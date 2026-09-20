#!/usr/bin/env python3
"""Local-only fixtures for browser dialogs, authentication, and downloads."""

from base64 import b64decode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time

ROOT = Path(__file__).resolve().parent
HOST = "127.0.0.1"
PORT = 8765
PAYLOAD = (b"Interlinked download fixture\n" * 8192)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = self.path.partition("?")[0]
        if path == "/":
            return self.send_bytes((ROOT / "web-capabilities.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/auth/basic":
            expected = "fixture:interlinked"
            supplied = self.headers.get("Authorization", "")
            if supplied.startswith("Basic "):
                try:
                    if b64decode(supplied[6:]).decode() == expected:
                        return self.send_bytes(b"Basic authentication completed.\n", "text/plain")
                except (ValueError, UnicodeDecodeError):
                    pass
            return self.challenge('Basic realm="Interlinked fixture"')
        if path == "/auth/digest":
            if self.headers.get("Authorization", "").startswith("Digest "):
                return self.send_bytes(b"Digest authentication completed.\n", "text/plain")
            return self.challenge('Digest realm="Interlinked fixture", nonce="interlinked", algorithm=MD5, qop="auth"')
        if path == "/popup/child":
            return self.popup_child("GET", "")
        if path == "/popup/blocked":
            return self.send_bytes(b"<!doctype html><title>Blocked popup opened</title><h1>Blocked popup opened</h1>", "text/html; charset=utf-8")
        if path == "/navigation/target":
            return self.send_bytes(b"<!doctype html><title>Navigation completed</title><h1>Navigation completed</h1>", "text/html; charset=utf-8")
        if path == "/redirect/cross-site":
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{PORT}/navigation/target")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path in {"/download/known", "/download/duplicate"}:
            return self.download(PAYLOAD, "fixture.txt", include_length=True)
        if path == "/download/unknown":
            return self.download(PAYLOAD, "unknown-length.txt", include_length=False)
        if path == "/download/slow":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="slow-fixture.bin"')
            self.send_header("Content-Length", str(len(PAYLOAD) * 8))
            self.end_headers()
            for _ in range(8):
                try:
                    self.wfile.write(PAYLOAD)
                    self.wfile.flush()
                    time.sleep(0.5)
                except (BrokenPipeError, ConnectionResetError):
                    break
            return
        if path == "/download/failure":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="broken-fixture.bin"')
            self.send_header("Content-Length", str(len(PAYLOAD) * 4))
            self.end_headers()
            self.wfile.write(PAYLOAD[:1024])
            self.wfile.flush()
            self.close_connection = True
            return
        self.send_error(404)

    def do_POST(self):
        if self.path == "/popup/post":
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
            return self.popup_child("POST", body)
        self.send_error(404)

    def popup_child(self, method, body):
        escaped = body.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        page = f"""<!doctype html>
<meta charset="utf-8"><title>{method} popup child</title>
<h1>{method} popup child</h1><p id="body">{escaped}</p>
<button id="close">Close this popup</button>
<script>
  if (window.opener) window.opener.postMessage({{kind: 'popup', method: {method!r}, body: {body!r}}}, '*');
  document.querySelector('#close').onclick = () => window.close();
</script>""".encode()
        return self.send_bytes(page, "text/html; charset=utf-8")

    def challenge(self, value):
        body = b"Authentication required.\n"
        self.send_response(401)
        self.send_header("WWW-Authenticate", value)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def download(self, data, filename, include_length):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        if include_length:
            self.send_header("Content-Length", str(len(data)))
        else:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(data)

    def send_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        print(f"{self.client_address[0]} {format % args}")


if __name__ == "__main__":
    print(f"Interlinked fixtures: http://{HOST}:{PORT}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
