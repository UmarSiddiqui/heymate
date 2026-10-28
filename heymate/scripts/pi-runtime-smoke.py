#!/usr/bin/env python3
"""Launch the packaged backend in a disposable profile, never a second GUI."""
import argparse
import json
import os
import pathlib
import secrets
import selectors
import subprocess
import tempfile
import time
import urllib.request


def verify(root):
    root = root.resolve()
    with tempfile.TemporaryDirectory(prefix='heymate-backend-smoke-') as scratch:
        token = secrets.token_urlsafe(32)
        environment = dict(os.environ, HEYMATE_AGENT_HOME=scratch,
                           HEYMATE_AGENT_DASHBOARD_SESSION_TOKEN=token,
                           HEYMATE_AGENT_DISABLE_LAZY_INSTALLS='1')
        # Exercise the packaged WASM dependency from the copied payload, not
        # this checkout's node_modules. No GUI, credentials or external tools.
        probe = '''
const { runRecoveredScript } = await import(process.argv[1]);
const result = await runRecoveredScript('text(await tools.fixture({value:7}))', {
  hasTool: name => name === 'fixture',
  callTool: async () => ({text:'{"value":7}',ok:true})
});
if (!result.ok || result.calls !== 1 || !result.output.includes('7')) throw Error('Packaged H1 runner failed');
console.log('PASS: packaged recovered H1 runner and QuickJS WASM execute isolated tool program.');
'''
        subprocess.run([str(root / 'bin/node'), '--input-type=module', '-e', probe,
                        (root / 'src/script-tools.mjs').as_uri()], cwd=scratch,
                       env=environment, check=True, timeout=15)
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen([str(root / 'bin/heymate-agent'), 'serve', '--isolated',
                                        '--host', '127.0.0.1', '--port', '0', '--no-open'],
                                       cwd=scratch, env=environment, stdout=subprocess.PIPE,
                                       stderr=errors, text=True)
            try:
                deadline = time.monotonic() + 30
                port = None
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    while time.monotonic() < deadline and process.poll() is None:
                        if not selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                            continue
                        line = process.stdout.readline().strip()
                        if line.startswith('HEYMATE_AGENT_BACKEND_READY port='):
                            port = int(line.split('=', 1)[1])
                            break
                if port is None:
                    errors.seek(0)
                    detail = errors.read().decode(errors='replace')[-2000:]
                    raise RuntimeError('Packaged backend did not become ready: ' + detail)
                for route in ['host/identity', 'health', 'config']:
                    request = urllib.request.Request(f'http://127.0.0.1:{port}/api/{route}',
                                                     headers={'x-heymate-agent-token': token})
                    with urllib.request.urlopen(request, timeout=5) as response:
                        result = json.load(response)
                    if route == 'host/identity' and (result.get('pid') != process.pid or result.get('engine') != 'pi'):
                        raise RuntimeError('Backend identity did not match the owned process.')
                    if route == 'health' and not result.get('ok'):
                        raise RuntimeError('Backend health check failed.')
                print('PASS: packaged backend starts; owned identity, health and config respond.')
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                process.stdout.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=pathlib.Path, required=True)
    verify(parser.parse_args().root)
