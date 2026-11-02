#!/usr/bin/env python3
"""Packaging regressions: model integrity and copy-stable resource inventory."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('phonon_runtime', Path(__file__).with_name('phonon-runtime.py'))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class PackagingTests(unittest.TestCase):
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
