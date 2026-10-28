#!/usr/bin/env python3
"""Build the locked HeyMate Pi harness using a caller-supplied Node binary."""
import argparse
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def build(out, node, npm):
    if out.exists():
        raise ValueError('Output already exists; choose a new runtime directory.')
    spec = importlib.util.spec_from_file_location('pi_stage', ROOT / 'scripts/pi-runtime-stage.py')
    stage = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(stage)
    stage.verify_node_dependencies(node)
    version = subprocess.check_output([str(node), '--version'], text=True).strip()
    numbers = tuple(map(int, version.lstrip('v').split('.')))
    if numbers < (22, 19, 0):
        raise ValueError('Pi requires Node 22.19.0 or later.')
    arch = subprocess.check_output([str(node), '-p', 'process.arch'], text=True).strip()
    architecture = {'arm64': 'arm64', 'x64': 'x86_64'}[arch]
    source = ROOT / 'agent-runtime'
    out.mkdir(parents=True)
    for name in ('src', 'bin'):
        shutil.copytree(source / name, out / name)
    for name in ('package.json', 'package-lock.json'):
        shutil.copy2(source / name, out / name)
    shutil.copy2(node, out / 'bin/node')
    # Execute the copied binary before signing/staging. A working source on
    # the build machine does not prove its relocatable payload can launch.
    copied_version = subprocess.check_output([str(out / 'bin/node'), '--version'], text=True).strip()
    if copied_version != version:
        raise ValueError('Copied Node version differs from the source.')
    license_file = node.parent.parent / 'LICENSE'
    if not license_file.is_file():
        raise ValueError('Node distribution LICENSE is required alongside its bin directory.')
    shutil.copy2(license_file, out / 'NODE-LICENSE')
    environment = dict(os.environ, PATH=str(node.parent) + os.pathsep + os.environ.get('PATH', ''))
    subprocess.run([str(npm), 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'],
                   cwd=out, env=environment, check=True)
    # Retain only this payload's platform-native TUI helper. SDK use does not
    # install/build tools at runtime; all resource bytes are sealed in the app.
    native = out / 'node_modules/@earendil-works/pi-tui/native'
    for platform in ('win32', 'linux'):
        if (native / platform).exists():
            shutil.rmtree(native / platform)
    prebuilds = native / 'darwin/prebuilds'
    if prebuilds.exists():
        for candidate in prebuilds.iterdir():
            if candidate.name != 'darwin-' + arch:
                shutil.rmtree(candidate)
    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip()
    files, native_images, native_digests = {}, [], {}
    for file in sorted(out.rglob('*')):
        if not file.is_file():
            continue
        relative = file.relative_to(out).as_posix()
        magic = file.open('rb').read(4)
        if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            native_images.append(relative)
            native_digests[relative] = hashlib.sha256(file.read_bytes()).hexdigest()
        else:
            files[relative] = hashlib.sha256(file.read_bytes()).hexdigest()
    if 'bin/node' not in native_images:
        raise ValueError('A macOS Mach-O Node binary is required.')
    manifest = {'schema': 1, 'engine': 'heymate-pi', 'piVersion': '1.4.0', 'nodeVersion': version,
                'sourceCommit': commit, 'architecture': architecture,
                'executablePath': 'bin/heymate-agent', 'runtimePath': 'bin',
                'files': files, 'nativeImages': native_images, 'nativeDigests': native_digests}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    subprocess.run([sys.executable, str(ROOT / 'scripts/pi-runtime-smoke.py'), '--root', str(out)], check=True)
    print(f'Prepared HeyMate Pi harness ({architecture}, Node {version})')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=pathlib.Path, required=True)
    parser.add_argument('--node', type=pathlib.Path, default=os.environ.get('HEYMATE_NODE_BINARY') or shutil.which('node'))
    parser.add_argument('--npm', type=pathlib.Path, default=shutil.which('npm'))
    args = parser.parse_args()
    build(args.out.resolve(), args.node.resolve(), args.npm.resolve())
