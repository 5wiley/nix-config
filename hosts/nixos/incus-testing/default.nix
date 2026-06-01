{
  config,
  pkgs,
  lib,
  hostName,
  hostSpec,
  ...
}: let
  keys = import ../../common/keys.nix;
in {
  imports = [
    ./hardware-configuration.nix
    ../../../modules/incus
  ];

  # Cgroups v2 for nested container management
  boot.kernelParams = ["systemd.unified_cgroup_hierarchy=1"];
  systemd.services."user@".serviceConfig.Delegate = "cpu cpuset io memory pids";

  # Incus preseed: dir storage (no ZFS in VM) and NAT bridge
  virtualisation.incus.preseed = {
    networks = [
      {
        name = "incusbr0";
        type = "bridge";
        config = {
          "ipv4.address" = "10.0.100.1/24";
          "ipv4.nat" = "true";
          "ipv6.address" = "none";
        };
      }
    ];
    storage_pools = [
      {
        name = "default";
        driver = "dir";
      }
    ];
    profiles = [
      {
        name = "default";
        devices = {
          root = {
            path = "/";
            pool = "default";
            type = "disk";
          };
          eth0 = {
            name = "eth0";
            network = "incusbr0";
            type = "nic";
          };
        };
      }
    ];
  };

  # Simple DHCP networking from Incus bridge
  networking = {
    useDHCP = true;
    hostName = hostName;
  };

  time.timeZone = hostSpec.timeZone;
  programs.zsh.enable = hostSpec.zshEnable;

  users.users.root = {
    openssh.authorizedKeys.keys = keys.rootAuthorizedKeys;
  };

  services.openssh.enable = hostSpec.opensshEnable;
  networking.firewall.enable = hostSpec.firewallEnable;
  system.stateVersion = hostSpec.stateVersion;
}
