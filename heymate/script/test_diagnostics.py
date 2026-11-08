#!/usr/bin/env python3
"""Run production diagnostics with synthetic metadata and a loopback destination."""
import http.server
import json
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


class Collector(http.server.BaseHTTPRequestHandler):
    payloads = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        assert b'PRIVATE' not in data and b'/Users/' not in data
        payload = json.loads(data)
        assert set(payload) == {'api_key', 'batch'}
        for event in payload['batch']:
            assert set(event) == {'event', 'distinct_id', 'properties', 'timestamp', 'uuid'}
            fields = event['properties']
            assert set(fields) <= {'feature', 'outcome', 'provider', 'failure_category', 'count',
                                   'duration_ms', 'crash_app_version', 'app_version', 'os_version',
                                   'analytics_schema', 'diagnostics_category',
                                   '$process_person_profile', '$geoip_disable'}
            assert fields['$process_person_profile'] is False
            assert fields['$geoip_disable'] is True
        self.payloads.append(payload)
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()


def main():
    with tempfile.TemporaryDirectory(prefix='heymate-diagnostics-') as directory:
        root = Path(directory)
        probe = root / 'probe'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-parse-as-library',
                        'HeyMate/AppBundleConfiguration.swift', 'HeyMate/HeyMateAnalytics.swift',
                        'script/diagnostics_probe.swift', '-o', str(probe)], cwd=ROOT, check=True)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Collector)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run([str(probe), str(root), 'http://127.0.0.1:%d/' % server.server_port],
                           check=True, timeout=30)
            assert len(Collector.payloads) == 2
            assert {e['properties']['diagnostics_category'] for p in Collector.payloads for e in p['batch']} == {'product', 'crash'}
            print('PASS loopback collector received exactly two sanitized, separately consented envelopes')
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    main()
