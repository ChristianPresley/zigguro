#!/usr/bin/env python3
"""Smart HTTP test server for zg_git: runs `git http-backend` as a CGI for
every request under the project root given as argv[1]. With argv[2]
("user:password") it requires that Basic credential. Prints the port it
listens on (127.0.0.1) and serves until killed or stdin closes."""

import base64
import http.server
import os
import subprocess
import sys
import threading

root = sys.argv[1]
auth = sys.argv[2] if len(sys.argv) > 2 else None


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.cgi()

    def do_POST(self):
        self.cgi()

    def cgi(self):
        if auth is not None:
            want = "Basic " + base64.b64encode(auth.encode()).decode()
            if self.headers.get("Authorization", "") != want:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="git"')
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        path, _, query = self.path.partition("?")
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        env = dict(os.environ)
        env.update(
            GIT_PROJECT_ROOT=root,
            GIT_HTTP_EXPORT_ALL="1",
            PATH_INFO=path,
            QUERY_STRING=query,
            REQUEST_METHOD=self.command,
            CONTENT_TYPE=self.headers.get("Content-Type", ""),
            CONTENT_LENGTH=str(len(body)),
            REMOTE_USER="tester",
            REMOTE_ADDR="127.0.0.1",
        )
        proto = self.headers.get("Git-Protocol")
        if proto:
            env["GIT_PROTOCOL"] = proto
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, data = out.partition(b"\r\n\r\n")
        status = 200
        headers = []
        for line in head.split(b"\r\n"):
            k, _, v = line.decode().partition(":")
            if k.lower() == "status":
                status = int(v.strip().split()[0])
            elif k:
                headers.append((k, v.strip()))
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
# Exit when the test closes our stdin.
sys.stdin.read()
