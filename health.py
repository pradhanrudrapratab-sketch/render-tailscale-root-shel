#!/usr/bin/env python3
"""Minimal health endpoint for Render / UptimeRobot.

GET or HEAD on / and /health -> 200 "online".
It only proves this web process is alive. It does NOT check SSH or Tailscale.
"""
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OK_PATHS = {"/", "/health"}


class Handler(BaseHTTPRequestHandler):
    server_version = "health"
    sys_version = ""

    def _respond(self, head_only=False):
        path = self.path.split("?", 1)[0]
        if path in OK_PATHS:
            status, body = 200, b"online"
        else:
            status, body = 404, b"not found"
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def do_GET(self):
        self._respond()

    def do_HEAD(self):  # UptimeRobot free plan can use HEAD
        self._respond(head_only=True)

    def log_message(self, *args):  # keep Render logs clean
        pass


def main():
    port = int(os.environ.get("PORT", "10000"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"health: listening on 0.0.0.0:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
