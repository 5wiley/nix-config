#!/usr/bin/env python3
import json
import os
import pathlib
import tempfile

import yaml


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None:
        raise SystemExit(f"missing required environment variable: {name}")
    return value


home = pathlib.Path(env("HERMES_HOME_DIR", env("HOME")))
hermes_home = pathlib.Path(env("HERMES_STATE_DIR", str(home / ".hermes")))
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
extra["host"] = env("HERMES_WEBHOOK_HOST", "127.0.0.1")
extra["port"] = int(env("HERMES_WEBHOOK_PORT", "8644"))
# The public-facing proxy validates Forgejo. Hermes is loopback-only and
# receives requests from that proxy, so the route intentionally disables
# Hermes-side HMAC requirements.
extra["secret"] = env("HERMES_WEBHOOK_SECRET", "INSECURE_NO_AUTH")

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

routes_json = os.environ.get("HERMES_WEBHOOK_ROUTES_JSON")
if routes_json:
    route_files = json.loads(routes_json)
    if not isinstance(route_files, dict):
        raise SystemExit("HERMES_WEBHOOK_ROUTES_JSON must be a JSON object")
else:
    route_files = {env("HERMES_WEBHOOK_ROUTE_NAME"): env("HERMES_WEBHOOK_ROUTE_FILE")}

for route_name, route_file in route_files.items():
    with open(route_file, "r", encoding="utf-8") as fh:
        subscriptions[route_name] = json.load(fh)

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
