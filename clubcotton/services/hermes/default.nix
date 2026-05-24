{
  config,
  lib,
  ...
}:
with lib; let
  service = "hermes";
  cfg = config.services.clubcotton.${service};
  clubcotton = config.clubcotton;

  dashboardArgs =
    [
      "dashboard"
      "--host"
      cfg.host
      "--port"
      (toString cfg.port)
      "--no-open"
    ]
    ++ lib.optional cfg.enableTui "--tui";
in {
  options.services.clubcotton.${service} = {
    enable = mkEnableOption "Hermes Agent dashboard";

    user = mkOption {
      type = types.str;
      default = "larry";
      description = "User account that owns the Hermes installation and state.";
    };

    group = mkOption {
      type = types.str;
      default = config.users.users.${cfg.user}.group;
      defaultText = literalExpression "config.users.users.\${config.services.clubcotton.hermes.user}.group";
      description = "Group used to run the Hermes dashboard service.";
    };

    executable = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.local/bin/hermes";
      defaultText = literalExpression ''"/home/\${config.services.clubcotton.hermes.user}/.local/bin/hermes"'';
      description = "Path to the hermes executable.";
    };

    home = mkOption {
      type = types.str;
      default = "/home/${cfg.user}";
      defaultText = literalExpression ''"/home/\${config.services.clubcotton.hermes.user}"'';
      description = "Home directory used for HERMES_HOME and dashboard state.";
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address for the Hermes dashboard to bind to.";
    };

    port = mkOption {
      type = types.port;
      default = 9119;
      description = "Local port for the Hermes dashboard.";
    };

    enableTui = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to expose the embedded browser TUI tab.";
    };

    tailnetHostname = mkOption {
      type = types.nullOr types.str;
      default = "hermes-dashboard";
      description = "The tailnet hostname to expose the Hermes dashboard as.";
    };

    homepage.name = mkOption {
      type = types.str;
      default = "Hermes Dashboard";
    };
    homepage.description = mkOption {
      type = types.str;
      default = "Hermes Agent configuration and session dashboard";
    };
    homepage.icon = mkOption {
      type = types.str;
      default = "mdi-robot-outline";
    };
    homepage.category = mkOption {
      type = types.str;
      default = "Infrastructure";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.hermes-dashboard = {
      description = "Hermes Agent web dashboard";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      environment = {
        HOME = cfg.home;
        HERMES_HOME = "${cfg.home}/.hermes";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.home;
        ExecStart = "${cfg.executable} ${lib.escapeShellArgs dashboardArgs}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    services.tsnsrv = mkIf (cfg.tailnetHostname != null && cfg.tailnetHostname != "") {
      enable = true;
      defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

      services."${cfg.tailnetHostname}" = {
        ephemeral = true;
        toURL = "http://${cfg.host}:${toString cfg.port}/";
      };
    };
  };
}
