#!/usr/bin/env python3
"""Packaging boundary tests; scratch fixtures only, no signing or app launch."""
import hashlib
import importlib.util
import json
import pathlib
import subprocess
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pi_stage', pathlib.Path(__file__).with_name('pi-runtime-stage.py'))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='heymate-pi-package-')
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name) / 'payload'
        (self.root / 'bin').mkdir(parents=True)
        shutil.copyfile('/bin/echo', self.root / 'bin/node')
        launcher = self.root / 'bin/heymate-agent'
        launcher.write_text('#!/bin/sh\nexit 0\n')
        launcher.chmod(0o755)
        self.manifest = {'schema': 1, 'engine': 'heymate-pi', 'piVersion': '1.4.0',
            'sourceCommit': 'a' * 40, 'architecture': subprocess.check_output(['/usr/bin/lipo', '-archs', '/bin/echo'], text=True).split()[0],
            'executablePath': 'bin/heymate-agent', 'runtimePath': 'bin',
            'files': {'bin/heymate-agent': hashlib.sha256(launcher.read_bytes()).hexdigest()}, 'nativeImages': ['bin/node'],
            'nativeDigests': {'bin/node': hashlib.sha256((self.root / 'bin/node').read_bytes()).hexdigest()}}
        self.save()

    def save(self):
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_valid_payload(self):
        self.assertEqual(stage.verify(self.root)['engine'], 'heymate-pi')

    def test_node_with_only_system_libraries_is_portable(self):
        output = 'node:\n\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0)\n'
        with patch.object(stage.subprocess, 'check_output', return_value=output):
            stage.verify_node_dependencies(self.root / 'bin/node')

    def test_node_with_missing_relative_library_is_rejected(self):
        output = 'node:\n\t@rpath/libnode.127.dylib (compatibility version 0.0.0)\n'
        with patch.object(stage.subprocess, 'check_output', return_value=output):
            with self.assertRaisesRegex(ValueError, 'self-contained'):
                stage.verify_node_dependencies(self.root / 'bin/node')

    def test_node_with_homebrew_library_is_rejected(self):
        output = 'node:\n\t/opt/homebrew/opt/libuv/lib/libuv.1.dylib (compatibility version 1.0.0)\n'
        with patch.object(stage.subprocess, 'check_output', return_value=output):
            with self.assertRaisesRegex(ValueError, 'self-contained'):
                stage.verify_node_dependencies(self.root / 'bin/node')

    def test_tampering_is_rejected(self):
        (self.root / 'bin/heymate-agent').write_text('modified')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            stage.verify(self.root)

    def test_unlisted_code_is_rejected(self):
        (self.root / 'unexpected.mjs').write_text('fixture')
        with self.assertRaisesRegex(ValueError, 'inventory differs'):
            stage.verify(self.root)

    def test_symlink_escape_is_rejected(self):
        (self.root / 'escape').symlink_to('/bin/echo')
        with self.assertRaisesRegex(ValueError, 'escapes payload|inventory differs'):
            stage.verify(self.root)

    def test_relative_traversal_is_rejected(self):
        self.manifest['files']['../outside'] = '0' * 64
        self.save()
        with self.assertRaisesRegex(ValueError, 'escapes payload'):
            stage.verify(self.root)

    def test_repeat_staging_keeps_unchanged_native_bytes_and_mtime(self):
        destination = self.root.parent / 'destination'
        stage.stage_payload(self.root, destination)
        before = (destination / 'bin/node').stat().st_mtime_ns
        stage.stage_payload(self.root, destination)
        self.assertEqual((destination / 'bin/node').stat().st_mtime_ns, before)

    def test_changed_native_source_cannot_bypass_hash_validation(self):
        with (self.root / 'bin/node').open('ab') as file:
            file.write(b'changed')
        with self.assertRaisesRegex(ValueError, 'Native source hash mismatch'):
            stage.verify(self.root, pristine=True)

    def test_aggregate_requires_matching_revision(self):
        aggregate = self.root.parent / 'aggregate'
        aggregate.mkdir()
        shutil.move(self.root, aggregate / 'arm64')
        child = json.loads((aggregate / 'arm64/manifest.json').read_text())
        (aggregate / 'manifest.json').write_text(json.dumps({'schema': 1, 'engine': 'heymate-pi',
            'sourceCommit': 'b' * 40, 'payloads': {child['architecture']: 'arm64'}}))
        with self.assertRaisesRegex(ValueError, 'Mixed harness source revisions'):
            stage.verify(aggregate)


if __name__ == '__main__':
    unittest.main()
