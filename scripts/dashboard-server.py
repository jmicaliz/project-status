#!/usr/bin/env python3
"""Serve the dashboard and start or remove sessions through scripts/."""

from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from access import Verifier

ROOT = Path(__file__).resolve().parent.parent
STATUS_DIR = Path(os.environ.get("PROJECT_STATUS_DIR") or Path.home() / ".project-status")
TOKEN_FILE = STATUS_DIR / ".token"
START = ROOT / "scripts" / "start-session.sh"
REMOVE = ROOT / "scripts" / "remove-session.sh"
GENERATE = os.environ.get("PROJECT_STATUS_GENERATOR") or str(ROOT / "scripts" / "generate-status.sh")
MAX_BODY = 16384
MAX_PROMPT = 4000
ACCESS_HEADER = "Cf-Access-Jwt-Assertion"


def load_token() -> str:
    try:
        return TOKEN_FILE.read_text().strip()
    except FileNotFoundError:
        STATUS_DIR.mkdir(parents=True, exist_ok=True)
        token = secrets.token_urlsafe(24)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(token + "\n")
        return token


def script_error(result: subprocess.CompletedProcess) -> str:
    lines = (result.stderr or result.stdout or "").strip().splitlines()
    if not lines:
        return "Command failed"
    return lines[-1].removeprefix("start-session.sh: ").removeprefix("remove-session.sh: ")


class Handler(SimpleHTTPRequestHandler):
    token = ""
    access: Verifier | None = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT / "dashboard"), **kwargs)

    def end_headers(self):
        if self.command in ("GET", "HEAD") and not self.path.startswith("/api/"):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        if self.command != "GET":
            super().log_message(fmt, *args)

    def send_json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def access_denied(self) -> bool:
        if self.access is None:
            return False
        try:
            self.access.verify(self.headers.get(ACCESS_HEADER) or "")
        except Exception as exc:
            SimpleHTTPRequestHandler.log_message(self, "Access JWT rejected: %s", exc)
            self.send_json(401, {"error": "Cloudflare Access login required"})
            return True
        return False

    def do_HEAD(self):
        if not self.access_denied():
            super().do_HEAD()

    def do_GET(self):
        if self.access_denied():
            return
        if urlsplit(self.path).path == "/api/info":
            probe = subprocess.run([str(START), "--probe"], capture_output=True, text=True, timeout=10)
            info = json.loads(probe.stdout) if probe.returncode == 0 else {"remoteControl": False}
            return self.send_json(200, {"start": True, **info})
        super().do_GET()

    def do_POST(self):
        if self.access_denied():
            return
        route = urlsplit(self.path).path
        if route not in ("/api/start", "/api/remove"):
            return self.send_json(404, {"error": "Not found"})
        body = self.authorized_body()
        if body is None:
            return
        if route == "/api/start":
            repo = body.get("repo")
            prompt = body.get("prompt") or ""
            if not isinstance(repo, str) or not isinstance(prompt, str) or len(prompt) > MAX_PROMPT:
                return self.send_json(400, {"error": "Expected {repo, prompt?}"})
            args = [str(START), repo] + ([prompt] if prompt.strip() else [])
        else:
            session = body.get("id")
            if not isinstance(session, str):
                return self.send_json(400, {"error": "Expected {id}"})
            args = [str(REMOVE), session]
        self.run_script(args)

    def authorized_body(self):
        origin = self.headers.get("Origin")
        if origin and urlsplit(origin).netloc != self.headers.get("Host"):
            return self.send_json(403, {"error": "Cross-origin request refused"})
        if self.headers.get_content_type() != "application/json":
            return self.send_json(415, {"error": "Expected application/json"})
        supplied = self.headers.get("X-Project-Status-Token", "")
        if not hmac.compare_digest(supplied.encode(), self.token.encode()):
            return self.send_json(401, {"error": "Token missing or wrong", "needToken": True})
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = -1
        if not 0 < length <= MAX_BODY:
            return self.send_json(413, {"error": "Request body too large or empty"})
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            body = None
        if not isinstance(body, dict):
            return self.send_json(400, {"error": "Invalid JSON"})
        return body

    def run_script(self, args: list) -> None:
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            return self.send_json(504, {"error": "Claude took too long to respond"})
        if result.returncode != 0:
            return self.send_json(422, {"error": script_error(result)})
        done = json.loads(result.stdout)
        subprocess.run([GENERATE], capture_output=True, timeout=60)
        self.log_message("%s %s", Path(args[0]).stem, " ".join(args[1:2]))
        self.send_json(200, done)

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument(
        "--access",
        action="store_true",
        help="require a Cloudflare Access JWT on every request, configured by "
        "PROJECT_STATUS_ACCESS_TEAM_DOMAIN and PROJECT_STATUS_ACCESS_AUD",
    )
    opts = parser.parse_args()
    if opts.access:
        team_domain = os.environ.get("PROJECT_STATUS_ACCESS_TEAM_DOMAIN", "").strip()
        aud = os.environ.get("PROJECT_STATUS_ACCESS_AUD", "").strip()
        if not team_domain or not aud:
            parser.error("--access needs PROJECT_STATUS_ACCESS_TEAM_DOMAIN and PROJECT_STATUS_ACCESS_AUD")
        Handler.access = Verifier(team_domain, aud)
    Handler.token = load_token()
    server = ThreadingHTTPServer((opts.bind, opts.port), Handler)
    print(f"http://{opts.bind}:{opts.port}/  (start token in {TOKEN_FILE})", file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
