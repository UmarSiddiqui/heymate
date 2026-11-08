#!/usr/bin/env python3
"""Production Swift transport against a disposable HTTP server/helper/model store."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


class Handler(http.server.BaseHTTPRequestHandler):
    mode = ''
    calls = 0

    def log_message(self, *_):
        pass

    def do_POST(self):
        type(self).calls += 1
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        assert request['model'] == 'phonon' and request['voice'] == 'Zoey'
        assert request['response_format'] == 'pcm' and 'speed' not in request
        if self.mode == 'voice':
            status, body = 400, b'{"error":{"message":"voice PRIVATE not found; /Users/PRIVATE token PRIVATE"}}'
        elif self.mode == 'fail' or (self.mode == 'recover' and self.calls == 1):
            status, body = 500, b'{"error":{"message":"load tokenizer: no such file /Users/PRIVATE https://PRIVATE"}}'
        else:
            status, body = 200, b'\x00\x40' * 1200
        self.send_response(status)
        self.send_header('Content-Length', str(len(body) + (2400 if self.mode == 'partial' else 0)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        if self.mode == 'partial':
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()


def main():
    with tempfile.TemporaryDirectory(prefix='heymate-phonon-regression-') as directory:
        root = Path(directory)
        probe = root / 'probe'
        sources = ['HeyMate/PhononEngine.swift', 'HeyMate/KokoroSpeechProcess.swift',
                   'HeyMate/SpeechRunnerProtocol.swift', 'HeyMate/HeyMateDataDirectory.swift',
                   'script/phonon_transport_probe.swift']
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                        *sources, '-o', str(probe)], cwd=ROOT, check=True)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        helper = root / 'helper'
        helper.write_text('#!/usr/bin/env python3\nimport json,sys,os\n'
                          'for line in sys.stdin:\n'
                          ' with open(os.environ["PHONON_STARTS"],"a") as f: f.write("start\\n")\n'
                          ' print(json.dumps({"port":int(os.environ["PHONON_PORT"])}),flush=True)\n')
        helper.chmod(0o700)
        try:
            for mode, expected_calls in [('cache', 0), ('voice', 1), ('fail', 2), ('recover', 2), ('partial', 1)]:
                resources = root / mode
                models = resources / 'models'
                blobs = models / 'blobs'
                blobs.mkdir(parents=True)
                data = b'synthetic model blob'
                digest = 'sha256:' + hashlib.sha256(data).hexdigest()
                (blobs / digest.replace(':', '-')).write_bytes(data)
                manifest = models / 'manifests/registry.ollama.ai/library/phonon/latest'
                manifest.parent.mkdir(parents=True)
                manifest.write_text(json.dumps({'config': {'digest': digest, 'size': len(data)}, 'layers': []}))
                starts = root / (mode + '-starts')
                Handler.mode, Handler.calls = mode, 0
                environment = dict(os.environ, PHONON_PORT=str(server.server_port), PHONON_STARTS=str(starts))
                subprocess.run([str(probe), str(resources), str(root / (mode + '-cache')), str(helper), mode],
                               env=environment, check=True, timeout=30)
                assert Handler.calls == expected_calls, (mode, Handler.calls)
                assert (len(starts.read_text().splitlines()) if starts.exists() else 0) == expected_calls
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
