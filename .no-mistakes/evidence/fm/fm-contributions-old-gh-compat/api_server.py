"""Disposable GitHub REST stand-in with real Link-header pagination.

Serves the endpoints bin/fm-contributions.sh reads. Each endpoint holds a list
of pages; page N is served with a Link rel="next" header when a page N+1
exists, so a paginating client must follow it. Every request is appended to the
request log, which is the proof that later pages were actually fetched.
"""
import json
import os
import socketserver
import urllib.parse
from http.server import BaseHTTPRequestHandler

PORT = int(os.environ["API_PORT"])
PORT_FILE = os.environ.get("API_PORT_FILE")
BASE = os.environ.get("API_BASE", "")
STORE = os.environ["API_STORE"]
LOG = os.environ["API_LOG"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(parts.query)
        page = int(query.get("page", ["1"])[0])
        with open(LOG, "a") as handle:
            handle.write("GET %s\n" % self.path)
        with open(STORE) as handle:
            store = json.load(handle)
        body = None
        status = 404
        nxt = None
        pages = store.get(parts.path) or store.get(parts.path.split("?")[0])
        if pages is None:
            # Path with a query: match on the bare path key.
            for key, value in store.items():
                if key.startswith("__") or "?" in key:
                    continue
                if parts.path == key:
                    pages = value
                    break
        if pages is not None:
            if page > len(pages):
                body = json.dumps([]).encode()
            else:
                item = pages[page - 1]
                if item == "__malformed__":
                    body = b'{"id": 7, "user": {"login": '  # truncated JSON
                else:
                    body = json.dumps(item).encode()
            status = 200
            if page < len(pages):
                query = parts.query or "per_page=100"
                if "per_page" not in query:
                    query = "per_page=100&" + query
                nxt = "%s%s?%s&page=%d" % (base, parts.path, query, page + 1)
        if body is None:
            body = json.dumps({"message": "not found", "documentation_url": "x"}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if nxt:
            self.send_header("Link", '<%s>; rel="next"' % nxt)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


socketserver.ThreadingTCPServer.allow_reuse_address = True
server = socketserver.ThreadingTCPServer(("127.0.0.1", PORT), Handler)
base = BASE or "http://127.0.0.1:%d" % server.server_address[1]
if PORT_FILE:
    with open(PORT_FILE, "w") as handle:
        handle.write(str(server.server_address[1]))
server.serve_forever()
