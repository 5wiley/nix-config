# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
{
  config,
  pkgs,
  lib,
  unstablePkgs,
  inputs,
  hostName,
  hostSpec,
  ...
}: let
  keys = import ../../common/keys.nix;
in {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../../../modules/node-exporter
    ../../../modules/nfs
    inputs.nix-builder-config.nixosModules.coordinator
    inputs.nix-builder-config.nixosModules.cache-pusher
    ../../../modules/incus
    ../../../modules/incus-cluster
    ../../../modules/systemd-network
  ];

  environment.systemPackages = with pkgs; [
    dolt
    python3Packages.huggingface-hub
  ];

  # Incus cluster controller for clubcotton site
  services.incus-cluster = {
    enable = true;
    site = "clubcotton";
    instances = import ../../../data/incus/clubcotton.nix;
  };

  services.clubcotton = {
    alloy-logs = {
      enable = true;
      otelReceiver.enable = true;
    };
    code-server.enable = true;
    nut-client.enable = true;
    bonob.enable = true;

    auto-upgrade = {
      enable = true;
      flake = "git+https://forgejo.bobtail-clownfish.ts.net/bcotton/nix-config?ref=main";
      dates = "03:30";
      healthChecks = {
        pingTargets = ["192.168.5.1" "192.168.5.220"];
        services = ["sshd" "tailscaled"];
        tcpPorts = [
          {port = 22;}
        ];
      };
    };
    # Cloudflare Tunnel for secure internet exposure
    # To enable:
    # 1. Create tunnel in Cloudflare Zero Trust dashboard
    # 2. Create secret: agenix -e secrets/cloudflare-tunnel-token.age
    # 3. Paste the tunnel token
    # 4. Uncomment below and rebuild
    cloudflare-tunnel = {
      enable = true;
      tokenFile = config.age.secrets.cloudflare-tunnel-token.path;
    };

    forgejo-runner = {
      enable = true;
      instances = {
        nix01_1 = {
          name = "nix-01-runner-1";
          url = "http://nas-01.lan:3000";
          tokenFile = config.age.secrets."forgejo-runner-token".path;
          labels = [
            "nixos:docker://nixos/nix:latest"
            "ubuntu-latest:docker://node:20-bookworm"
            "debian-latest:docker://node:20-bookworm"
          ];
          capacity = 2;
        };
        nix01_2 = {
          name = "nix-01-runner-2";
          url = "http://nas-01.lan:3000";
          tokenFile = config.age.secrets."forgejo-runner-token".path;
          labels = [
            "nixos:docker://nixos/nix:latest"
            "ubuntu-latest:docker://node:20-bookworm"
            "debian-latest:docker://node:20-bookworm"
          ];
          capacity = 2;
        };
      };
    };

    obsidian = {
      enable = true;
      instances.bcotton = {
        httpPort = 13000;
        httpsPort = 13001;
        user = "bcotton";
        group = "users";
        vaultDir = "/home/bcotton/obsidian-vaults";
        sshDir = "/home/bcotton/.ssh";
        # To enable HTTP Basic Auth:
        # 1. Create the secret: agenix -e secrets/obsidian-bcotton.age
        # 2. Add content: PASSWORD=your-secret-password
        # 3. Uncomment the basicAuth block below
        basicAuth = {
          enable = true;
          username = "bcotton";
          environmentFile = config.age.secrets.obsidian-bcotton.path;
        };
      };
      instances.natalya = {
        httpPort = 13002;
        httpsPort = 13003;
        user = "natalya";
        group = "users";
        vaultDir = "/home/natalya/obsidian-vaults";
        basicAuth = {
          enable = false;
          username = "natalya";
          environmentFile = config.age.secrets.obsidian-natalya.path;
        };
      };
    };

    honcho.enable = true;

    # CPU-only Ollama for embeddings — offloads from nas-01 GPU to avoid
    # llama-swap model swap thrashing between chat and embedding models.
    ollama = {
      enable = true;
      acceleration = false;
      models = "/models/ollama";
      environmentVariables = {
        OLLAMA_NUM_PARALLEL = "4";
        OLLAMA_MAX_LOADED_MODELS = "1";
      };
    };
  };

  # Configure distributed build fleet
  services.nix-builder.coordinator = {
    enable = true;
    sshKeyPath = config.age.secrets."nix-builder-ssh-key".path;
    enableLocalBuilds = true; # nix-01 can build locally as fallback
    localCache = null; # Don't sign builds on nix-01 - nas-01 handles cache signing
    # Use .lan suffix for local DNS resolution (Tailscale names won't resolve from builder environment)
    builders = [
      {
        hostname = "nas-01.lan";
        systems = ["x86_64-linux"];
        maxJobs = 16;
        speedFactor = 2; # nas-01 is faster
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
      }
      {
        hostname = "nix-02.lan";
        systems = ["x86_64-linux"];
        maxJobs = 16;
        speedFactor = 4;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
      }
      {
        hostname = "nix-03.lan";
        systems = ["x86_64-linux"];
        maxJobs = 16;
        speedFactor = 4;
        supportedFeatures = ["nixos-test" "benchmark" "big-parallel" "kvm"];
      }
    ];
  };

  # Push all locally-built paths to the Harmonia cache on nas-01
  services.nix-builder.cache-pusher = {
    enable = true;
    sshKeyPath = config.age.secrets."nix-builder-ssh-key".path;
  };

  # Cache client already enabled via flake-modules/hosts.nix with defaults

  # Create builder user for remote builds
  users.users.nix-builder = {
    isNormalUser = true;
    description = "Nix remote builder";
    openssh.authorizedKeys.keys = keys.builderAuthorizedKeys;
  };

  nix.settings.trusted-users = ["nix-builder"];

  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    autoPrune.enable = true;
    # Required for containers under podman-compose to be able to talk to each other.
    defaultNetwork.settings.dns_enabled = true;
  };

  clubcotton.zfs_single_root = {
    enable = true;
    poolname = "rpool";
    swapSize = "64G";
    disk = "/dev/disk/by-id/nvme-eui.00000000000000000026b738281a1aa5";
    useStandardRootFilesystems = true;
    reservedSize = "20GiB";
    volumes = {};
  };

  boot.zfs.extraPools = ["incus"];

  # Declarative ZFS dataset for LLM models on the second SSD (incus pool / nvme1n1)
  disko.zfs = {
    enable = true;
    # Ignore pool roots and all existing datasets — only manage incus/models
    settings.ignoredDatasets = ["incus" "incus/buckets" "incus/buckets/*" "incus/containers" "incus/containers/*" "incus/custom" "incus/custom/*" "incus/deleted" "incus/deleted/*" "incus/images" "incus/images/*" "incus/virtual-machines" "incus/virtual-machines/*" "rpool" "rpool/*"];
    settings.datasets = {
      "incus/models" = {
        properties = {
          mountpoint = "/models";
          compression = "lz4";
          atime = "off";
          quota = "50G";
        };
      };
    };
  };

  # Create /models/ollama before ollama.service (ReadWritePaths requires it to exist)
  systemd.services.ollama-models-dir = {
    description = "Create Ollama models directory";
    before = ["ollama.service"];
    requiredBy = ["ollama.service"];
    serviceConfig.Type = "oneshot";
    script = ''
      ${pkgs.coreutils}/bin/mkdir -p /models/ollama
      ${pkgs.coreutils}/bin/chmod 1777 /models/ollama
    '';
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Enable cgroups v2 unified hierarchy for containers
  boot.kernelParams = ["systemd.unified_cgroup_hierarchy=1"];

  # Delegate cgroup controllers for container management
  systemd.services."user@".serviceConfig.Delegate = "cpu cpuset io memory pids";

  networking = {
    hostName = "nix-01";
    hostId = hostSpec.hostId;
  };

  # Configure systemd-networkd with bonding and VLANs
  clubcotton.systemd-network = {
    enable = true;
    mode = "bonded";
    interfaces = ["enp2s0" "enp3s0"];
    bondName = "bond0";
    bridgeName = "br0";
    enableIncusBridge = true;
    enableVlans = true;
    nativeVlan = {
      id = 5;
      address = "192.168.5.210/24";
      gateway = "192.168.5.1";
      dns = ["192.168.5.220"];
    };
  };

  services.clubcotton.claude-relay = {
    enable = true;
    port = 8788;
    openFirewall = true;
  };

  # Daily infrastructure health report via Claude Code
  systemd.services.infra-report = {
    description = "Generate daily infrastructure health report via Claude Code";
    after = ["network-online.target"];
    wants = ["network-online.target"];
    path = [pkgs.git pkgs.claude-code pkgs.curl pkgs.jq pkgs.openssh];

    serviceConfig = {
      Type = "oneshot";
      User = "bcotton";
      Group = "users";
      WorkingDirectory = "/home/bcotton/nix-config/default";
      TimeoutStartSec = "30min";
      EnvironmentFile = "/home/bcotton/.config/sensitive/.claude-personal-env";
      Environment = [
        "HOME=/home/bcotton"
        "CLAUDE_CONFIG_DIR=/home/bcotton/.claude-personal"
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1"
      ];
      ExecStart = "${pkgs.claude-code}/bin/claude -p '/infra-report' --allowedTools 'Bash,Read,Write,Grep,Glob,Edit,Agent' --dangerously-skip-permissions";
    };
  };

  systemd.timers.infra-report = {
    description = "Run daily infrastructure health report at 6am";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "06:00";
      Persistent = true;
    };
  };

  services.clubcotton.code-server = {
    tailnetHostname = "nix-01-vscode";
    user = "bcotton";
  };

  services.clubcotton.bonob = {
    sonosSeedHost = "192.168.5.96";
    url = "http://192.168.5.210:3000/";
    subsonicUrl = "http://nas-01.lan:${toString config.services.navidrome.settings.Port}/";
  };

  # Set your time zone.
  time.timeZone = hostSpec.timeZone;

  programs.zsh.enable = hostSpec.zshEnable;

  users.users.root = {
    openssh.authorizedKeys.keys = keys.rootAuthorizedKeys;
  };

  # Enable the OpenSSH daemon.
  services.openssh.enable = hostSpec.opensshEnable;

  networking.firewall.enable = hostSpec.firewallEnable;

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
    };
  };

  system.stateVersion = hostSpec.stateVersion;
}
