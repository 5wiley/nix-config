#!/usr/bin/env python3
import hashlib
import hmac
import json
import logging
import os
import re
import sys
import urllib.error
import urllib.parse
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
TARGET_USER = os.environ.get(
    "TARGET_USER",
    os.environ.get("TARGET_ASSIGNEE", "larry"),
)
FORGEJO_API_BASE = os.environ.get(
    "FORGEJO_API_BASE",
    "https://forgejo.bobtail-clownfish.ts.net/api/v1",
).rstrip("/")
FORGEJO_TOKEN_FILE = os.environ.get("FORGEJO_TOKEN_FILE", "")
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", "1048576"))
MENTION_RE = re.compile(rf"(?<![\w-])@{re.escape(TARGET_USER)}(?![\w-])", re.IGNORECASE)


def read_secret():
    with open(SECRET_FILE, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def read_token():
    if not FORGEJO_TOKEN_FILE:
        return ""
    try:
        with open(FORGEJO_TOKEN_FILE, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        logging.warning("Forgejo token file is configured but not readable")
        return ""


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


def event_type(headers, payload):
    return (
        header(headers, "X-Gitea-Event")
        or header(headers, "X-Forgejo-Event")
        or header(headers, "X-GitHub-Event")
        or payload.get("event_type")
        or ""
    ).lower()


def mentioned_texts(payload):
    for key in ("comment", "issue", "pull_request"):
        value = payload.get(key) or {}
        if isinstance(value, dict):
            for text_key in ("body", "content", "title"):
                text = value.get(text_key)
                if isinstance(text, str):
                    yield text
    for text_key in ("body", "content", "title"):
        text = payload.get(text_key)
        if isinstance(text, str):
            yield text


def has_target_mention(payload):
    return any(MENTION_RE.search(text) for text in mentioned_texts(payload))


def is_issue_or_pr_payload(payload):
    return isinstance(payload.get("issue"), dict) or isinstance(
        payload.get("pull_request"),
        dict,
    )


def should_forward(headers, payload):
    event = event_type(headers, payload)
    action = str(payload.get("action") or "").lower()
    if event and not any(
        marker in event
        for marker in ("issue", "pull_request", "pull_request_comment")
    ):
        return False
    if action in {"deleted", "closed"}:
        return False
    return is_issue_or_pr_payload(payload) and has_target_mention(payload)


def repository_full_name(payload):
    repository = payload.get("repository") or {}
    full_name = repository.get("full_name") or repository.get("fullName")
    if full_name:
        return full_name
    owner = repository.get("owner") or {}
    owner_name = owner.get("login") or owner.get("username") or owner.get("name")
    repo_name = repository.get("name")
    if owner_name and repo_name:
        return f"{owner_name}/{repo_name}"
    return ""


def add_eyes_reaction_if_possible(payload):
    comment = payload.get("comment") or {}
    comment_id = comment.get("id")
    repo = repository_full_name(payload)
    token = read_token()
    if not comment_id or not repo or not token:
        return False

    owner, repo_name = repo.split("/", 1)
    url = (
        f"{FORGEJO_API_BASE}/repos/"
        f"{urllib.parse.quote(owner, safe='')}/"
        f"{urllib.parse.quote(repo_name, safe='')}/"
        f"issues/comments/{comment_id}/reactions"
    )
    body = json.dumps({"content": "eyes"}).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"token {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
        logging.info("Added eyes reaction to Forgejo comment %s", comment_id)
        return True
    except urllib.error.HTTPError as exc:
        if exc.code in {409, 422}:
            logging.info(
                "Eyes reaction already present or unsupported for comment %s",
                comment_id,
            )
        else:
            logging.warning(
                "Could not add eyes reaction to Forgejo comment %s: HTTP %s",
                comment_id,
                exc.code,
            )
    except Exception:
        logging.exception("Could not add eyes reaction to Forgejo comment %s", comment_id)
    return False


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
        if not should_forward(self.headers, payload):
            self.send_json(200, {"status": "ignored"})
            return

        reaction_added = add_eyes_reaction_if_possible(payload)
        payload.setdefault("event_type", event_type(self.headers, payload) or "issues")
        payload["hermes_forgejo_proxy"] = {
            "matched_user": TARGET_USER,
            "reaction_added": reaction_added,
        }
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
                "X-GitHub-Event": payload["event_type"],
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
                        "reaction_added": reaction_added,
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
        "Listening on %s:%s%s and forwarding mentions of @%s to %s",
        LISTEN_HOST,
        LISTEN_PORT,
        ROUTE_PATH,
        TARGET_USER,
        HERMES_URL,
    )
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
