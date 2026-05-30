{
  config,
  lib,
  pkgs,
  localPackages,
  inputs,
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
  forgejoCiWebhookCfg = cfg.forgejoCiFailureWebhook;
  alertmanagerWebhookCfg = cfg.alertmanagerWebhook;
  webhookEnabled = forgejoWebhookCfg.enable || forgejoCiWebhookCfg.enable || alertmanagerWebhookCfg.enable;

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

  forgejoCiFailureWebhookPrompt = ''
    Forgejo CI failure webhook received.

    Repository: {repository.full_name}
    Event: {event_type}
    Action: {action}
    Workflow: {hermes_forgejo_ci_proxy.workflow_name}
    Run ID: {hermes_forgejo_ci_proxy.run_id}
    Job ID: {hermes_forgejo_ci_proxy.job_id}
    Job: {hermes_forgejo_ci_proxy.job_name}
    Status: {hermes_forgejo_ci_proxy.status}
    Conclusion: {hermes_forgejo_ci_proxy.conclusion}
    State: {hermes_forgejo_ci_proxy.state}
    Branch/ref: {hermes_forgejo_ci_proxy.branch}
    Commit: {hermes_forgejo_ci_proxy.commit_sha}
    URL: {hermes_forgejo_ci_proxy.html_url}

    This webhook has already been validated and filtered by the local nix-config
    Forgejo-to-Hermes CI proxy. It should only fire for terminal failed Forgejo
    Actions jobs or runs.

    Required autonomous workflow:
    1. Fetch the full Forgejo run/job details and logs. For bcotton/nix-config,
       prefer `fj run view` / `fj run logs` and `just ci-analyze <run-id>` when available.
    2. Determine why the failure is occurring. Distinguish code/config regressions
       from flaky infrastructure, missing secrets, runner capacity, or unrelated main-branch failures.
    3. If a safe repository fix is possible, create a branch from the correct base,
       make the fix, run the relevant formatter/tests/Nix checks, commit, push, and
       open a Forgejo PR against bcotton/nix-config. If the failure belongs to a PR,
       target that PR's branch when appropriate instead of opening duplicate work.
    4. If no safe code/config fix is possible, gather enough evidence to explain the
       manual action needed and do not invent a PR.
    5. Send the user a Telegram home-channel message with: failing workflow/job, run
       URL, suspected root cause, evidence, PR URL if created, verification performed,
       and any manual action needed. This route delivers Hermes' final response to
       logs only, so you must explicitly use the messaging/send_message tool.

    Use Forgejo via fj. Do not print tokens or secrets.
  '';

  forgejoCiFailureWebhookRoute = {
    description = "Investigate failing Forgejo CI jobs and open remediation PRs";
    secret = "INSECURE_NO_AUTH";
    prompt = forgejoCiFailureWebhookPrompt;
    skills = ["forgejo-fj" "github-pr-workflow" "systematic-debugging"];
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
  forgejoCiFailureWebhookRouteFile = pkgs.writeText "hermes-forgejo-ci-failure-webhook-route.json" (builtins.toJSON forgejoCiFailureWebhookRoute);
  alertmanagerWebhookRouteFile = pkgs.writeText "hermes-alertmanager-webhook-route.json" (builtins.toJSON alertmanagerWebhookRoute);
  webhookRouteFiles =
    lib.optionalAttrs forgejoWebhookCfg.enable {
      "${forgejoWebhookCfg.routeName}" = forgejoWebhookRouteFile;
    }
    // lib.optionalAttrs forgejoCiWebhookCfg.enable {
      "${forgejoCiWebhookCfg.routeName}" = forgejoCiFailureWebhookRouteFile;
    }
    // lib.optionalAttrs alertmanagerWebhookCfg.enable {
      "${alertmanagerWebhookCfg.routeName}" = alertmanagerWebhookRouteFile;
    };
  webhookRouteFilesJson = pkgs.writeText "hermes-webhook-route-files.json" (builtins.toJSON webhookRouteFiles);

  proxyPackage = inputs.forgejo-webhook-proxy.packages.${pkgs.stdenv.hostPlatform.system}.default;
  proxyRoutes =
    lib.optional forgejoWebhookCfg.enable {
      name = "forgejo-mentions";
      kind = "forgejo-mention";
      path = forgejoWebhookCfg.proxyPath;
      hermes_url = "http://${forgejoWebhookCfg.hermesHost}:${toString forgejoWebhookCfg.hermesPort}/webhooks/${forgejoWebhookCfg.routeName}";
      secret_file = forgejoWebhookCfg.secretFile;
      target_user = forgejoWebhookCfg.targetUser;
      forgejo_api_base = forgejoWebhookCfg.forgejoApiBase;
      forgejo_token_file = forgejoWebhookCfg.forgejoTokenFile;
    }
    ++ lib.optional forgejoCiWebhookCfg.enable {
      name = "forgejo-ci-failures";
      kind = "forgejo-ci-failure";
      path = forgejoCiWebhookCfg.proxyPath;
      hermes_url = "http://${forgejoWebhookCfg.hermesHost}:${toString forgejoWebhookCfg.hermesPort}/webhooks/${forgejoCiWebhookCfg.routeName}";
      secret_file = forgejoCiWebhookCfg.secretFile;
    }
    ++ lib.optional alertmanagerWebhookCfg.enable {
      name = "alertmanager";
      kind = "alertmanager";
      path = alertmanagerWebhookCfg.proxyPath;
      hermes_url = "http://${forgejoWebhookCfg.hermesHost}:${toString forgejoWebhookCfg.hermesPort}/webhooks/${alertmanagerWebhookCfg.routeName}";
    };
  proxyRoutesJson = pkgs.writeText "hermes-webhook-proxy-routes.json" (builtins.toJSON {
    listen_host = forgejoWebhookCfg.proxyHost;
    listen_port = forgejoWebhookCfg.proxyPort;
    routes = proxyRoutes;
  });
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
        default = "/webhooks/forgejo";
        description = "HTTP path that Forgejo should POST issue, pull request, and Actions webhooks to.";
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

    forgejoCiFailureWebhook = {
      enable = mkEnableOption "Forgejo CI failure webhook proxy into Hermes";

      proxyHost = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address for the Forgejo CI failure webhook proxy to bind to.";
      };

      proxyPort = mkOption {
        type = types.port;
        default = 8656;
        description = "Local port for the Forgejo CI failure webhook proxy.";
      };

      proxyPath = mkOption {
        type = types.str;
        default = forgejoWebhookCfg.proxyPath;
        defaultText = literalExpression "config.services.clubcotton.hermes.forgejoIssueWebhook.proxyPath";
        description = "HTTP path that Forgejo should POST Actions webhooks to. Defaults to the shared Forgejo webhook path.";
      };

      routeName = mkOption {
        type = types.str;
        default = "forgejo-ci-failure-investigation";
        description = "Hermes webhook subscription route name used by the Forgejo CI failure proxy.";
      };

      secretFile = mkOption {
        type = types.path;
        default = config.age.secrets."forgejo-hermes-webhook-secret".path;
        defaultText = literalExpression ''config.age.secrets."forgejo-hermes-webhook-secret".path'';
        description = "Path containing the Forgejo webhook shared secret.";
      };

      tailnetHostname = mkOption {
        type = types.nullOr types.str;
        default = "hermes-forgejo-ci-webhook";
        description = "Tailnet hostname exposing the Forgejo CI failure webhook proxy.";
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

    systemd.services.hermes-webhook-proxy = mkIf webhookEnabled {
      description = "Validate and route Forgejo/Alertmanager webhooks into Hermes";
      after = ["network-online.target" "hermes-gateway.service"];
      wants = ["network-online.target" "hermes-gateway.service"];
      wantedBy = ["multi-user.target"];

      environment = {
        ROUTES_JSON_FILE = proxyRoutesJson;
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${proxyPackage}/bin/forgejo-webhook-proxy";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadOnlyPaths =
          [cfg.home]
          ++ lib.optional forgejoWebhookCfg.enable forgejoWebhookCfg.secretFile
          ++ lib.optional forgejoCiWebhookCfg.enable forgejoCiWebhookCfg.secretFile
          ++ lib.optional (forgejoWebhookCfg.enable && forgejoWebhookCfg.forgejoTokenFile != null) forgejoWebhookCfg.forgejoTokenFile;
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
      (mkIf (forgejoCiWebhookCfg.enable && forgejoCiWebhookCfg.tailnetHostname != null && forgejoCiWebhookCfg.tailnetHostname != "") {
        enable = true;
        defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

        services."${forgejoCiWebhookCfg.tailnetHostname}" = {
          ephemeral = true;
          toURL = "http://${forgejoWebhookCfg.proxyHost}:${toString forgejoWebhookCfg.proxyPort}/";
        };
      })
      (mkIf (alertmanagerWebhookCfg.enable && alertmanagerWebhookCfg.tailnetHostname != null && alertmanagerWebhookCfg.tailnetHostname != "") {
        enable = true;
        defaults.authKeyPath = clubcotton.tailscaleAuthKeyPath;

        services."${alertmanagerWebhookCfg.tailnetHostname}" = {
          ephemeral = true;
          toURL = "http://${forgejoWebhookCfg.proxyHost}:${toString forgejoWebhookCfg.proxyPort}/";
        };
      })
    ];
  };
}
