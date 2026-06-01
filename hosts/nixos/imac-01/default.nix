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
  ];

  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    # Required for containers under podman-compose to be able to talk to each other.
    defaultNetwork.settings.dns_enabled = true;
  };

  clubcotton.zfs_single_root = {
    enable = true;
    poolname = "rpool";
    swapSize = "4G";
    disk = "/dev/disk/by-id/wwn-0x5002538655584d30";
    useStandardRootFilesystems = true;
    reservedSize = "20GiB";
  };

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking = {
    hostName = "imac-01";
    hostId = hostSpec.hostId;

    useDHCP = false;
    defaultGateway = "192.168.5.1";
    nameservers = ["192.168.5.220"];
    interfaces.enp4s0f0.ipv4.addresses = [
      {
        address = "192.168.5.125";
        prefixLength = 24;
      }
    ];
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

  # Disable smartctl exporter on imac-01: upstream bug in v0.14.0 causes HTTP 500
  # on every scrape due to a DescribeByCollect race condition triggered by the
  # Apple SSD's partial ATA command support (exit status 4).
  # See: https://github.com/prometheus-community/smartctl_exporter/issues/305
  # Re-enable when nixpkgs ships a fixed version (check docs/UPGRADE_CHECKLIST.md).
  services.prometheus.exporters.smartctl.enable = lib.mkForce false;

  services.clubcotton = {
    alloy-logs.enable = true;

    auto-upgrade = {
      enable = true;
      flake = "git+https://forgejo.bobtail-clownfish.ts.net/bcotton/nix-config?ref=main";
      dates = "03:00";
      healthChecks = {
        pingTargets = ["192.168.5.1" "192.168.5.220"];
        services = ["sshd" "tailscaled" "display-manager"];
        tcpPorts = [
          {port = 22;}
        ];
      };
    };
  };

  environment.systemPackages = with pkgs; [
    firefox
    code-cursor
  ];

  system.stateVersion = hostSpec.stateVersion;
}
