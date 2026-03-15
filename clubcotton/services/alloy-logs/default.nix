{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  service = "alloy-logs";
  cfg = config.services.clubcotton.${service};

  extraLabelsStr =
    concatStringsSep "\n"
    (mapAttrsToList (k: v: ''${k} = "${v}",'') cfg.extraLabels);

  # Generate file match + source blocks for each file target
  mkFileTargetLabels = target: let
    allLabels =
      {
        job = target.job;
        hostname = config.networking.hostName;
      }
      // target.extraLabels;
  in
    concatStringsSep "\n" (mapAttrsToList (k: v: ''${k} = "${v}",'') allLabels);

  mkFileSourceBlock = target: ''
    local.file_match "${target.job}" {
      path_targets = [{
        __path__ = "${target.path}",
    ${mkFileTargetLabels target}
      }]
    }

    loki.source.file "${target.job}" {
      targets    = local.file_match.${target.job}.targets
      forward_to = [loki.write.default.receiver]
    }
  '';

  fileSourceBlocks = concatStringsSep "\n" (map mkFileSourceBlock cfg.fileTargets);

  # --- Noise filter helpers ---

  nfCfg = cfg.noiseFilter;
  allNoiseRules = nfCfg.rules ++ nfCfg.extraRules;

  # Convert a unit option to a LogQL selector
  # "foo.service" → '{unit="foo.service"}'
  # "~regex.*"    → '{unit=~"regex.*"}'
  mkSelector = unit: let
    isRegex = hasPrefix "~" unit;
    pattern = removePrefix "~" unit;
  in
    if isRegex
    then ''{unit=~"${pattern}"}''
    else ''{unit="${unit}"}'';

  # Generate a stage.match block wrapping a stage.drop for unit-scoped rules
  # Uses backtick raw strings for selector to avoid double-quote escaping issues
  mkUnitDropBlock = rule: ''
    stage.match {
      selector = `${mkSelector rule.unit}`
      stage.drop {
        expression = "${rule.expression}"
      }
    }
  '';

  # Generate a bare stage.drop for global (unit=null) rules
  mkGlobalDropBlock = rule: ''
    stage.drop {
      expression = "${rule.expression}"
    }
  '';

  mkDropBlock = rule:
    if rule.unit == null
    then mkGlobalDropBlock rule
    else mkUnitDropBlock rule;

  noiseFilterBlock = ''
    loki.process "noise_filter" {
      forward_to = [loki.write.default.receiver]

    ${concatStringsSep "\n" (map mkDropBlock allNoiseRules)}
    }
  '';

  # Where journal logs are forwarded: through noise filter or directly to loki.write
  journalForwardTo =
    if nfCfg.enable && allNoiseRules != []
    then "[loki.process.noise_filter.receiver]"
    else "[loki.write.default.receiver]";

  # Default noise rules — known cosmetic log noise across the fleet
  defaultNoiseRules = [
    {
      unit = "immich-server.service";
      expression = "unsupported image format";
      description = "Immich logs thousands of these daily for unsupported thumbnails";
    }
    {
      unit = "garage.service";
      expression = "error 404 Not Found, Key not found";
      description = "Garage S3 404s during normal cache-miss lookups";
    }
    {
      unit = "~podman-pinchflat.*";
      expression = "last_error";
      description = "Pinchflat container emits noisy last_error status lines";
    }
    {
      unit = "navidrome.service";
      expression = "(?i)scanner";
      description = "Navidrome scanner progress logs clutter error views";
    }
    {
      unit = "systemd-resolved.service";
      expression = "Using degraded feature set";
      description = "Resolved degraded-mode warnings on every boot";
    }
    {
      unit = "polkit.service";
      expression = "(?i)error";
      description = "Polkit logs non-actionable JS engine errors ~10/host/day";
    }
    {
      unit = "grafana.service";
      expression = "(?i)error";
      description = "Grafana logs plugin and datasource errors during normal operation";
    }
    {
      unit = "~tsnsrv-.*\\.service";
      expression = "(?i)error";
      description = "Tailscale serve proxies log transient connection errors";
    }
    {
      unit = "unifi-poller.service";
      expression = "401";
      description = "UniFi Poller 401s when controller session expires";
    }
    {
      unit = "tailscaled.service";
      expression = "(?i)error";
      description = "Tailscale daemon logs routine connectivity errors";
    }
    {
      unit = null;
      expression = "Failed to initialize graphics backend for OpenGL";
      description = "OpenGL init failures on headless servers (any unit)";
    }
    {
      unit = "~aardvark-dns.*";
      expression = "(?i)error";
      description = "Podman DNS resolver logs transient lookup errors";
    }
    {
      unit = "lxcfs.service";
      expression = "(?i)fail|error";
      description = "LXCFS logs non-critical cgroup mount errors";
    }
    {
      unit = "prometheus-smartctl-exporter.service";
      expression = "open: permission denied";
      description = "Smartctl exporter can't access some disk devices";
    }
  ];

  noiseRuleSubmodule = types.submodule {
    options = {
      unit = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Systemd unit to scope this rule to. null matches any unit.
          Prefix with ~ for regex matching (e.g. "~tsnsrv-.*\\.service").
        '';
      };
      expression = mkOption {
        type = types.str;
        description = "RE2 regex matched against log line content. Matching lines are dropped.";
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "Human-readable explanation of why this rule exists.";
      };
    };
  };

  alloyConfig = pkgs.writeText "config.alloy" ''
    loki.source.journal "systemd" {
      forward_to    = ${journalForwardTo}
      relabel_rules = loki.relabel.journal.rules
      path          = "/var/log/journal"
      labels        = {
        job      = "systemd-journal",
        hostname = "${config.networking.hostName}",
    ${extraLabelsStr}
      }
    }

    loki.relabel "journal" {
      forward_to = ${journalForwardTo}

      rule {
        source_labels = ["__journal__systemd_unit"]
        target_label  = "unit"
      }
      rule {
        source_labels = ["__journal__systemd_user_unit"]
        target_label  = "user_unit"
      }
      rule {
        source_labels = ["__journal_syslog_identifier"]
        target_label  = "syslog_identifier"
      }
      rule {
        source_labels = ["__journal__transport"]
        target_label  = "transport"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "priority"
      }
      rule {
        source_labels = ["__journal_priority_keyword"]
        target_label  = "level"
      }
    }

    ${optionalString (nfCfg.enable && allNoiseRules != []) noiseFilterBlock}

    ${fileSourceBlocks}

    loki.write "default" {
      endpoint {
        url = "${cfg.lokiEndpoint}"
      }
    }
  '';
