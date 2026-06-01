# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).
#
# Nuke and pave this machine
# nix run github:nix-community/nixos-anywhere -- --flake '.#condo-01' root@<host ip>
{
  config,
  pkgs,
  lib,
  unstablePkgs,
  hostName,
  hostSpec,
  ...
}: let
  keys = import ../../common/keys.nix;
in {
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ../../../modules/incus
  ];

  services.clubcotton = {
    alloy-logs.enable = true;
    alloy-logs.lokiEndpoint = "https://loki.bobtail-clownfish.ts.net/loki/api/v1/push";
    tailscale.enable = true;

    auto-upgrade = {
      enable = true;
      flake = "git+https://forgejo.bobtail-clownfish.ts.net/bcotton/nix-config?ref=main";
      dates = "03:00";
      healthChecks = {
        services = ["sshd" "tailscaled"];
        tcpPorts = [
          {port = 22;}
        ];
        # Remote host — not on the 192.168.5.0/24 LAN, so the default gateway ping target doesn't apply.
        pingTargets = [];
      };
    };
  };

  clubcotton.zfs_single_root.enable = true;

  # Suppress WARN-level smartctl exporter noise: /dev/sda has 1 stale historical
  # error in its SMART log (from 8400+ hours ago), causing ~960 false warnings/day.
  # Disk is healthy (0 reallocated sectors, 0 read errors, PASSED self-test).
  services.prometheus.exporters.smartctl.extraFlags = ["--log.level=error"];
  virtualisation.podman.enable = true;

  programs.zsh.enable = hostSpec.zshEnable;
  services.openssh.enable = hostSpec.opensshEnable;

  services.clubcotton.tailscale = {
    useRoutingFeatures = "server";
    extraSetFlags = [
      "--advertise-routes=192.168.5.0/24"
      "--accept-routes"
    ];
  };

  users.users.root = {
    openssh.authorizedKeys.keys = keys.rootAuthorizedKeys;
  };

  virtualisation.podman = {
    dockerSocket.enable = true;
    dockerCompat = true;
    autoPrune.enable = true;
    # Required for containers under podman-compose to be able to talk to each other.
    defaultNetwork.settings.dns_enabled = true;
  };

  clubcotton.zfs_single_root = {
    poolname = "rpool";
    swapSize = "4G"; # 1/4 of 16G
    disk = "/dev/disk/by-id/ata-X12_SSD_256GB_KT2023000020001117";
    useStandardRootFilesystems = true;
    reservedSize = "50GiB"; #0.20 of 256G
  };

  networking = {
    hostId = hostSpec.hostId;
    hostName = "condo-01";
    # defaultGateway is supplied by DHCP on br0.
    # Setting it statically races network-setup against dhcpcd during
    # nixos-rebuild test → "Nexthop has invalid gateway" (forgejo #299).
    useDHCP = false;
    bridges."br0".interfaces = ["eno1"];
    interfaces."br0".useDHCP = true;
    #interfaces."br0".ipv4.addresses = [
    #  {
    #    address = "192.168.12.54";
    #    prefixLength = 24;
    #  }
    #];

    # Static nameservers to fix forgejo #332: tailscaled was losing its
    # DHCP-supplied upstream resolvers around 03:00 MDT (DHCP lease event
    # coinciding with auto-upgrade), causing 4 days of consecutive failures
    # with `dns: resolver: forward: no upstream resolvers set, returning
    # SERVFAIL` for cache.nixos.org / github.com.
    #
    # tailscaled forwards non-MagicDNS queries to whatever upstream resolvers
    # it learned from /etc/resolv.conf, so pinning resolv.conf to stable
    # public + LAN resolvers ensures the upstream set is never empty.
    nameservers = ["1.1.1.1" "9.9.9.9" "192.168.12.1"];
    # Prevent dhcpcd from overwriting our static nameservers when leases renew.
    dhcpcd.extraConfig = ''
      nohook resolv.conf
    '';
  };
  time.timeZone = hostSpec.timeZone;

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };

  services.xserver = {
    enable = true;
    desktopManager = {
      xterm.enable = false;
      xfce.enable = true;
    };
  };
  services.displayManager.defaultSession = "xfce";

  services.displayManager.autoLogin = {
    enable = true;
    user = "media";
  };

  users.users.media = {
    isNormalUser = true;
    packages = with pkgs; [
      jellyfin-media-player
    ];
  };

  services.caddy = {
    enable = true;
    virtualHosts.":8096".extraConfig = ''
      bind 0.0.0.0
      reverse_proxy http://100.88.184.98:8096
    '';
    virtualHosts.":8112".extraConfig = ''
      bind 0.0.0.0
      reverse_proxy http://100.88.184.98:8112
    '';
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [8096 8112];
  # Or disable the firewall altogether.
  networking.firewall.enable = hostSpec.firewallEnable;

  system.stateVersion = hostSpec.stateVersion;
}
