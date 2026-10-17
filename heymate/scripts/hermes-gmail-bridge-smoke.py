#!/usr/bin/env python3
"""Exercise shipped Node bridge and real Hermes MCP discovery, with local Gmail fixtures.
No provider/model calls, real accounts, or email sends. Pass --payload for a sealed Hermes bundle.
"""
import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--payload', type=Path)
    args = parser.parse_args()
    if args.payload:
        import platform
        args.payload = args.payload.resolve()
        manifest = json.loads((args.payload / 'manifest.json').read_text())
        if 'payloads' in manifest:
            arch = 'arm64' if platform.machine().lower() in ('arm64', 'aarch64') else 'x86_64'
            args.payload = args.payload / manifest['payloads'][arch]
    source = (Path(__file__).resolve().parents[1] / 'HeyMate/HeyMateMCPServer.swift').read_text()
    script = source.split('static let serverSource = #"""', 1)[1].split('"""#', 1)[0]
    # Swift multiline literals strip common indentation.
    import textwrap
    script = textwrap.dedent(script).lstrip('\n')
    state = {'active': True, 'calls': [], 'unscoped': 0}
    token, scope = secrets.token_hex(24), secrets.token_hex(24)
    tool = {'name': 'composio__COMPOSIO_SEARCH_TOOLS', 'description': 'Search fixture Gmail tools',
            'inputSchema': {'type': 'object', 'properties': {'query': {'type': 'string'}}}}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert self.headers.get('Authorization') == 'Bearer ' + token
            assert data.get('scope') == scope
            if self.path == '/talk/connector-tools':
                result = {'tools': [tool] if state['active'] else []}
            elif self.path == '/talk/connector-call':
                if not state['active']:
                    result = {'text': 'Conversation scope expired', 'isError': True}
                else:
                    state['calls'].append(data)
                    result = {'text': json.dumps({'tools': [{'tool_slug': 'GMAIL_FETCH_EMAILS'}]}), 'isError': False}
            else:
                state['unscoped'] += 1
                result = {'text': 'Unscoped route refused', 'isError': True}
            payload = json.dumps(result).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='heymate-gmail-smoke-') as directory:
        root = Path(directory)
        bridge = root / 'bridge.mjs'
        bridge.write_text(script)
        context = root / 'context.json'
        context.write_text(json.dumps({'HEYMATE_BRIDGE_URL': f'http://127.0.0.1:{server.server_port}',
                                      'HEYMATE_BRIDGE_TOKEN': token}))
        context.chmod(0o600)
        if args.payload:
            manifest = json.loads((args.payload / 'manifest.json').read_text())
            tools = args.payload / manifest['runtimePath']
            facts = json.loads((tools / 'facts.json').read_text())
            node = str(tools / facts['packages']['node']['entry'] / 'bin/node')
        else:
            node = shutil.which('node')
        assert node, 'Node runtime required'
        env = dict(os.environ, HEYMATE_TALK_SCOPE=scope, HEYMATE_SCOPED_ONLY='1', HEYMATE_BRIDGE_CONTEXT_FILE=str(context))
        child = subprocess.Popen([node, str(bridge)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        counter = 0

        def rpc(method, params):
            nonlocal counter
            counter += 1
            child.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': counter, 'method': method, 'params': params}) + '\n')
            child.stdin.flush()
            line = child.stdout.readline()
            assert line, child.stderr.read()
            response = json.loads(line)
            assert response['id'] == counter
            return response['result']

        try:
            rpc('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'fixture', 'version': '1'}})
            assert rpc('tools/list', {})['tools'] == [tool]
            result = rpc('tools/call', {'name': tool['name'], 'arguments': {'query': 'Gmail inbox'}})
            assert not result['isError']
            assert state['calls'][0]['tool'] == tool['name']
            assert state['calls'][0]['arguments'] == '{"query":"Gmail inbox"}'
            assert rpc('tools/call', {'name': 'heymate_create_mate', 'arguments': {}})['isError']
            state['active'] = False
            assert rpc('tools/call', {'name': tool['name'], 'arguments': {}})['isError']
            assert rpc('tools/list', {})['tools'] == []
            assert state['unscoped'] == 0
        finally:
            child.terminate()
            child.wait(timeout=5)
        print('PASS: real Node MCP discovery, scoped Gmail search, expired scope, blocked native tools; zero unscoped calls')
        state['active'] = True
        if args.payload:
            asyncio.run(probe_hermes(args.payload.resolve(), root, node, bridge, context, scope, tool))
    server.shutdown()


async def probe_hermes(payload, root, node, bridge, context, scope, tool):
    # Run this script with the payload's Python and site-packages for websockets.
    import websockets
    manifest = json.loads((payload / 'manifest.json').read_text())
    home = root / 'profile'
    home.mkdir(mode=0o700)
    ready = root / 'ready.json'
    owner_token = secrets.token_hex(32)
    env = dict(os.environ, HERMES_HOME=str(home), HERMES_RUNTIME_DIR=str(payload / manifest['runtimePath']),
               HERMES_DISABLE_LAZY_INSTALLS='1', HERMES_DESKTOP='1', HERMES_DASHBOARD_SESSION_TOKEN=owner_token,
               HERMES_DESKTOP_READY_FILE=str(ready), PYTHONPYCACHEPREFIX=str(root / 'pycache'))
    with (root / 'hermes.log').open('w') as log:
        child = subprocess.Popen([str(payload / manifest['executablePath']), 'serve', '--isolated', '--host', '127.0.0.1', '--port', '0', '--no-open'], env=env, cwd=home, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            while not ready.exists():
                assert time.monotonic() < deadline and child.poll() is None, 'Hermes readiness failed'
                await asyncio.sleep(.1)
            port = json.loads(ready.read_text())['port']
            async with websockets.connect(f'ws://127.0.0.1:{port}/api/ws?token={owner_token}', additional_headers={'Origin': f'http://127.0.0.1:{port}'}) as socket:
                sequence = 0
                async def rpc(method, params):
                    nonlocal sequence
                    sequence += 1
                    await socket.send(json.dumps({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': params}))
                    while True:
                        value = json.loads(await asyncio.wait_for(socket.recv(), timeout=90))
                        if value.get('id') == sequence:
                            assert 'error' not in value, value.get('error')
                            return value['result']
                added = await rpc('mcp.servers.add', {'name': 'heymate_fixture', 'config': {'command': node, 'args': [str(bridge)],
                    'env': {'HEYMATE_TALK_SCOPE': scope, 'HEYMATE_SCOPED_ONLY': '1', 'HEYMATE_BRIDGE_CONTEXT_FILE': str(context)}}})
                assert added['ok']
                refreshed = await rpc('reload.mcp', {'confirm': True})
                assert refreshed['status'] == 'reloaded', refreshed
                tested = await rpc('mcp.servers.test', {'name': 'heymate_fixture'})
                assert tested['ok'] and any(row['name'] == tool['name'] for row in tested['tools']), tested
                await rpc('mcp.servers.remove', {'name': 'heymate_fixture'})
                print('PASS: Hermes runtime adds, reloads, discovers, removes scoped HeyMate MCP tools; zero model calls')
        finally:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


if __name__ == '__main__':
    main()