in {
  options.services.clubcotton.${service} = {
    enable = mkEnableOption "Grafana Alloy log collection agent";

    lokiEndpoint = mkOption {
      type = types.str;
      default = "http://nas-01.lan:3100/loki/api/v1/push";
      description = "Loki push endpoint URL.";
    };

    httpListenPort = mkOption {
      type = types.port;
      default = 12346;
      description = "Port for Alloy's internal UI/metrics (bound to localhost).";
    };

    extraLabels = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional static labels to attach to all log entries.";
    };

    fileTargets = mkOption {
      type = types.listOf (types.submodule {
        options = {
          job = mkOption {
            type = types.str;
            description = "Job name used as Alloy component identifier and Loki label.";
          };
          path = mkOption {
            type = types.str;
            description = "Glob pattern for log files to tail (e.g. /var/log/app/*.log).";
          };
          extraLabels = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Additional labels to attach to entries from these files.";
          };
        };
      });
      default = [];
      description = "File paths to tail and forward to Loki.";
    };

    noiseFilter = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable log noise filtering before Loki ingestion.";
      };

      rules = mkOption {
        type = types.listOf noiseRuleSubmodule;
        default = defaultNoiseRules;
        description = "Drop rules applied to journal logs. Override to replace defaults entirely.";
      };

      extraRules = mkOption {
        type = types.listOf noiseRuleSubmodule;
        default = [];
        description = "Additional drop rules appended to the default set (per-host customization).";
      };
    };
  };

  config = mkIf cfg.enable {
    services.alloy = {
      enable = true;
      extraFlags = [
        "--server.http.listen-addr=127.0.0.1:${toString cfg.httpListenPort}"
        "--disable-reporting"
      ];
      configPath = pkgs.runCommand "alloy-logs.d" {} ''
        mkdir $out
        cp "${alloyConfig}" "$out/config.alloy"
      '';
    };

    # DynamicUser=true (set by the upstream alloy module) implies PrivateTmp,
    # so Alloy can't see files under /tmp. Bind-mount each fileTarget's parent
    # directory read-only into the service namespace.
    systemd.services.alloy.serviceConfig.BindReadOnlyPaths = let
      # Extract parent directory from a glob path (strip the filename/glob portion)
      parentDir = path: dirOf path;
      dirs = unique (map (t: parentDir t.path) cfg.fileTargets);
    in
      mkIf (cfg.fileTargets != []) dirs;
  };
}
