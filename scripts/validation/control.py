#!/usr/bin/env python3
"""Private loopback controls for the Discord playlist validation client."""
import argparse
import hmac
import json
import os
from pathlib import Path
import re
import secrets
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler

DEFAULTS = {"soundCheck": True, "autoMix": True}
ENDPOINT = re.compile(r"/v4/plugins/swapping/sessions/[A-Za-z0-9_-]{1,128}/players/[0-9]{1,20}\Z")


def read_json(path, fallback):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return fallback


def validate_settings(body):
    if not isinstance(body, dict) or set(body) != set(DEFAULTS):
        raise ValueError("Expected soundCheck and autoMix")
    if any(type(value) is not bool for value in body.values()):
        raise ValueError("Settings must be booleans")
    return body


def save_settings(path, settings):
    validate_settings(settings)
    temporary = path.with_suffix(".pending")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(settings, output)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Control:
    def __init__(self, env_path):
        self.private = env_path.resolve().parent
        config = {}
        for line in env_path.read_text().splitlines():
            key, separator, value = line.strip().partition("=")
            if separator:
                config[key] = value.strip('"')
        self.origin = config.get("LIXI_URL", "http://127.0.0.1:2333").rstrip("/")
        parts = urlsplit(self.origin)
        if parts.scheme not in ("http", "https") or parts.hostname not in ("127.0.0.1", "localhost", "::1") or parts.username or parts.path:
            raise ValueError("Controls require a loopback LIXI_URL")
        self.password = config["LIXI_PASSWORD"]
        self.csrf = secrets.token_urlsafe(32)
        self.settings_path = self.private / "swapping.json"
        self.state_path = self.private / "state" / "control.json"
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def api(self, method="GET", body=None):
        state = read_json(self.state_path, {})
        endpoint = state.get("endpoint", "")
        if not isinstance(endpoint, str) or not ENDPOINT.fullmatch(endpoint):
            return None
        request = Request(self.origin + endpoint, method=method,
                          headers={"Authorization": self.password, "Content-Type": "application/json"},
                          data=None if body is None else json.dumps(body).encode())
        try:
            with self.opener.open(request, timeout=3) as response:
                data = response.read(262145)
                if len(data) > 262144:
                    raise ValueError("Oversized control response")
                return json.loads(data)
        except HTTPError as error:
            if error.code == 404:
                return None
            raise ValueError(f"Player settings rejected (HTTP {error.code})") from None
        except (URLError, TimeoutError):
            return None

    def state(self):
        desired = validate_settings(read_json(self.settings_path, dict(DEFAULTS)))
        live = self.api()
        return {"desired": desired, "live": live, "active": live is not None and live.get("enabled", False)}


def handler(control, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def valid_host(self):
            return self.headers.get("Host") in (f"127.0.0.1:{port}", f"localhost:{port}")

        def respond(self, status, data, content_type="application/json"):
            body = json.dumps(data).encode() if content_type == "application/json" else data
            self.send_response(status)
            self.send_header("Content-Type", content_type + "; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-" + control.csrf + "'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if not self.valid_host():
                self.respond(403, {"error": "Invalid host"})
            elif self.path == "/":
                html = Path(__file__).with_name("control.html").read_text().replace("__NONCE__", control.csrf)
                self.respond(200, html.encode(), "text/html")
            elif self.path == "/api/state":
                try:
                    self.respond(200, control.state())
                except (ValueError, OSError):
                    self.respond(502, {"error": "Could not read control state"})
            else:
                self.respond(404, {"error": "Not found"})

        def do_POST(self):
            origin = self.headers.get("Origin", "")
            csrf = self.headers.get("X-Lixi-Control", "")
            if not self.valid_host() or origin not in (f"http://127.0.0.1:{port}", f"http://localhost:{port}") or not hmac.compare_digest(csrf, control.csrf):
                self.respond(403, {"error": "Invalid control request"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if self.path != "/api/settings" or self.headers.get_content_type() != "application/json" or not 0 < length <= 1024:
                    self.respond(400, {"error": "Invalid settings request"})
                    return
                settings = validate_settings(json.loads(self.rfile.read(length)))
                control.api("PUT", settings)
                save_settings(control.settings_path, settings)
                self.respond(200, control.state())
            except (ValueError, OSError):
                self.respond(409, {"error": "Could not apply settings"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", required=True, type=Path)
    parser.add_argument("--port", default=2334, type=int)
    args = parser.parse_args()
    control = Control(args.env)
    server = HTTPServer(("127.0.0.1", args.port), handler(control, args.port))
    server.timeout = 5
    print(f"Swapping controls: http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
