#!/usr/bin/env python3
"""Packaging admission tests; no profiles, credentials, model calls or installs."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("hermes-runtime-stage.py")
spec = importlib.util.spec_from_file_location("runtime_stage", SCRIPT)
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
COMMIT = "1" * 40


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="hermes-runtime-tests-")
        self.root = Path(self.scratch.name) / "Hermes"
        self.fixture(self.root)

    def tearDown(self):
        self.scratch.cleanup()

    def fixture(self, root):
        for name in ("bin", "tools", "site", "venv", "hermes-agent"):
            (root / name).mkdir(parents=True)
        for name in ("bin/hermes", "tools/python"):
            (root / name).write_text("#!/bin/sh\nexit 0\n")
            (root / name).chmod(0o755)
        (root / "hermes-agent/LICENSE").write_text("Test fixture license\n")
        (root / "hermes-agent/install-stamp.json").write_text(json.dumps({"commit": COMMIT, "updateMechanism": "external"}))
        (root / "manifest.json").write_text(json.dumps({
            "schema": 1, "target": "darwin-arm64", "sourceCommit": COMMIT,
            "executablePath": "bin/hermes", "runtimePath": "tools", "venv": "venv",
            "runtime": {"storePython": "tools/python", "sitePackages": "site", "repoDir": "hermes-agent"}}))

    def test_escape_rejected_before_staging(self):
        manifest = json.loads((self.root / "manifest.json").read_text())
        manifest["executablePath"] = "../external"
        (self.root / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            stage.validate(self.root)

    def test_profile_credentials_rejected_but_example_allowed(self):
        (self.root / "hermes-agent/.env.example").write_text("EXAMPLE=value\n")
        stage.validate(self.root)
        (self.root / "hermes-agent/.env.production").write_text("TEST_ONLY=value\n")
        with self.assertRaises(ValueError):
            stage.validate(self.root)

    def test_escaping_symlink_rejected(self):
        (self.root / "tools/escaped").symlink_to("../../../outside")
        with self.assertRaises(ValueError):
            stage.validate(self.root)

    def test_aggregate_rejects_mismatched_source(self):
        aggregate = Path(self.scratch.name) / "aggregate"
        aggregate.mkdir()
        shutil.move(self.root, aggregate / "arm64")
        (aggregate / "manifest.json").write_text(json.dumps({"schema": 1, "sourceCommit": "2" * 40, "payloads": {"arm64": "arm64"}}))
        with self.assertRaises(ValueError):
            stage.validate(aggregate)

    def test_aggregate_rejects_extra_profile_state(self):
        aggregate = Path(self.scratch.name) / "aggregate"
        aggregate.mkdir()
        shutil.move(self.root, aggregate / "arm64")
        (aggregate / "manifest.json").write_text(json.dumps({"schema": 1, "sourceCommit": COMMIT, "payloads": {"arm64": "arm64"}}))
        stage.validate(aggregate)
        (aggregate / "profiles").mkdir()
        with self.assertRaises(ValueError):
            stage.validate(aggregate)

    def test_universal_architecture_request_requires_both_payloads(self):
        env = dict(os.environ, ARCHS="arm64 x86_64")
        result = subprocess.run(["/usr/bin/python3", str(SCRIPT), "--source", str(self.root),
                                 "--destination", str(Path(self.scratch.name) / "Resources/Hermes"),
                                 "--verify-only"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not cover ARCHS", result.stderr)


if __name__ == "__main__":
    unittest.main()
