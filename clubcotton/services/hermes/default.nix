{
  config,
  lib,
  pkgs,
  localPackages,
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

  webhookCfg = cfg.forgejoIssueWebhook;

  webhookPrompt = ''
    Forgejo issue assignment webhook received.

    Repository: {repository.full_name}
    Action: {action}
    Issue: #{issue.number} - {issue.title}
    Issue URL: {issue.html_url}
    Assignees: {issue.assignees}

    This webhook has already been validated and filtered by the local nix-config
    Forgejo-to-Hermes proxy. The issue is assigned to larry.

    Implement the issue:
    1. Fetch the full issue details from Forgejo.
    2. Clone or update the repository checkout for {repository.full_name}.
    3. Create an implementation branch named for issue #{issue.number}.
    4. Make the requested change.
    5. Run the relevant formatter, tests, and/or NixOS build checks.
    6. Commit and push the branch.
    7. Open a Forgejo pull request or update an existing one.
    8. Report the PR URL and verification results.

    Use Forgejo via fj. Do not print tokens or secrets.
  '';

  webhookRoute = {
    description = "Implement Forgejo issues assigned to larry";
    secret = "INSECURE_NO_AUTH";
    prompt = webhookPrompt;
    skills = ["forgejo-fj" "github-pr-workflow"];
    deliver = "log";
  };

  webhookRouteFile = pkgs.writeText "hermes-forgejo-issue-webhook-route.json" (builtins.toJSON webhookRoute);
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

    gateway.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to run the Hermes gateway service for webhook and messaging platforms.";
    };

    forgejoIssueWebhook = {
      enable = mkEnableOption "Forgejo issue-assignment webhook proxy into Hermes";

      proxyHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address for the Forgejo webhook validation proxy to bind to.";
      };

      proxyPort = mkOption {
        type = types.port;
        default = 8654;
        description = "Local port for the Forgejo webhook validation proxy.";
      };

      proxyPath = mkOption {
        type = types.str;
        default = "/webhooks/forgejo/issues/assigned-larry";
        description = "HTTP path that Forgejo should POST issue webhooks to.";
      };

      hermesHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address for the Hermes webhook platform to bind to.";
      };

      hermesPort = mkOption {
        type = types.port;
        default = 8644;
        description = "Local port for the Hermes webhook platform.";
      };

      routeName = mkOption {
        type = types.str;
        default = "forgejo-issue-assigned-larry";
        description = "Hermes webhook subscription route name used by the proxy.";
      };

      assignee = mkOption {
        type = types.str;
        default = "larry";
        description = "Forgejo username whose issue assignments should trigger Hermes.";
      };

      secretFile = mkOption {
        type = types.path;
        default = config.age.secrets."forgejo-hermes-webhook-secret".path;
        defaultText = literalExpression ''config.age.secrets."forgejo-hermes-webhook-secret".path'';
        description = "Path containing the Forgejo webhook shared secret.";
      };

      tailnetHostname = mkOption {
        type = types.nullOr types.str;
        default = "hermes-forgejo-webhook";
        description = "Tailnet hostname exposing the Forgejo webhook validation proxy.";
      };
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

      path = [pkgs.bash pkgs.coreutils];

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

    systemd.services.hermes-configure-webhooks = mkIf webhookCfg.enable {
      description = "Configure Hermes webhook platform and Forgejo issue route";
      before = ["hermes-gateway.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "HERMES_HOME_DIR=${cfg.home}"
          "HERMES_STATE_DIR=${cfg.home}/.hermes"
          "HERMES_WEBHOOK_HOST=${webhookCfg.hermesHost}"
          "HERMES_WEBHOOK_PORT=${toString webhookCfg.hermesPort}"
          "HERMES_WEBHOOK_SECRET=INSECURE_NO_AUTH"
          "HERMES_WEBHOOK_ROUTE_FILE=${webhookRouteFile}"
          "HERMES_WEBHOOK_ROUTE_NAME=${webhookCfg.routeName}"
        ];
        ExecStart = "${localPackages.hermes-webhook-tools}/bin/configure-hermes-webhook";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.home;
      };
    };

    systemd.services.hermes-gateway = mkIf cfg.gateway.enable {
      description = "Hermes Agent gateway";
      after = ["network-online.target"] ++ lib.optional webhookCfg.enable "hermes-configure-webhooks.service";
      wants = ["network-online.target"] ++ lib.optional webhookCfg.enable "hermes-configure-webhooks.service";
      wantedBy = ["multi-user.target"];

      path = [pkgs.bash pkgs.coreutils];

      environment = {
        HOME = cfg.home;
        HERMES_HOME = "${cfg.home}/.hermes";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.home;
        ExecStart = "${cfg.executable} gateway run";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.forgejo-hermes-webhook-proxy = mkIf webhookCfg.enable {
      description = "Validate Forgejo issue-assignment webhooks and forward them to Hermes";
      after = ["network-online.target" "hermes-gateway.service"];
      wants = ["network-online.target" "hermes-gateway.service"];
      wantedBy = ["multi-user.target"];

      environment = {
        LISTEN_HOST = webhookCfg.proxyHost;
        LISTEN_PORT = toString webhookCfg.proxyPort;
        ROUTE_PATH = webhookCfg.proxyPath;
        HERMES_URL = "http://${webhookCfg.hermesHost}:${toString webhookCfg.hermesPort}/webhooks/${webhookCfg.routeName}";
        FORGEJO_WEBHOOK_SECRET_FILE = webhookCfg.secretFile;
        TARGET_ASSIGNEE = webhookCfg.assignee;
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${localPackages.hermes-webhook-tools}/bin/forgejo-hermes-webhook-proxy";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadOnlyPaths = [webhookCfg.secretFile cfg.home];
      };
    };

    services.tsnsrv = mkMerge [
      (mkIf (cfg.tailnetHostname != null && cfg.tailnetHostname != "") {
        enable = true;
        defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

        services."${cfg.tailnetHostname}" = {
          ephemeral = true;
          toURL = "http://${cfg.host}:${toString cfg.port}/";
          # Hermes dashboard validates the Host header against the address it
          # was bound to and rejects anything else with HTTP 400 (Invalid Host
          # header). tsnsrv's recommendedProxyHeaders default forwards the
          # original tailnet hostname, which the dashboard refuses. Disable it
          # so the proxied request uses the upstream URL's host (cfg.host).
          extraArgs = ["-recommendedProxyHeaders=false"];
        };
      })
      (mkIf (webhookCfg.enable && webhookCfg.tailnetHostname != null && webhookCfg.tailnetHostname != "") {
        enable = true;
        defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

        services."${webhookCfg.tailnetHostname}" = {
          ephemeral = true;
          toURL = "http://${webhookCfg.proxyHost}:${toString webhookCfg.proxyPort}/";
        };
      })
    ];
  };
}
