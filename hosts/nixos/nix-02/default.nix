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
    # nix-builder client is enabled via flake-modules/hosts.nix
    inputs.nix-builder-config.nixosModules.coordinator
    inputs.nix-builder-config.nixosModules.cache-pusher
    ../../../modules/incus
    ../../../modules/systemd-network
  ];

  environment.systemPackages = with pkgs; [
    dolt
  ];

  services.clubcotton = {
    alloy-logs = {
      enable = true;
      otelReceiver.enable = true;
      fileTargets = [
        {
          job = "openclaw";
          path = "/tmp/openclaw/*.log";
        }
      ];
    };
    # vnc.enable = true;
    tailscale.enable = true;
    nut-client.enable = true;
    hyprland.enable = true;
    hermes = {
      enable = true;
      forgejoIssueWebhook.enable = true;
      forgejoCiFailureWebhook.enable = true;
      alertmanagerWebhook.enable = true;
    };

    auto-upgrade = {
      enable = true;
      flake = "git+https://forgejo.bobtail-clownfish.ts.net/bcotton/nix-config?ref=main";
      dates = "03:00";
      healthChecks = {
        pingTargets = ["192.168.5.1" "192.168.5.220"];
        services = ["sshd" "tailscaled"];
        tcpPorts = [
          {port = 22;}
        ];
      };
    };
    forgejo-runner = {
      enable = true;
      instances = {
        nix02_1 = {
          name = "nix-02-runner-1";
          url = "http://nas-01.lan:3000";
          tokenFile = config.age.secrets."forgejo-runner-token".path;
          labels = [
            "nixos:docker://nixos/nix:latest"
            "ubuntu-latest:docker://node:20-bookworm"
            "debian-latest:docker://node:20-bookworm"
          ];
          capacity = 2;
        };
        nix02_2 = {
          name = "nix-02-runner-2";
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
  };

  # Create builder user for remote builds
  users.users.nix-builder = {
    isNormalUser = true;
    description = "Nix remote builder";
    openssh.authorizedKeys.keys = keys.builderAuthorizedKeys;
  };

  nix.settings.trusted-users = ["nix-builder"];

  # Worker role: accept distributed builds but do NOT redelegate.
  # nix-01 is the sole in-repo coordinator; CI coordinates via its own SSH config.
  # Empty `builders` prevents the full-mesh cascade deadlock where serving hosts
  # would recursively delegate to peers. cache-pusher below still pushes locally-
  # built artifacts to nas-01's Harmonia cache.
  services.nix-builder.coordinator = {
    enable = true;
    sshKeyPath = config.age.secrets."nix-builder-ssh-key".path;
    enableLocalBuilds = true;
    localCache = null; # nas-01 handles cache signing
    builders = [];
  };

  # Raise local build concurrency to actually use this host's CPU when serving
  # remote build requests (coordinator module caps this at 2 otherwise).
  nix.settings.max-jobs = lib.mkForce "auto";

  # Push all locally-built paths to the Harmonia cache on nas-01
  services.nix-builder.cache-pusher = {
    enable = true;
    sshKeyPath = config.age.secrets."nix-builder-ssh-key".path;
  };

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
    disk = "/dev/disk/by-id/nvme-eui.00000000000000000026b738281a43c5";
    useStandardRootFilesystems = true;
    reservedSize = "20GiB";
    volumes = {};
  };

  boot.zfs.extraPools = ["incus"];

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Enable cgroups v2 unified hierarchy for containers
  boot.kernelParams = ["systemd.unified_cgroup_hierarchy=1"];

  # Delegate cgroup controllers for container management
  systemd.services."user@".serviceConfig.Delegate = "cpu cpuset io memory pids";

  networking = {
    hostId = hostSpec.hostId;
    hostName = hostName;
  };

  # Configure systemd-networkd with bonding and VLANs
  clubcotton.systemd-network = {
    enable = true;
    mode = "single-nic";
    interfaces = ["enp3s0"];
    bridgeName = "br0";
    enableIncusBridge = true;
    enableVlans = true;
    nativeVlan = {
      id = 5;
      address = "192.168.5.212/24";
      gateway = "192.168.5.1";
      dns = ["192.168.5.220"];
    };
  };

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
    };
  };

  time.timeZone = hostSpec.timeZone;

  programs.zsh.enable = hostSpec.zshEnable;

  users.users.root = {
    openssh.authorizedKeys.keys = keys.rootAuthorizedKeys;
  };

  services.clubcotton.claude-relay = {
    enable = true;
    port = 8788;
    openFirewall = true;
  };

  services.openssh.enable = hostSpec.opensshEnable;
  # TODO
  networking.firewall.enable = hostSpec.firewallEnable;
  system.stateVersion = hostSpec.stateVersion;
}
