#!/usr/bin/env python3
import http.server
import json
import os
import socketserver
import sys

version = os.environ.get("FIXTURE_VERSION", "v1.0.0-rc.21")
theme = os.environ.get("FIXTURE_THEME", "default")
revision = os.environ.get("FIXTURE_REVISION", "037710ec037710ec037710ec037710ec037710ec")
linuxdo = os.environ.get("FIXTURE_LINUXDO", "false") == "true"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        cache_control = None
        if self.path == "/build-info.json":
            body = json.dumps(
                {
                    "schema": 1,
                    "version": version,
                    "theme": theme,
                    "revision": revision,
                }
            ).encode()
            content_type = "application/json"
            cache_control = "no-store, no-cache, must-revalidate, max-age=0"
        elif self.path == "/api/status":
            body = json.dumps({"success": True, "data": {"version": version, "theme": theme, "linuxdo_oauth": linuxdo}}).encode()
            content_type = "application/json"
        elif self.path == "/dashboard":
            body = b"<!doctype html><html><body>dashboard</body></html>"
            content_type = "text/html"
            cache_control = "no-store, no-cache, must-revalidate, max-age=0"
        elif self.path == "/assets/missing.js":
            self.send_error(404)
            return
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        if cache_control:
            self.send_header("Cache-Control", cache_control)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), Handler) as server:
    server.serve_forever()
