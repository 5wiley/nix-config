#!/usr/bin/env python3
import json
import logging
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(message)s")

LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8655"))
ROUTE_PATH = os.environ.get("ROUTE_PATH", "/webhooks/alertmanager/hermes")
HERMES_URL = os.environ["HERMES_URL"]
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", "1048576"))


def alert_summary(payload):
    alerts = payload.get("alerts") if isinstance(payload, dict) else None
    if not isinstance(alerts, list):
        return "unknown alert payload"
    names = []
    for alert in alerts:
        labels = alert.get("labels") if isinstance(alert, dict) else {}
        if isinstance(labels, dict):
            name = labels.get("alertname")
            if name and name not in names:
                names.append(str(name))
    return ", ".join(names) if names else f"{len(alerts)} alert(s)"


class Handler(BaseHTTPRequestHandler):
    server_version = "alertmanager-hermes-webhook-proxy/1.0"

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
        if self.path in ("/", "/health"):
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
        body_text = body.decode("utf-8", errors="replace")
        logging.info("Received Alertmanager webhook payload (%d bytes): %s", len(body), body_text)
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            logging.warning("Failed to parse Alertmanager webhook payload as JSON: %s; body=%s", exc, body_text)
            self.send_json(400, {"error": "invalid json", "detail": str(exc)})
            return

        if not isinstance(payload, dict) or not isinstance(payload.get("alerts"), list):
            logging.warning("Rejected Alertmanager webhook payload with unexpected shape: %s", body_text)
            self.send_json(400, {"error": "not an Alertmanager webhook payload"})
            return

        payload.setdefault("event_type", "alertmanager")
        payload["hermes_alertmanager_proxy"] = {
            "summary": alert_summary(payload),
            "alerts_count": len(payload.get("alerts") or []),
        }
        forward_body = json.dumps(payload).encode("utf-8")
        request_id = self.headers.get("X-Request-ID") or "alertmanager-hermes-webhook"
        request = urllib.request.Request(
            HERMES_URL,
            data=forward_body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "X-GitHub-Event": "alertmanager",
                "X-Request-ID": request_id,
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                response_body = response.read().decode("utf-8", errors="replace")
            logging.info(
                "Forwarded Alertmanager webhook to Hermes: status=%s alerts=%s summary=%s",
                payload.get("status"),
                len(payload.get("alerts") or []),
                alert_summary(payload),
            )
            self.send_json(
                response.status,
                {
                    "status": "forwarded",
                    "hermes": json.loads(response_body),
                },
            )
        except urllib.error.HTTPError as exc:
            logging.exception("Hermes webhook rejected forwarded Alertmanager payload")
            self.send_json(502, {"error": "hermes rejected payload", "status": exc.code})
        except Exception:
            logging.exception("Failed to forward Alertmanager webhook to Hermes")
            self.send_json(502, {"error": "failed to forward to hermes"})


if __name__ == "__main__":
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    logging.info("Listening on %s:%s%s and forwarding Alertmanager alerts to %s", LISTEN_HOST, LISTEN_PORT, ROUTE_PATH, HERMES_URL)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)
