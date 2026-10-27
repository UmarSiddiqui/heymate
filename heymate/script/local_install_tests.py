#!/usr/bin/env python3
"""Exercise local signing/install failures in disposable fixtures, never the real app."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIR = Path(__file__).resolve().parent
CERTIFICATE = "local-development-certificate"
OTHER_CERTIFICATE = "different-certificate"
FINGERPRINT = hashlib.sha1(CERTIFICATE.encode()).hexdigest().upper()
OTHER_FINGERPRINT = hashlib.sha1(OTHER_CERTIFICATE.encode()).hexdigest().upper()
NAME = "Apple Development: Local Developer (PERSONALID)"

MOCK_CODESIGN = r'''
import json, pathlib, sys
args = sys.argv[1:]
target = pathlib.Path(args[-1])
bundle = target
if target.is_file():
    bundle = next(path for path in target.parents if path.suffix == ".app")
data = json.loads((bundle / "signature.json").read_text())
if args[0] == "--verify":
    if not data.get("valid", True) or str(bundle) == data.get("invalid_at"):
        sys.exit(1)
    for arg in args:
        if arg.startswith("-R=") and arg[3:] not in data.get("accepts", [data["requirement"]]):
            sys.exit(1)
elif "-r-" in args:
    print("designated => " + data["requirement"], file=sys.stderr)
elif any(arg.startswith("--extract-certificates=") for arg in args):
    if data.get("certificate"):
        prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--extract-certificates="))
        pathlib.Path(prefix + "0").write_text(data["certificate"])
else:
    identifier = data.get("identifier", "com.heymate.app")
    if target.name == "HeyMateAgentRunner": identifier = "com.heymate.app.agent-runner"
    print("Identifier=" + identifier, file=sys.stderr)
    print("TeamIdentifier=" + data.get("team", "REALTEAMID"), file=sys.stderr)
    print("CodeDirectory flags=0x10000(runtime)", file=sys.stderr)
'''

MOCK_WORKFLOW_TOOL = r'''
import json, os, pathlib, shutil, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
state_path = pathlib.Path(os.environ["TEST_RUNNING"])
running = state_path.exists()
installed = os.environ["TEST_INSTALLED"]
def record(event):
    with open(os.environ["TEST_EVENTS"], "a") as stream:
        stream.write(json.dumps([event, args]) + "\n")
if name == "pgrep":
    if running: print("23456")
    else: sys.exit(1)
elif name == "ps":
    if not running: sys.exit(1)
    print(installed + "/Contents/MacOS/HeyMate")
elif name == "sleep":
    pass
elif name == "xcodebuild":
    record("build")
    assert "CODE_SIGN_IDENTITY=" + os.environ["TEST_FINGERPRINT"] in args
    assert "DEVELOPMENT_TEAM=REALTEAMID" in args
    if os.environ.get("TEST_FAIL") == "build": sys.exit(83)
    products = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Debug/HeyMate.app"
    shutil.copytree(os.environ["TEST_TEMPLATE"], products, dirs_exist_ok=True)
elif name == "osascript":
    record("quit")
    assert args == ["-", installed]
    if os.environ.get("TEST_FAIL") == "quit": sys.exit(84)
    state_path.unlink()
elif name in ("open", "lldb", "log"):
    record(name)
    if name == "open":
        assert args == [installed]
        state_path.touch()
    elif name == "lldb":
        assert args == ["--", installed + "/Contents/MacOS/HeyMate"]
'''


class LocalInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="heymate-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.installed = self.root / "Applications" / "HeyMate.app"
        self.candidate = self.root / "stage with spaces" / "HeyMate.app"
        self.backup = self.root / "backups" / "previous" / "HeyMate.app"
        self.make_bundle(self.installed, payload="old")
        self.make_bundle(self.candidate, payload="new")
        tools = self.root / "bin"
        tools.mkdir()
        for name, code in {
            "codesign": MOCK_CODESIGN,
            "security": 'import os; print(os.environ["TEST_IDENTITIES"])',
        }.items():
            path = tools / name
            path.write_text(f"#!{sys.executable}\n{code}\n")
            path.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "TEST_IDENTITIES": f'  1) {FINGERPRINT} "{NAME}"\n  1 valid identities found',
            "TEST_INSTALLED": str(self.installed),
            "TEST_CANDIDATE": str(self.candidate),
            "TEST_BACKUP": str(self.backup),
        }
        self.environment.pop("HEYMATE_SIGNING_IDENTITY", None)
        self.environment.pop("HEYMATE_DEVELOPMENT_TEAM", None)

    def make_bundle(self, path, payload, **signature):
        (path / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.heymate.app"}))
        binary = path / "Contents/MacOS/HeyMate"
        binary.write_text(payload)
        binary.chmod(0o755)
        runner = path / "Contents/Helpers/HeyMateAgentRunner"
        runner.parent.mkdir(exist_ok=True)
        runner.write_text("detached runner")
        runner.chmod(0o755)
        (path / "signature.json").write_text(json.dumps({
            "certificate": CERTIFICATE, "requirement": "local-development", **signature,
        }))

    def run_shell(self, action, expected=0):
        source = "\n".join(f"source {shlex.quote(str(SCRIPT_DIR / name))}" for name in [
            "code_signature_checks.sh", "local_install.sh",
        ])
        result = subprocess.run(
            ["/bin/bash", "-euo", "pipefail", "-c", source + "\n" + action],
            env=self.environment, text=True, capture_output=True,
        )
        if expected == 0:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def resolve(self, action="", expected=0):
        return self.run_shell('heymate_resolve_local_signing "$TEST_INSTALLED"\n' + action, expected)

    def check(self, expected=0):
        return self.resolve('heymate_local_check_candidate "$TEST_CANDIDATE" "$TEST_INSTALLED"', expected)

    def install(self, before="", expected=0):
        return self.resolve(before + '\nheymate_install_local_candidate "$TEST_CANDIDATE" "$TEST_INSTALLED" "$TEST_BACKUP"', expected)

    def test_installed_certificate_wins_over_keychain_order(self):
        self.environment["TEST_IDENTITIES"] = (
            f'1) {OTHER_FINGERPRINT} "Apple Development: Other (OTHER)"\n'
            f'2) {FINGERPRINT} "{NAME}"'
        )
        result = self.resolve('printf "selected=%s team=%s\\n" "$HEYMATE_LOCAL_SIGNER_SHA1" "$HEYMATE_LOCAL_TEAM"')
        self.assertIn(f"selected={FINGERPRINT} team=REALTEAMID", result.stdout)

    def test_missing_private_identity_never_falls_back(self):
        self.environment["TEST_IDENTITIES"] = f'1) {OTHER_FINGERPRINT} "Apple Development: Other (OTHER)"'
        self.resolve(expected=1)
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")

    def test_explicit_other_identity_is_refused(self):
        self.environment["HEYMATE_SIGNING_IDENTITY"] = OTHER_FINGERPRINT
        self.resolve(expected=1)

    def test_explicit_ad_hoc_identity_is_refused(self):
        self.environment["HEYMATE_SIGNING_IDENTITY"] = "-"
        self.resolve(expected=1)

    def test_explicit_wrong_team_is_refused(self):
        self.environment["HEYMATE_DEVELOPMENT_TEAM"] = "OTHERTEAM"
        self.resolve(expected=1)

    def test_same_bundle_id_different_signer_is_refused(self):
        self.make_bundle(self.candidate, "new", certificate=OTHER_CERTIFICATE)
        self.check(expected=1)

    def test_both_designated_requirements_must_accept_other_app(self):
        self.make_bundle(self.candidate, "new", requirement="stricter", accepts=["local-development", "stricter"])
        # Candidate accepts the installed DR, but installed rejects candidate DR.
        self.check(expected=1)
        self.make_bundle(self.installed, "old", requirement="stricter", accepts=["stricter", "local-development"])
        self.make_bundle(self.candidate, "new")
        # Reverse asymmetry must also fail.
        self.check(expected=1)

    def test_wrong_bundle_id_and_invalid_signature_are_refused(self):
        (self.candidate / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.other.app"}))
        self.check(expected=1)
        self.make_bundle(self.candidate, "new", valid=False)
        self.check(expected=1)

    def test_signed_install_keeps_old_bundle_as_backup(self):
        self.install()
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "new")
        self.assertEqual((self.backup / "Contents/MacOS/HeyMate").read_text(), "old")
        self.assertFalse(self.candidate.exists())

    def test_failed_move_restores_old_bundle(self):
        self.install('mv() { if [ "$1" = "$TEST_CANDIDATE" ]; then return 1; fi; command mv "$@"; }', expected=1)
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")
        self.assertTrue(self.candidate.exists())

    def test_failed_installed_verification_restores_old_bundle(self):
        self.make_bundle(self.candidate, "new", invalid_at=str(self.installed))
        self.install(expected=1)
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")
        self.assertTrue(self.candidate.exists())

    def test_existing_backup_is_never_overwritten(self):
        self.make_bundle(self.backup, "keep")
        self.install(expected=1)
        self.assertEqual((self.backup / "Contents/MacOS/HeyMate").read_text(), "keep")
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")

    def test_installed_signer_change_during_build_is_refused(self):
        self.resolve('printf different > "$TEST_INSTALLED/signature.json"\nheymate_local_check_candidate "$TEST_CANDIDATE" "$TEST_INSTALLED"', expected=1)
        self.assertTrue(self.candidate.exists())

    def test_first_install_requires_unambiguous_identity(self):
        self.environment["TEST_INSTALLED"] = str(self.root / "not-installed.app")
        self.resolve()
        self.environment["TEST_IDENTITIES"] += f'\n2) {OTHER_FINGERPRINT} "Apple Development: Other (OTHER)"'
        self.resolve(expected=1)
        self.environment["HEYMATE_SIGNING_IDENTITY"] = FINGERPRINT.lower()
        self.resolve()

    def workflow_script(self):
        # Exercise the entry point in a disposable project with an isolated
        # install path. Production keeps its canonical /Applications path.
        project = self.root / "project"
        script = project / "script/build_and_run.sh"
        script.parent.mkdir(parents=True)
        source = (SCRIPT_DIR / "build_and_run.sh").read_text().replace(
            'INSTALL_BUNDLE="/Applications/$APP_NAME.app"',
            'INSTALL_BUNDLE="$TEST_INSTALLED"',
        ).replace("/Applications/", str(self.root / "Applications") + "/")
        source = source.replace('$HOME/Library/Application Support/HeyMate Install Backups/', str(self.root / "backups") + "/")
        for name in ["open", "osascript", "log"]:
            source = source.replace(f"/usr/bin/{name}", shlex.quote(str(self.root / "bin" / name)))
        script.write_text(source)
        for name in ["local_install.sh", "code_signature_checks.sh", "process_scope.sh"]:
            (script.parent / name).write_bytes((SCRIPT_DIR / name).read_bytes())
        return script

    def test_preflight_in_build_script_never_builds_or_stops_app(self):
        script = self.workflow_script()
        forbidden = self.root / "bin/xcodebuild"
        forbidden.write_text('#!/bin/bash\necho "unexpected build" >&2\nexit 99\n')
        forbidden.chmod(0o755)
        result = subprocess.run(["/bin/bash", str(script), "--check"], env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("No build, install, quit, launch, or privacy changes", result.stdout)
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")
        self.assertFalse(self.backup.exists())

    def prepare_workflow(self):
        script = self.workflow_script()
        self.environment.update({
            "TEST_RUNNING": str(self.root / "running"),
            "TEST_EVENTS": str(self.root / "events.jsonl"),
            "HEYMATE_PI_RUNTIME": str(self.root / "pi-runtime"),
            "TEST_FINGERPRINT": FINGERPRINT,
            "TEST_TEMPLATE": str(self.candidate),
        })
        Path(self.environment["TEST_RUNNING"]).touch()
        for name in ["xcodebuild", "pgrep", "ps", "sleep", "osascript", "open", "lldb", "log"]:
            tool = self.root / "bin" / name
            tool.write_text(f"#!{sys.executable}\n{MOCK_WORKFLOW_TOOL}\n")
            tool.chmod(0o755)
        return script

    def workflow_events(self):
        path = self.root / "events.jsonl"
        return [json.loads(line)[0] for line in path.read_text().splitlines()] if path.exists() else []

    def test_full_verify_workflow_builds_before_quit_and_launches_installed_copy(self):
        script = self.prepare_workflow()
        result = subprocess.run(["/bin/bash", str(script), "--verify"], env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.workflow_events(), ["build", "quit", "open"])
        self.assertIn("remained alive (PID 23456)", result.stdout)
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "new")
        # A verified launch removes its rollback copy: one HeyMate on the Mac.
        backups = list((self.root / "backups").glob("*/HeyMate.app/Contents/MacOS/HeyMate"))
        self.assertEqual(backups, [])
        self.assertFalse((self.root / "Applications/.heymate-local-install.lock").exists())

    def test_build_failure_leaves_current_app_running(self):
        script = self.prepare_workflow()
        self.environment["TEST_FAIL"] = "build"
        result = subprocess.run(["/bin/bash", str(script), "--verify"], env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.workflow_events(), ["build"])
        self.assertTrue(Path(self.environment["TEST_RUNNING"]).exists())
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")

    def test_refused_quit_does_not_replace_app_or_force_kill(self):
        script = self.prepare_workflow()
        self.environment["TEST_FAIL"] = "quit"
        result = subprocess.run(["/bin/bash", str(script), "--verify"], env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.workflow_events(), ["build", "quit"])
        self.assertTrue(Path(self.environment["TEST_RUNNING"]).exists())
        self.assertEqual((self.installed / "Contents/MacOS/HeyMate").read_text(), "old")

    def test_debug_logs_and_telemetry_target_installed_copy(self):
        script = self.prepare_workflow()
        for mode, last_events in [
            ("--debug", ["lldb"]), ("--logs", ["open", "log"]), ("--telemetry", ["open", "log"]),
        ]:
            with self.subTest(mode=mode):
                Path(self.environment["TEST_EVENTS"]).unlink(missing_ok=True)
                Path(self.environment["TEST_RUNNING"]).touch()
                result = subprocess.run(["/bin/bash", str(script), mode], env=self.environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.workflow_events(), ["build", "quit"] + last_events)


if __name__ == "__main__":
    unittest.main(verbosity=2)
