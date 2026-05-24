{
  config,
  lib,
  pkgs,
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
  webhookRouteFileString = toString webhookRouteFile;
  webhookRouteFilePrefix = builtins.substring 0 48 webhookRouteFileString;
  webhookRouteFileSuffix = builtins.substring 48 4096 webhookRouteFileString;

  configureGatewayScript = pkgs.writers.writePython3 "configure-hermes-webhook" {libraries = [pkgs.python3Packages.pyyaml];} ''
    import json
    import os
    import pathlib
    import tempfile

    import yaml

    home = pathlib.Path(${builtins.toJSON cfg.home})
    hermes_home = home / ".hermes"
    hermes_home.mkdir(mode=0o750, parents=True, exist_ok=True)

    config_path = hermes_home / "config.yaml"
    if config_path.exists():
        with config_path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    else:
        data = {}

    platforms = data.setdefault("platforms", {})
    webhook = platforms.setdefault("webhook", {})
    webhook["enabled"] = True
    extra = webhook.setdefault("extra", {})
    extra["host"] = ${builtins.toJSON webhookCfg.hermesHost}
    extra["port"] = ${toString webhookCfg.hermesPort}
    # The public-facing proxy validates Forgejo. Hermes is loopback-only and
    # receives requests from that proxy, so the route intentionally disables
    # Hermes-side HMAC requirements.
    extra["secret"] = "INSECURE_NO_AUTH"

    fd, tmp = tempfile.mkstemp(prefix="config.", suffix=".yaml", dir=hermes_home)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
    os.replace(tmp, config_path)
    os.chmod(config_path, 0o640)

    subscriptions_path = hermes_home / "webhook_subscriptions.json"
    if subscriptions_path.exists():
        try:
            with subscriptions_path.open("r", encoding="utf-8") as fh:
                subscriptions = json.load(fh)
            if not isinstance(subscriptions, dict):
                subscriptions = {}
        except Exception:
            subscriptions = {}
    else:
        subscriptions = {}

    route_file = (
        ${builtins.toJSON webhookRouteFilePrefix}
        ${builtins.toJSON webhookRouteFileSuffix}
    )
    with open(route_file, "r", encoding="utf-8") as fh:
        subscriptions[${builtins.toJSON webhookCfg.routeName}] = json.load(fh)

    fd, tmp = tempfile.mkstemp(
        prefix="webhook_subscriptions.",
        suffix=".json",
        dir=hermes_home,
    )
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(subscriptions, fh, indent=2)
        fh.write("\n")
    os.replace(tmp, subscriptions_path)
    os.chmod(subscriptions_path, 0o640)
  '';

  proxyScript = pkgs.writers.writePython3 "forgejo-hermes-webhook-proxy" {} ''
    import hashlib
    import hmac
    import json
    import logging
    import os
    import sys
    import urllib.error
    import urllib.request
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=LOG_LEVEL,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8654"))
    ROUTE_PATH = os.environ.get(
        "ROUTE_PATH",
        "/webhooks/forgejo/issues/assigned-larry",
    )
    HERMES_URL = os.environ["HERMES_URL"]
    SECRET_FILE = os.environ["FORGEJO_WEBHOOK_SECRET_FILE"]
    TARGET_ASSIGNEE = os.environ.get("TARGET_ASSIGNEE", "larry")
    MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", "1048576"))


    def read_secret():
        with open(SECRET_FILE, "r", encoding="utf-8") as fh:
            return fh.read().strip()


    def header(headers, name):
        return headers.get(name) or headers.get(name.lower()) or ""


    def validate_signature(headers, body):
        secret_text = read_secret()
        secret = secret_text.encode("utf-8")
        signatures = [
            header(headers, "X-Gitea-Signature"),
            header(headers, "X-Forgejo-Signature"),
            header(headers, "X-Hub-Signature-256"),
        ]
        for sig in [s for s in signatures if s]:
            if sig.startswith("sha256="):
                digest = hmac.new(secret, body, hashlib.sha256).hexdigest()
                expected = "sha256=" + digest
            else:
                expected = hmac.new(secret, body, hashlib.sha256).hexdigest()
            if hmac.compare_digest(sig, expected):
                return True
        token = header(headers, "X-Gitea-Token") or header(
            headers,
            "X-Forgejo-Token",
        )
        return bool(token) and hmac.compare_digest(token, secret_text)


    def assignee_login(value):
        if isinstance(value, dict):
            return value.get("login") or value.get("username") or value.get("name")
        if isinstance(value, str):
            return value
        return None


    def is_for_target_assignee(payload):
        issue = payload.get("issue") or {}
        candidates = []
        candidates.append(payload.get("assignee"))
        candidates.extend(issue.get("assignees") or [])
        if issue.get("assignee"):
            candidates.append(issue.get("assignee"))
        return any(
            assignee_login(candidate) == TARGET_ASSIGNEE
            for candidate in candidates
        )


    def is_issue_assignment(headers, payload):
        event = (
            header(headers, "X-Gitea-Event")
            or header(headers, "X-Forgejo-Event")
            or header(headers, "X-GitHub-Event")
            or payload.get("event_type")
            or ""
        ).lower()
        action = str(payload.get("action") or "").lower()
        if event and "issue" not in event:
            return False
        if action and action not in {"assigned", "opened", "edited"}:
            return False
        return "issue" in payload and is_for_target_assignee(payload)


    class Handler(BaseHTTPRequestHandler):
        server_version = "forgejo-hermes-webhook-proxy/1.0"

        def log_message(self, fmt, *args):
            logging.info("%s - %s", self.address_string(), fmt % args)

        def send_json(self, status, payload):
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path == "/health":
                self.send_json(200, {"status": "ok"})
            else:
                self.send_json(404, {"error": "not found"})

        def do_POST(self):
            if self.path != ROUTE_PATH:
                self.send_json(404, {"error": "unknown route"})
                return
            content_length = int(self.headers.get("Content-Length") or "0")
            if content_length <= 0 or content_length > MAX_BODY_BYTES:
                self.send_json(413, {"error": "invalid payload size"})
                return
            body = self.rfile.read(content_length)
            if not validate_signature(self.headers, body):
                logging.warning("Rejected webhook with invalid signature")
                self.send_json(401, {"error": "invalid signature"})
                return
            try:
                payload = json.loads(body)
            except json.JSONDecodeError:
                self.send_json(400, {"error": "invalid json"})
                return
            if not is_issue_assignment(self.headers, payload):
                self.send_json(200, {"status": "ignored"})
                return

            payload.setdefault("event_type", "issues")
            forward_body = json.dumps(payload).encode("utf-8")
            delivery_id = (
                self.headers.get("X-Gitea-Delivery")
                or self.headers.get("X-Forgejo-Delivery")
                or "forgejo-hermes-webhook"
            )
            request = urllib.request.Request(
                HERMES_URL,
                data=forward_body,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "X-GitHub-Event": "issues",
                    "X-Request-ID": delivery_id,
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=10) as response:
                    response_body = response.read().decode(
                        "utf-8",
                        errors="replace",
                    )
                    self.send_json(
                        response.status,
                        {
                            "status": "forwarded",
                            "hermes": json.loads(response_body),
                        },
                    )
            except urllib.error.HTTPError as exc:
                logging.exception("Hermes webhook rejected forwarded payload")
                self.send_json(
                    502,
                    {"error": "hermes rejected payload", "status": exc.code},
                )
            except Exception:
                logging.exception("Failed to forward webhook to Hermes")
                self.send_json(502, {"error": "failed to forward to hermes"})


    if __name__ == "__main__":
        httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
        logging.info(
            "Listening on %s:%s%s and forwarding to %s",
            LISTEN_HOST,
            LISTEN_PORT,
            ROUTE_PATH,
            HERMES_URL,
        )
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            sys.exit(0)
  '';
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
      default = true;
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
        ExecStart = "${configureGatewayScript}";
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
        ExecStart = "${proxyScript}";
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
