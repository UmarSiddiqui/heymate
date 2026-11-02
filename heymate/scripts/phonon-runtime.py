#!/usr/bin/env python3
"""Build/stage pinned, self-contained Ollama + Phonon for the macOS app.

Only nested native images are signed. Xcode owns the outer app signature.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

VERSION = '0.40.13'
ARCHIVE_SHA = 'bae29252232b9e1358cf5801a7d65a07442af18fb5467cb68c7fc3711f59c511'
MODEL_SHA = 'd47cfe951d4d684faecb78d21f5698c56b3181f573628a0eb1ee42346d140f2e'
MODEL_PATH = 'models/manifests/registry.ollama.ai/library/phonon/latest'


def sha(path):
    with path.open('rb') as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
        return digest.hexdigest()


def fetch(url, destination, digest):
    if destination.is_file() and sha(destination) == digest:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix('.download')
    try:
        with urllib.request.urlopen(url, timeout=120) as source, temporary.open('wb') as output:
            shutil.copyfileobj(source, output)
        if sha(temporary) != digest:
            raise ValueError('Download hash mismatch: ' + destination.name)
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def verify(root, pristine=False):
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('engine') != 'heymate-phonon' or manifest.get('ollamaVersion') != VERSION:
        raise ValueError('Unsupported speech runtime')
    expected = set(manifest['files']) | set(manifest['nativeImages']) | {'manifest.json'}
    actual = {f.relative_to(root).as_posix() for f in root.rglob('*') if f.is_file()}
    if actual != expected:
        raise ValueError('Speech runtime inventory mismatch')
    for name in expected - {'manifest.json'}:
        file = root / name
        if file.resolve() != root.resolve() and root.resolve() not in file.resolve().parents:
            raise ValueError('Speech runtime path escapes payload')
        if name in manifest['files'] or pristine:
            if sha(file) != manifest['files'].get(name, manifest['nativeImages'].get(name)):
                raise ValueError('Speech runtime hash mismatch: ' + name)
    if sha(root / MODEL_PATH) != MODEL_SHA:
        raise ValueError('Speech model manifest changed')
    return manifest


def build(destination):
    cache = Path(os.environ.get('HEYMATE_PHONON_CACHE', Path.home() / 'Library/Caches/HeyMate/PhononBuild'))
    archive = Path(os.environ.get('HEYMATE_OLLAMA_ARCHIVE', cache / 'ollama-darwin.tgz'))
    fetch(f'https://github.com/ollama/ollama/releases/download/v{VERSION}/ollama-darwin.tgz', archive, ARCHIVE_SHA)
    model_manifest = Path(__file__).with_name('phonon') / 'model-manifest.json'
    if sha(model_manifest) != MODEL_SHA:
        raise ValueError('Unpinned model manifest')
    model = json.loads(model_manifest.read_text())
    blob_cache = Path(os.environ.get('HEYMATE_PHONON_MODELS_SOURCE', cache / 'models')) / 'blobs'
    descriptors = {item['digest']: item for item in [model['config']] + model['layers']}

    def get_blob(item):
        digest = item['digest'].split(':')[1]
        file = blob_cache / ('sha256-' + digest)
        fetch('https://registry.ollama.ai/v2/library/phonon/blobs/sha256:' + digest, file, digest)
        if file.stat().st_size != item['size']:
            raise ValueError('Model blob size mismatch')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(get_blob, descriptors.values()))
    with tempfile.TemporaryDirectory(prefix='heymate-phonon-') as scratch:
        scratch = Path(scratch).resolve()
        extracted, payload = scratch / 'archive', scratch / 'payload'
        extracted.mkdir()
        with tarfile.open(archive) as source:
            for member in source.getmembers():
                candidate = (extracted / member.name).resolve()
                if extracted not in candidate.parents and candidate != extracted:
                    raise ValueError('Archive path escapes payload')
                if member.issym() or member.islnk():
                    link = (candidate.parent / member.linkname).resolve()
                    if extracted not in link.parents:
                        raise ValueError('Archive link escapes payload')
            source.extractall(extracted)
        runtime = next(extracted.rglob('ollama')).parent
        payload.mkdir()
        for file in runtime.iterdir():
            if file.name.startswith('._') or file.name.endswith('.so') or file.name == 'llama-quantize':
                continue
            target = payload / file.name
            if file.is_symlink():
                target.symlink_to(os.readlink(file))
            elif file.is_dir():
                shutil.copytree(file, target, symlinks=True, ignore=shutil.ignore_patterns('._*'))
            else:
                shutil.copy2(file, target)
        target = payload / MODEL_PATH
        target.parent.mkdir(parents=True)
        shutil.copy2(model_manifest, target)
        blobs = payload / 'models/blobs'
        blobs.mkdir(parents=True)
        for digest in descriptors:
            name = digest.replace(':', '-')
            shutil.copy2(blob_cache / name, blobs / name)
        files, native = {}, {}
        for file in payload.rglob('*'):
            if not file.is_file():
                continue
            name = file.relative_to(payload).as_posix()
            if file.suffix == '.dylib' or file.name in ('ollama', 'llama-server'):
                native[name] = sha(file)
                if not file.is_symlink():
                    file.chmod(0o755)
            else:
                files[name] = sha(file)
        manifest = dict(engine='heymate-phonon', schema=1, ollamaVersion=VERSION,
                        archiveSHA256=ARCHIVE_SHA, modelManifestSHA256=MODEL_SHA,
                        files=files, nativeImages=native)
        (payload / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        verify(payload, pristine=True)
        if destination.exists():
            shutil.rmtree(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(payload, destination, symlinks=True)
    print('PASS: pinned Phonon payload built')


def stage(source, destination):
    manifest = verify(source, pristine=True)
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError('Speech payload paths overlap')
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY', '')
    if identity and os.environ.get('CODE_SIGNING_ALLOWED') != 'NO':
        for name in manifest['nativeImages']:
            file = destination / name
            if not file.is_symlink():
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity,
                                '--options', 'runtime', '--timestamp=none', str(file)], check=True)
    build_dir, wrapper = os.environ.get('TARGET_BUILD_DIR'), os.environ.get('WRAPPER_NAME')
    if build_dir and wrapper:
        (Path(build_dir) / wrapper).touch()
    print('PASS: Phonon payload staged; nested code signed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path)
    args = parser.parse_args()
    if args.out:
        build(args.out.resolve())
    else:
        stage(args.source.resolve(), args.destination.resolve())
