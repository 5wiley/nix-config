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

  forgejoWebhookCfg = cfg.forgejoIssueWebhook;
  alertmanagerWebhookCfg = cfg.alertmanagerWebhook;
  webhookEnabled = forgejoWebhookCfg.enable || alertmanagerWebhookCfg.enable;

  webhookPrompt = ''
    Forgejo issue or pull request mention webhook received.

    Repository: {repository.full_name}
    Action: {action}
    Issue: #{issue.number} - {issue.title}
    Issue URL: {issue.html_url}
    Pull request: #{pull_request.number} - {pull_request.title}
    Pull request URL: {pull_request.html_url}
    Comment URL: {comment.html_url}
    Comment body: {comment.body}
    Mentioned user: {hermes_forgejo_proxy.matched_user}
    Eyes reaction added by proxy: {hermes_forgejo_proxy.reaction_added}

    This webhook has already been validated and filtered by the local nix-config
    Forgejo-to-Hermes proxy. The issue or pull request comment mentions larry.

    Triage and implement the request:
    1. Fetch the full issue or pull request details from Forgejo.
    2. Clone or update the repository checkout for {repository.full_name}.
    3. Create an implementation branch named for the issue, PR, or comment context.
    4. Determine what the mention asks larry to do, then make the requested change.
    5. Run the relevant formatter, tests, and/or NixOS build checks.
    6. Commit and push the branch.
    7. Open a Forgejo pull request or update an existing one.
    8. Report the PR URL and verification results.

    Use Forgejo via fj. Do not print tokens or secrets.
  '';

  forgejoWebhookRoute = {
    description = "Implement Forgejo issues or pull requests that mention larry";
    secret = "INSECURE_NO_AUTH";
    prompt = webhookPrompt;
    skills = ["forgejo-fj" "github-pr-workflow"];
    deliver = "log";
  };

  alertmanagerWebhookPrompt = ''
    Prometheus Alertmanager webhook received.

    Status: {status}
    Receiver: {receiver}
    Group labels: {groupLabels}
    Common labels: {commonLabels}
    Common annotations: {commonAnnotations}
    External URL: {externalURL}
    Proxy summary: {hermes_alertmanager_proxy.summary}
    Alerts count: {hermes_alertmanager_proxy.alerts_count}
    Alerts JSON: {alerts}

    You are responding to a production monitoring alert. Investigate root cause and
    record the work in Forgejo.

    Required workflow:
    1. Parse the Alertmanager payload and summarize which alert(s) are firing or resolved.
    2. If the status is resolved, still create/update an issue only if the alert suggests
       follow-up is needed; otherwise send the user a concise home-channel note and stop.
    3. Use available diagnostics such as Loki logs, local system status, Forgejo CI, and
       the nix-config checkout to investigate likely root cause.
    4. Create a Forgejo issue in bcotton/nix-config with the alert details, suspected
       root cause, evidence, links, and next steps.
    5. If a safe config/code fix is possible, create a branch, commit it, push it, and
       open a PR against bcotton/nix-config. Link the PR from the issue.
    6. Send the user a note over the home channel on Telegram with: alert name/status,
       likely cause, issue URL, PR URL if created, and any urgent manual action.

    Use Forgejo via fj. Do not print tokens or secrets.
  '';

  alertmanagerWebhookRoute = {
    description = "Investigate Prometheus Alertmanager alerts and file nix-config issues";
    secret = "INSECURE_NO_AUTH";
    prompt = alertmanagerWebhookPrompt;
    skills = ["forgejo-fj" "github-pr-workflow" "loki-query"];
    deliver = "log";
  };

  forgejoWebhookRouteFile = pkgs.writeText "hermes-forgejo-issue-webhook-route.json" (builtins.toJSON forgejoWebhookRoute);
  alertmanagerWebhookRouteFile = pkgs.writeText "hermes-alertmanager-webhook-route.json" (builtins.toJSON alertmanagerWebhookRoute);
  webhookRouteFiles =
    lib.optionalAttrs forgejoWebhookCfg.enable {
      "${forgejoWebhookCfg.routeName}" = forgejoWebhookRouteFile;
    }
    // lib.optionalAttrs alertmanagerWebhookCfg.enable {
      "${alertmanagerWebhookCfg.routeName}" = alertmanagerWebhookRouteFile;
    };
  webhookRouteFilesJson = pkgs.writeText "hermes-webhook-route-files.json" (builtins.toJSON webhookRouteFiles);
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
      enable = mkEnableOption "Forgejo issue and pull request mention webhook proxy into Hermes";

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
        description = "HTTP path that Forgejo should POST issue and pull request webhooks to.";
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
        description = "Deprecated alias for targetUser.";
      };

      targetUser = mkOption {
        type = types.str;
        default = "larry";
        description = "Forgejo username whose @mentions should trigger Hermes.";
      };

      forgejoApiBase = mkOption {
        type = types.str;
        default = "https://forgejo.bobtail-clownfish.ts.net/api/v1";
        description = "Forgejo API base URL used to add acknowledgement reactions.";
      };

      forgejoTokenFile = mkOption {
        type = types.nullOr types.path;
        default = config.age.secrets."forgejo-token-larry".path;
        defaultText = literalExpression ''config.age.secrets."forgejo-token-larry".path'';
        description = "Optional Forgejo API token file used to add eyes reactions to mention comments.";
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

    alertmanagerWebhook = {
      enable = mkEnableOption "Prometheus Alertmanager webhook proxy into Hermes";

      proxyHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address for the Alertmanager webhook proxy to bind to.";
      };

      proxyPort = mkOption {
        type = types.port;
        default = 8655;
        description = "Local port for the Alertmanager webhook proxy.";
      };

      proxyPath = mkOption {
        type = types.str;
        default = "/webhooks/alertmanager/hermes";
        description = "HTTP path that Alertmanager should POST alerts to.";
      };

      routeName = mkOption {
        type = types.str;
        default = "alertmanager-investigation";
        description = "Hermes webhook subscription route name used by the Alertmanager proxy.";
      };

      tailnetHostname = mkOption {
        type = types.nullOr types.str;
        default = "hermes-alertmanager-webhook";
        description = "Tailnet hostname exposing the Alertmanager webhook proxy.";
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

    systemd.services.hermes-configure-webhooks = mkIf webhookEnabled {
      description = "Configure Hermes webhook platform and routes";
      before = ["hermes-gateway.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "HERMES_HOME_DIR=${cfg.home}"
          "HERMES_STATE_DIR=${cfg.home}/.hermes"
          "HERMES_WEBHOOK_HOST=${forgejoWebhookCfg.hermesHost}"
          "HERMES_WEBHOOK_PORT=${toString forgejoWebhookCfg.hermesPort}"
          "HERMES_WEBHOOK_SECRET=INSECURE_NO_AUTH"
          "HERMES_WEBHOOK_ROUTES_JSON_FILE=${webhookRouteFilesJson}"
        ];
        ExecStart = "${localPackages.hermes-webhook-tools}/bin/configure-hermes-webhook";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.home;
      };
    };

    systemd.services.hermes-gateway = mkIf cfg.gateway.enable {
      description = "Hermes Agent gateway";
      after = ["network-online.target"] ++ lib.optional webhookEnabled "hermes-configure-webhooks.service";
      wants = ["network-online.target"] ++ lib.optional webhookEnabled "hermes-configure-webhooks.service";
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

    systemd.services.forgejo-hermes-webhook-proxy = mkIf forgejoWebhookCfg.enable {
      description = "Validate Forgejo mention webhooks and forward them to Hermes";
      after = ["network-online.target" "hermes-gateway.service"];
      wants = ["network-online.target" "hermes-gateway.service"];
      wantedBy = ["multi-user.target"];

      environment = {
        LISTEN_HOST = forgejoWebhookCfg.proxyHost;
        LISTEN_PORT = toString forgejoWebhookCfg.proxyPort;
        ROUTE_PATH = forgejoWebhookCfg.proxyPath;
        HERMES_URL = "http://${forgejoWebhookCfg.hermesHost}:${toString forgejoWebhookCfg.hermesPort}/webhooks/${forgejoWebhookCfg.routeName}";
        FORGEJO_WEBHOOK_SECRET_FILE = forgejoWebhookCfg.secretFile;
        TARGET_USER = forgejoWebhookCfg.targetUser;
        FORGEJO_API_BASE = forgejoWebhookCfg.forgejoApiBase;
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
        Environment = lib.optional (forgejoWebhookCfg.forgejoTokenFile != null) "FORGEJO_TOKEN_FILE=${forgejoWebhookCfg.forgejoTokenFile}";
        ReadOnlyPaths = [forgejoWebhookCfg.secretFile cfg.home] ++ lib.optional (forgejoWebhookCfg.forgejoTokenFile != null) forgejoWebhookCfg.forgejoTokenFile;
      };
    };

    systemd.services.alertmanager-hermes-webhook-proxy = mkIf alertmanagerWebhookCfg.enable {
      description = "Forward Prometheus Alertmanager webhooks to Hermes";
      after = ["network-online.target" "hermes-gateway.service"];
      wants = ["network-online.target" "hermes-gateway.service"];
      wantedBy = ["multi-user.target"];

      environment = {
        LISTEN_HOST = alertmanagerWebhookCfg.proxyHost;
        LISTEN_PORT = toString alertmanagerWebhookCfg.proxyPort;
        ROUTE_PATH = alertmanagerWebhookCfg.proxyPath;
        HERMES_URL = "http://${forgejoWebhookCfg.hermesHost}:${toString forgejoWebhookCfg.hermesPort}/webhooks/${alertmanagerWebhookCfg.routeName}";
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${localPackages.hermes-webhook-tools}/bin/alertmanager-hermes-webhook-proxy";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
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
      (mkIf (forgejoWebhookCfg.enable && forgejoWebhookCfg.tailnetHostname != null && forgejoWebhookCfg.tailnetHostname != "") {
        enable = true;
        defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

        services."${forgejoWebhookCfg.tailnetHostname}" = {
          ephemeral = true;
          toURL = "http://${forgejoWebhookCfg.proxyHost}:${toString forgejoWebhookCfg.proxyPort}/";
        };
      })
      (mkIf (alertmanagerWebhookCfg.enable && alertmanagerWebhookCfg.tailnetHostname != null && alertmanagerWebhookCfg.tailnetHostname != "") {
        enable = true;
        defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

        services."${alertmanagerWebhookCfg.tailnetHostname}" = {
          ephemeral = true;
          toURL = "http://${alertmanagerWebhookCfg.proxyHost}:${toString alertmanagerWebhookCfg.proxyPort}/";
        };
      })
    ];
  };
}
