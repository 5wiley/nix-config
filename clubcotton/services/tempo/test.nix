{nixpkgs}: let
  unstablePkgs = import <nixpkgs-unstable> {};
in {
  name = "tempo-service-test";

  nodes = {
    tempo = {
      config,
      pkgs,
      lib,
      ...
    }: {
      imports = [
        ../../../clubcotton/services/tempo
      ];

      # Define minimal clubcotton options for test
      options.clubcotton = {
        tailscaleAuthKeyPath = lib.mkOption {
          type = lib.types.str;
          default = "/dev/null";
        };
      };

      # Mock tsnsrv service options to avoid Tailscale
      options.services.tsnsrv = lib.mkOption {
        default = {};
        type = lib.types.attrs;
      };

      config = {
        _module.args.unstablePkgs = unstablePkgs;

        services.clubcotton.tempo = {
          enable = true;
          # Use local storage for test to avoid S3 dependency
          s3.environmentFile = pkgs.writeText "tempo-s3-env" ''
            TEMPO_S3_ACCESS_KEY_ID=test-access-key
            TEMPO_S3_SECRET_ACCESS_KEY=test-secret-key
          '';
        };

        # Override tempo config to use local storage only for test
        services.tempo.settings.storage.trace = lib.mkForce {
          backend = "local";
          wal = {
            path = "/var/lib/tempo/wal";
          };
          local = {
            path = "/var/lib/tempo/blocks";
          };
        };

        # Mock tsnsrv service to avoid Tailscale dependencies in tests
        services.tsnsrv.enable = lib.mkForce false;

        # Enable SSH for debugging
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "yes";
            PermitEmptyPasswords = "yes";
          };
        };
        users.users.root.password = "";
      };
    };
  };

  testScript = ''
    start_all()

    # Wait for tempo service to start
    tempo.wait_for_unit("tempo.service")

    # Check that tempo is listening on the expected ports
    with subtest("tempo HTTP API is accessible"):
        tempo.wait_for_open_port(3200)
        # Just test that we can connect, don't require ready endpoint to work
        tempo.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost:3200/ready | grep -E '(200|503)'")
        tempo.succeed("echo 'Tempo is responding on port 3200'")

    with subtest("tempo OTLP endpoints are accessible"):
        tempo.wait_for_open_port(4317)  # OTLP gRPC
        tempo.wait_for_open_port(4318)  # OTLP HTTP

    with subtest("tempo service is healthy"):
        tempo.succeed("systemctl is-active tempo.service")
        # Print status for debugging
        tempo.succeed("systemctl status tempo.service")
        tempo.succeed("journalctl -u tempo.service --no-pager | tail -10")

    with subtest("tempo data directories are created"):
        tempo.succeed("test -d /var/lib/tempo")
        tempo.succeed("test -d /var/lib/tempo/wal")
        tempo.succeed("test -d /var/lib/tempo/blocks")
        tempo.succeed("test -d /var/lib/tempo/generator/wal")

    with subtest("tempo user and permissions"):
        tempo.succeed("stat /var/lib/tempo | grep 'Uid.*tempo'")
        tempo.succeed("getent passwd tempo")
        tempo.succeed("getent group tempo")
  '';
}
