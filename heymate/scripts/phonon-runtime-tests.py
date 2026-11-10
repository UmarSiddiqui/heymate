#!/usr/bin/env python3
"""Packaging regressions: model integrity and copy-stable resource inventory."""
import importlib.util
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('phonon_runtime', Path(__file__).with_name('phonon-runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PackagingTests(unittest.TestCase):
    def test_archive_keeps_relative_dylib_alias_and_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'fixture.tgz'
            with tarfile.open(archive, 'w:gz') as source:
                alias = tarfile.TarInfo('lib/libollama.dylib')
                alias.type = tarfile.SYMTYPE
                alias.linkname = 'libollama.1.dylib'
                source.addfile(alias)
                binary = tarfile.TarInfo('lib/libollama.1.dylib')
                binary.mode = 0o4755
                binary.size = 4
                source.addfile(binary, io.BytesIO(b'data'))
            destination = root / 'unpacked'
            runtime.unpack_archive(archive, destination)
            self.assertEqual((destination / alias.name).readlink(), Path(alias.linkname))
            self.assertEqual((destination / alias.name).read_bytes(), b'data')
            self.assertEqual((destination / binary.name).stat().st_mode & 0o7777, 0o755)

    def test_archive_refuses_traversal_links_and_special_files(self):
        for name, kind, target in [
            ('../outside', tarfile.REGTYPE, ''),
            ('/outside', tarfile.REGTYPE, ''),
            ('link', tarfile.SYMTYPE, '../outside'),
            ('link', tarfile.SYMTYPE, '/outside'),
            ('hardlink', tarfile.LNKTYPE, 'safe'),
            ('pipe', tarfile.FIFOTYPE, ''),
        ]:
            with self.subTest(name=name, target=target), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / 'fixture.tgz'
                with tarfile.open(archive, 'w:gz') as source:
                    entry = tarfile.TarInfo(name)
                    entry.type, entry.linkname = kind, target
                    source.addfile(entry)
                destination = root / 'unpacked'
                destination.mkdir()
                with self.assertRaises(ValueError):
                    runtime.unpack_archive(archive, destination)
                self.assertEqual(list(destination.iterdir()), [])
                self.assertFalse((root / 'outside').exists())

    def test_archive_api_fallback_keeps_checksum_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'runtime.tgz'
            body = b'pinned runtime fixture'
            primary, fallback = 'https://example.invalid/release', 'https://example.invalid/asset'
            error = HTTPError(primary, 504, 'Gateway Time-out', {}, None)
            with patch.object(runtime.urllib.request, 'urlopen', side_effect=[error, io.BytesIO(body)]) as download, \
                 patch.object(runtime.time, 'sleep'):
                runtime.fetch(primary, destination, hashlib.sha256(body).hexdigest(), fallback_url=fallback)
            self.assertEqual([call.args[0].full_url for call in download.call_args_list], [primary, fallback])
            self.assertEqual(download.call_args.args[0].get_header('Accept'), 'application/octet-stream')
            self.assertEqual(destination.read_bytes(), body)

    def test_transient_download_retries_then_verifies_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'runtime.tgz'
            body = b'pinned runtime fixture'
            error = HTTPError('https://example.invalid/runtime', 504, 'Gateway Time-out', {}, None)
            with patch.object(runtime.urllib.request, 'urlopen', side_effect=[error, io.BytesIO(body)]) as download, \
                 patch.object(runtime.time, 'sleep') as sleep:
                runtime.fetch('https://example.invalid/runtime', destination, hashlib.sha256(body).hexdigest())
            self.assertEqual(destination.read_bytes(), body)
            self.assertEqual(download.call_count, 2)
            sleep.assert_called_once_with(1)
            self.assertFalse(destination.with_suffix('.download').exists())

    def test_transient_download_retry_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'runtime.tgz'
            error = HTTPError('https://example.invalid/runtime', 504, 'Gateway Time-out', {}, None)
            with patch.object(runtime.urllib.request, 'urlopen', side_effect=error) as download, \
                 patch.object(runtime.time, 'sleep'):
                with self.assertRaises(HTTPError):
                    runtime.fetch('https://example.invalid/runtime', destination, 'unused')
            self.assertEqual(download.call_count, 4)
            self.assertFalse(destination.exists())
            self.assertFalse(destination.with_suffix('.download').exists())

    def test_permanent_download_error_is_not_retried(self):
        with tempfile.TemporaryDirectory() as directory:
            error = HTTPError('https://example.invalid/runtime', 404, 'Not Found', {}, None)
            with patch.object(runtime.urllib.request, 'urlopen', side_effect=error) as download, \
                 patch.object(runtime.time, 'sleep') as sleep:
                with self.assertRaises(HTTPError):
                    runtime.fetch('https://example.invalid/runtime', Path(directory) / 'runtime.tgz', 'unused')
            self.assertEqual(download.call_count, 1)
            sleep.assert_not_called()

    def test_bad_download_hash_preserves_existing_file_without_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'runtime.tgz'
            destination.write_bytes(b'existing cache')
            with patch.object(runtime.urllib.request, 'urlopen', return_value=io.BytesIO(b'corrupt')) as download, \
                 patch.object(runtime.time, 'sleep') as sleep:
                with self.assertRaisesRegex(ValueError, 'Download hash mismatch'):
                    runtime.fetch('https://example.invalid/runtime', destination, hashlib.sha256(b'expected').hexdigest())
            self.assertEqual(destination.read_bytes(), b'existing cache')
            self.assertFalse(destination.with_suffix('.download').exists())
            self.assertEqual(download.call_count, 1)
            sleep.assert_not_called()

    def fixture(self, root):
        model = root / runtime.MODEL_PATH
        model.parent.mkdir(parents=True)
        model.write_bytes((Path(__file__).with_name('phonon') / 'model-manifest.json').read_bytes())
        manifest = dict(engine='heymate-phonon', ollamaVersion=runtime.VERSION,
                        files={runtime.MODEL_PATH: runtime.sha(model)}, nativeImages={})
        (root / 'manifest.json').write_text(json.dumps(manifest))

    def test_tampered_model_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            runtime.verify(root, pristine=True)
            (root / runtime.MODEL_PATH).write_bytes(b'tampered')
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                runtime.verify(root, pristine=True)

    def test_unlisted_appledouble_metadata_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            (root / '._mlx.metallib').write_bytes(b'AppleDouble')
            with self.assertRaisesRegex(ValueError, 'inventory mismatch'):
                runtime.verify(root)


if __name__ == '__main__':
    unittest.main()
