#!/usr/bin/env python3
"""Exercise the installed signed helper's EOF and SIGTERM cleanup. No GUI."""
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.request


def processes():
    result = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3:
            result[int(parts[0])] = (int(parts[1]), parts[2])
    return result


def check(models, mode):
    helper = subprocess.Popen(['/Applications/HeyMate.app/Contents/Helpers/HeyMateSpeechRunner'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    server = None
    try:
        request = dict(operation='servePhonon', text='', voice='Zoey', speed=1, modelDirectory=str(models))
        helper.stdin.write((json.dumps(request) + '\n').encode())
        helper.stdin.flush()
        if not select.select([helper.stdout], [], [], 40)[0]:
            raise AssertionError('Helper startup timeout')
        reply = json.loads(helper.stdout.readline())
        assert not reply.get('error'), reply.get('error')
        server = reply['service']['pid']
        request = urllib.request.Request('http://127.0.0.1:%d/v1/audio/speech' % reply['port'],
                                        json.dumps(dict(model='phonon', voice='Zoey',
                                                        input='Speech worker lifetime check.', response_format='pcm')).encode(),
                                        {'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=45) as response:
            audio = response.read()
        assert len(audio) > 24_000 and len(audio) % 2 == 0
        workers = [pid for pid, (parent, command) in processes().items()
                   if parent == server and '/PhononRuntime/ollama runner' in command]
        assert workers, 'No MLX worker started'
        if mode == 'EOF':
            helper.stdin.close()
        else:
            helper.send_signal(signal.SIGTERM)
        helper.wait(timeout=8)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            remaining = set([server] + workers) & set(processes())
            if not remaining:
                print('PASS %s: signed helper, server and MLX worker exit' % mode, flush=True)
                return
            time.sleep(0.05)
        raise AssertionError('Workers survived %s: %r' % (mode, remaining))
    finally:
        if helper.poll() is None:
            helper.terminate()
            helper.wait(timeout=8)
        if server is not None and server in processes():
            parent, command = processes()[server]
            # This test owns only the server returned by its private helper.
            if command == '/Applications/HeyMate.app/Contents/Resources/PhononRuntime/ollama serve' and os.getpgid(server) == server:
                os.killpg(server, signal.SIGTERM)


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='heymate-phonon-lifetime-') as directory:
        models = Path(directory) / 'models'
        shutil.copytree('/Applications/HeyMate.app/Contents/Resources/PhononRuntime/models', models)
        check(models, 'EOF')
        check(models, 'SIGTERM')
