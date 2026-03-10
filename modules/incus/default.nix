{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./monitoring.nix
  ];

  networking.nftables.enable = true;
  networking.firewall.allowedTCPPorts = [8443];

  virtualisation.incus.enable = true;
  virtualisation.incus.package = pkgs.incus;
  virtualisation.incus.ui.enable = true;

  # Don't restart Incus during nixos-rebuild test/switch. Incus updates
  # its cluster DB (api_extensions, schema) on startup, which is irreversible.
  # If a test activation rolls back, the DB stays upgraded, causing a version
  # mismatch that blocks the entire cluster. The auto-upgrade module handles
  # the explicit restart after a successful switch via deferredRestartServices.
  systemd.services.incus.restartIfChanged = false;
  systemd.services.incus.stopIfChanged = false;

  # Restart Incus only after a successful switch, not during test activation.
  services.clubcotton.auto-upgrade.deferredRestartServices =
    lib.mkIf config.services.clubcotton.auto-upgrade.enable ["incus"];

  virtualisation.incus.preseed = {};
  # virtualisation.incus.preseed = {
  #   config = {"core.https_address" = "192.168.5.213:8443";};
  #   networks = [];
  #   storage_pools = [
  #     {
  #       config = {size = "30GiB";};
  #       description = "";
  #       name = "local";
  #       driver = "btrfs";
  #     }
  #   ];
  #   profiles = [
  #     {
  #       config = {};
  #       description = "";
  #       devices = {
  #         root = {
  #           path = "/";
  #           pool = "local";
  #           type = "disk";
  #         };
  #       };
  #       name = "default";
  #     }
  #   ];
  #   projects = [];
  #   cluster = {
  #     # server_name = "nix-02";
  #     server_name = "${config.networking.hostName}";
  #     enabled = true;
  #     member_config = [];
  #     cluster_address = "";
  #     cluster_certificate = "";
  #     server_address = "";
  #     cluster_token = "";
  #     cluster_certificate_path = "";
  #   };
  # };
}
