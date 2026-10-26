#!/usr/bin/env python3
"""Start only a scratch-profile harness and check its attested local API."""
import argparse
import json
import pathlib
import platform
import secrets
import selectors
import subprocess
import tempfile
import urllib.error
import urllib.request


def smoke(payload):
    manifest = json.loads((payload / 'manifest.json').read_text())
    if 'payloads' in manifest:
        architecture = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
        payload = payload / manifest['payloads'][architecture]
        manifest = json.loads((payload / 'manifest.json').read_text())
    with tempfile.TemporaryDirectory(prefix='heymate-pi-smoke-') as scratch:
        token = secrets.token_hex(32)
        child = subprocess.Popen([str(payload / manifest['executablePath']), 'serve'],
            env={'PATH': '/usr/bin:/bin', 'HEYMATE_AGENT_HOME': scratch,
                 'HEYMATE_AGENT_DASHBOARD_SESSION_TOKEN': token},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            selector = selectors.DefaultSelector()
            selector.register(child.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=30):
                raise RuntimeError('Harness did not announce readiness.')
            line = child.stdout.readline().strip()
            prefix = 'HEYMATE_AGENT_BACKEND_READY port='
            if not line.startswith(prefix):
                raise RuntimeError('Invalid harness readiness.')
            port = int(line[len(prefix):])
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

            def get(route, authorized=True):
                headers = {'X-HeyMate-Agent-Token': token} if authorized else {}
                with opener.open(urllib.request.Request(f'http://127.0.0.1:{port}' + route, headers=headers), timeout=10) as response:
                    return json.load(response)

            identity = get('/api/host/identity')
            assert identity['pid'] == child.pid and identity['engine'] == 'pi'
            assert get('/api/status')['agent_home'] == str(pathlib.Path(scratch).resolve())
            assert get('/api/health')['commit'] == manifest['sourceCommit']
            try:
                get('/api/status', False)
                raise AssertionError('Unauthenticated API succeeded.')
            except urllib.error.HTTPError as error:
                assert error.code == 401
            print('PASS: bundled Pi harness startup, ownership and authentication; no model requests')
        finally:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--payload', type=pathlib.Path, required=True)
    smoke(parser.parse_args().payload.resolve())
