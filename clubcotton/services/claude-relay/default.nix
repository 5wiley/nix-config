{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  service = "claude-relay";
  cfg = config.services.clubcotton.${service};
in {
  options.services.clubcotton.${service} = {
    enable = mkEnableOption "Claude Relay channel firewall rules";

    port = mkOption {
      type = types.port;
      default = 8788;
      description = "Fixed port for Claude Relay HTTP server";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the firewall port for Claude Relay";
    };
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [cfg.port];
  };
}
