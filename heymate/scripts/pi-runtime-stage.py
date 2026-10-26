#!/usr/bin/env python3
"""Verify, stage and sign only the nested executables of a prepared Pi harness."""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile


def child(root, relative, allow_root=False):
    if not isinstance(relative, str) or pathlib.PurePath(relative).is_absolute() or '..' in pathlib.PurePath(relative).parts:
        raise ValueError('Runtime path escapes payload.')
    candidate = (root / relative).resolve()
    if candidate != root and root not in candidate.parents:
        raise ValueError('Runtime symlink escapes payload.')
    if candidate == root and not allow_root:
        raise ValueError('Runtime file points to payload root.')
    if not candidate.exists():
        raise ValueError('Runtime member missing: ' + relative)
    return candidate


def verify(root, expected_arch=None, pristine=False):
    root = root.resolve()
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('engine') != 'heymate-pi' or manifest.get('schema') != 1:
        raise ValueError('Not a HeyMate Pi harness payload.')
    if 'payloads' in manifest:
        for arch, relative in manifest['payloads'].items():
            nested = verify(child(root, relative), arch, pristine=pristine)
            if nested['sourceCommit'] != manifest['sourceCommit']:
                raise ValueError('Mixed harness source revisions.')
        return manifest
    if expected_arch and manifest['architecture'] != expected_arch:
        raise ValueError('Runtime architecture mismatch.')
    if manifest.get('piVersion') != '1.4.0' or manifest.get('executablePath') != 'bin/heymate-agent':
        raise ValueError('Unsupported harness manifest.')
    for relative, digest in manifest['files'].items():
        if hashlib.sha256(child(root, relative).read_bytes()).hexdigest() != digest:
            raise ValueError('Runtime hash mismatch: ' + relative)
    for relative in manifest['nativeImages']:
        binary = child(root, relative)
        if pristine and hashlib.sha256(binary.read_bytes()).hexdigest() != manifest.get('nativeDigests', {}).get(relative):
            raise ValueError('Native source hash mismatch: ' + relative)
        architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(binary)], text=True).split()
        if manifest['architecture'] not in architectures:
            raise ValueError('Nested executable architecture mismatch: ' + relative)
    expected = set(manifest['files']) | set(manifest['nativeImages']) | {'manifest.json'}
    actual = {file.relative_to(root).as_posix() for file in root.rglob('*') if file.is_file()}
    if actual != expected:
        raise ValueError('Runtime inventory differs from manifest.')
    if 'bin/node' not in manifest['nativeImages']:
        raise ValueError('Bundled Node missing.')
    if not os.access(child(root, manifest['executablePath']), os.X_OK):
        raise ValueError('Harness launcher is not executable.')
    child(root, manifest['runtimePath'], allow_root=True)
    # Validate every symlink, including npm's .bin launchers.
    for file in root.rglob('*'):
        if file.is_symlink():
            child(root, file.relative_to(root).as_posix())
    return manifest


def signed_by(root, manifest, identity):
    if 'payloads' in manifest:
        return all(signed_by(root / relative, json.loads((root / relative / 'manifest.json').read_text()), identity)
                   for relative in manifest['payloads'].values())
    if not identity or os.environ.get('CODE_SIGNING_ALLOWED') == 'NO':
        try:
            verify(root, pristine=True)
            return True
        except ValueError:
            return False
    for relative in manifest['nativeImages']:
        binary = root / relative
        if subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], capture_output=True).returncode:
            return False
        with tempfile.TemporaryDirectory(prefix='heymate-pi-cert-') as scratch:
            prefix = pathlib.Path(scratch) / 'certificate'
            check = subprocess.run(['/usr/bin/codesign', '-d', '--extract-certificates', str(prefix), str(binary)], capture_output=True)
            certificate = pathlib.Path(str(prefix) + '0')
            if check.returncode or not certificate.exists() or hashlib.sha1(certificate.read_bytes()).hexdigest().lower() != identity.lower():
                return False
    return True


def stage_payload(source, destination):
    manifest = verify(source, pristine=True)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Source and destination overlap.')
    if destination.exists():
        try:
            current = verify(destination)
            if current == manifest and signed_by(destination, current, os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '')):
                print('Reused unchanged Pi payload; nested signatures preserved')
                return False
        except (ValueError, OSError, KeyError):
            pass
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    verify(destination, pristine=True)
    sign(destination, manifest)
    # Xcode must see an app-product input change when only harness resources
    # changed. It then performs normal outer signing after this build phase.
    build_dir, wrapper = os.environ.get('TARGET_BUILD_DIR'), os.environ.get('WRAPPER_NAME')
    if build_dir and wrapper:
        app = (pathlib.Path(build_dir) / wrapper).resolve()
        if destination == app / 'Contents/Resources/MateAgent':
            app.touch()
    return True


def sign(root, manifest):
    if 'payloads' in manifest:
        for relative in manifest['payloads'].values():
            nested = root / relative
            sign(nested, json.loads((nested / 'manifest.json').read_text()))
        return
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '')
    if os.environ.get('CODE_SIGNING_ALLOWED') == 'NO' or not identity:
        return
    entitlements = pathlib.Path(__file__).with_name('pi-node.entitlements')
    for relative in manifest['nativeImages']:
        args = ['/usr/bin/codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp=none']
        if relative == 'bin/node':
            args += ['--entitlements', str(entitlements)]
        subprocess.run(args + [str(root / relative)], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=pathlib.Path, required=True)
    parser.add_argument('--destination', type=pathlib.Path, required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    source, destination = args.source.resolve(), args.destination.resolve()
    if args.verify_only:
        verify(source)
    else:
        stage_payload(source, destination)
    print('PASS: HeyMate Pi harness payload verified')
