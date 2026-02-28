{
  config,
  lib,
  ...
}:
with lib; let
  service = "tempo";
  cfg = config.services.clubcotton.${service};
  clubcotton = config.clubcotton;
in {
  options.services.clubcotton.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable Grafana Tempo for distributed tracing";
    };
    port = mkOption {
      type = types.port;
      default = 3200;
      description = "HTTP listen port for Tempo.";
    };
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/tempo";
      description = "Local data directory for WAL and local traces.";
    };
    retentionPeriod = mkOption {
      type = types.str;
      default = "168h";
      description = "Trace retention period (default 7 days).";
    };

    s3 = {
      endpoint = mkOption {
        type = types.str;
        default = "localhost:3900";
        description = "S3-compatible endpoint (e.g., Garage).";
      };
      bucketName = mkOption {
        type = types.str;
        default = "tempo-traces";
        description = "S3 bucket name for trace storage.";
      };
      region = mkOption {
        type = types.str;
        default = "garage";
        description = "S3 region (use any string for Garage).";
      };
      insecure = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to use HTTP instead of HTTPS for S3.";
      };
      environmentFile = mkOption {
        type = types.path;
        description = ''
          Path to environment file with S3 credentials.
          Must contain TEMPO_S3_ACCESS_KEY_ID and TEMPO_S3_SECRET_ACCESS_KEY.
        '';
      };
    };

    tailnetHostname = mkOption {
      type = types.nullOr types.str;
      default = "${service}";
      description = "The tailnet hostname to expose Tempo as.";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Tempo";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Distributed tracing";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "grafana.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Infrastructure";
    };
  };

  config = lib.mkIf cfg.enable {
    services.tempo = {
      enable = true;
      settings = {
        server = {
          http_listen_port = cfg.port;
          log_level = "warn";
        };

        distributor = {
          receivers = {
            otlp = {
              protocols = {
                grpc = {
                  endpoint = "0.0.0.0:4317";
                };
                http = {
                  endpoint = "0.0.0.0:4318";
                };
              };
            };
          };
        };

        ingester = {
          max_block_duration = "5m";
          max_block_bytes = 1000000;
          flush_check_period = "10s";
          trace_idle_period = "10s";
        };

        compactor = {
          compaction = {
            block_retention = cfg.retentionPeriod;
          };
        };

        storage = {
          trace = {
            backend = "s3";
            wal = {
              path = "${cfg.dataDir}/wal";
            };
            s3 = {
              bucket = cfg.s3.bucketName;
              endpoint = cfg.s3.endpoint;
              region = cfg.s3.region;
              access_key = "\${TEMPO_S3_ACCESS_KEY_ID}";
              secret_key = "\${TEMPO_S3_SECRET_ACCESS_KEY}";
              insecure = cfg.s3.insecure;
              forcepathstyle = true;
            };
            local = {
              path = "${cfg.dataDir}/blocks";
            };
            pool = {
              max_workers = 100;
              queue_depth = 10000;
            };
          };
        };

        querier = {
          frontend_worker = {
            frontend_address = "127.0.0.1:9095";
          };
        };

        query_frontend = {
          search = {
            duration_slo = "5s";
            throughput_bytes_slo = 1.073741824e+09;
          };
          trace_by_id = {
            duration_slo = "5s";
          };
        };

        metrics_generator = {
          registry = {
            external_labels = {
              source = "tempo";
              cluster = "docker-compose";
            };
          };
          storage = {
            path = "${cfg.dataDir}/generator/wal";
            remote_write_flush_deadline = "1m";
          };
        };

        overrides = {
          defaults = {
            metrics_generator = {
              processors = ["service-graphs" "span-metrics"];
            };
          };
        };
      };
    };

    systemd.services.tempo.serviceConfig = {
      EnvironmentFile = cfg.s3.environmentFile;
      # The upstream module sets DynamicUser=true, which allocates a
      # transient UID that conflicts with the static tempo user our
      # tmpfiles rules expect.  Disable it so the service runs as
      # the static tempo user consistently.
      DynamicUser = lib.mkForce false;
      User = "tempo";
      Group = "tempo";
      # Override ExecStart to add --config.expand-env flag for environment variable substitution
      ExecStart = lib.mkForce "${pkgs.tempo}/bin/tempo --config.expand-env --config.file=${config.services.tempo.configFile}";
    };

    users.users.tempo = {
      isSystemUser = true;
      group = "tempo";
      home = cfg.dataDir;
    };
    users.groups.tempo = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 tempo tempo - -"
      "d ${cfg.dataDir}/wal 0750 tempo tempo - -"
      "d ${cfg.dataDir}/blocks 0750 tempo tempo - -"
      "d ${cfg.dataDir}/generator 0750 tempo tempo - -"
      "d ${cfg.dataDir}/generator/wal 0750 tempo tempo - -"
    ];

    services.tsnsrv = {
      enable = true;
      defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

      services."${cfg.tailnetHostname}" = mkIf (cfg.tailnetHostname != "") {
        ephemeral = true;
        toURL = "http://127.0.0.1:${toString cfg.port}/";
      };
    };

    networking.firewall.allowedTCPPorts = [
      cfg.port # HTTP API
      4317 # OTLP gRPC
      4318 # OTLP HTTP
    ];
  };
}
