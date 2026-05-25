#!/usr/bin/env python3
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

    def log_message(self, format, *args):
        logging.info("%s - %s", self.address_string(), format % args)

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
