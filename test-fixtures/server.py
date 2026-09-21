#!/usr/bin/env python3
"""Local-only fixtures for browser dialogs, authentication, and downloads."""

from base64 import b64decode, b64encode
from hashlib import sha1
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import struct
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
        if path == "/identity/lookalike":
            return self.send_bytes((ROOT / "identity-lookalike.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/inbox":
            return self.send_inbox()
        if path == "/public-article":
            return self.send_bytes((ROOT / "public-article.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/contact":
            return self.send_bytes((ROOT / "contact.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/runtime":
            return self.send_bytes((ROOT / "runtime.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/history/a":
            return self.send_bytes((ROOT / "history-a.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/history/b":
            return self.send_bytes((ROOT / "history-b.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/sw.js":
            return self.send_bytes((ROOT / "sw.js").read_bytes(), "text/javascript; charset=utf-8")
        if path == "/ws":
            return self.websocket_echo()
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

    def send_inbox(self):
        data = (ROOT / "inbox.html").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Set-Cookie", "SID=fixture-session; Path=/; HttpOnly; SameSite=Lax")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def websocket_echo(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if self.headers.get("Upgrade", "").lower() != "websocket" or not key:
            return self.send_error(426, "Upgrade to WebSocket required")
        accept = b64encode(sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        payload = self.read_ws_text()
        self.write_ws_text(payload or "pong")

    def read_ws_text(self):
        header = self.rfile.read(2)
        if len(header) < 2:
            return ""
        length = header[1] & 127
        if length == 126:
            length = struct.unpack(">H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if header[1] & 128 else b""
        data = self.rfile.read(length)
        if mask:
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
        return data.decode("utf-8", errors="replace")

    def write_ws_text(self, text):
        payload = text.encode()
        header = bytearray([0x81])
        if len(payload) < 126:
            header.append(len(payload))
        elif len(payload) < 65536:
            header.append(126)
            header.extend(struct.pack(">H", len(payload)))
        else:
            header.append(127)
            header.extend(struct.pack(">Q", len(payload)))
        self.wfile.write(header + payload)
        self.wfile.flush()

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
