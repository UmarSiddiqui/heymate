#!/usr/bin/env python3
"""Loopback-only synthetic cookie/storage/form evidence for browser workers."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import sys
import threading
import time
from urllib.parse import parse_qs, urlparse

root = Path(sys.argv[1])
events = []
lock = threading.Lock()


def record(value):
    with lock:
        events.append(value)
        temporary = root / "events.tmp"
        temporary.write_text(json.dumps(events))
        temporary.replace(root / "events.json")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/event":
            record({key: values[0] for key, values in query.items()})
            content = b"ok"
        elif parsed.path == "/slow":
            record({"owner": "A", "navigation_started": "yes"})
            time.sleep(2)
            content = b"<title>Cancelled page</title><script>fetch('/event?owner=A&late_effect=yes')</script>"
        else:
            content = b'''<!doctype html><title>Worker fixture</title>
            <label>Benchmark name <input id="name"></label>
            <button onclick="fetch('/event?owner='+owner+'&saved='+encodeURIComponent(document.querySelector('input').value));document.querySelector('#out').textContent='Saved fixture'">Save fixture</button>
            <input type="password" aria-label="Password"><p id="out">Worker page</p>
            <script>
            const args=new URLSearchParams(location.search),owner=args.get('owner');
            if(args.has('seed')) {document.cookie='worker='+args.get('seed')+';path=/';localStorage.setItem('worker',args.get('seed'));}
            fetch('/event?owner='+owner+'&cookie='+encodeURIComponent(document.cookie||'empty')+'&storage='+encodeURIComponent(localStorage.getItem('worker')||'empty'));
            </script><div style="height:2400px"></div><p>Fixture bottom</p>'''
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        try:
            self.wfile.write(content)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the cancelled owned browser closes.


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port))
server.serve_forever()
