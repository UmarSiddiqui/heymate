#!/usr/bin/env python3
"""Validate/copy a sealed Hermes payload; sign nested Mach-O before outer app.

Python standard library only; suitable for Xcode's /usr/bin/python3. Signing
changes PM tool digests, so refresh them through the shipped official PM API
after signing. Never operate on a live Hermes profile or source payload.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tempfile

MACHO = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
FORBIDDEN_FILES = {".env", "auth.json", "state.db", "state.db-wal", "state.db-shm", "credentials.json"}
FORBIDDEN_ROOTS = {"profiles", "sessions", "memories", "installs", "credentials", ".git", ".hermes"}


def relative_path(root, value, label):
    if not isinstance(value, str) or not value:
        raise ValueError("missing " + label)
    path = Path(value)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("unsafe " + label)
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root.resolve()) or not resolved.exists():
        raise ValueError("missing or escaped " + label)
    return root / path


def validate(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("payload must be a real directory")
    if (root / "manifest.json").is_symlink():
        raise ValueError("manifest must not be a symlink")
    manifest = json.loads((root / "manifest.json").read_text())
    if isinstance(manifest.get("payloads"), dict):
        if manifest.get("schema") != 1 or not re.fullmatch(r"[0-9a-f]{40}", manifest.get("sourceCommit", "")):
            raise ValueError("invalid aggregate runtime manifest")
        if not manifest["payloads"] or set(manifest["payloads"]) - {"arm64", "x86_64"}:
            raise ValueError("unsupported aggregate runtime architectures")
        if any(value != arch for arch, value in manifest["payloads"].items()):
            raise ValueError("aggregate child directories must match architecture names")
        if {entry.name for entry in root.iterdir()} - {"manifest.json", *manifest["payloads"]}:
            raise ValueError("unexpected files in aggregate runtime root")
        all_binaries, runtimes = [], []
        for arch, value in manifest["payloads"].items():
            child = relative_path(root, value, "aggregate " + arch)
            info, native, binaries = validate(child)
            target = "darwin-arm64" if arch == "arm64" else "darwin-x64"
            if info.get("target") != target or info.get("sourceCommit") != manifest["sourceCommit"]:
                raise ValueError("aggregate child architecture/source mismatch")
            runtimes.extend(native)
            all_binaries.extend(binaries)
        return manifest, runtimes, all_binaries
    if manifest.get("schema") != 1 or manifest.get("target") not in ("darwin-arm64", "darwin-x64"):
        raise ValueError("unsupported sealed runtime schema/architecture")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest.get("sourceCommit", "")):
        raise ValueError("missing pinned sourceCommit")
    executable = relative_path(root, manifest.get("executablePath"), "executablePath")
    tools = relative_path(root, manifest.get("runtimePath"), "runtimePath")
    runtime = manifest.get("runtime", {})
    python = relative_path(root, runtime.get("storePython"), "storePython")
    relative_path(root, runtime.get("sitePackages"), "sitePackages")
    repo = relative_path(root, runtime.get("repoDir"), "repoDir")
    relative_path(root, manifest.get("venv"), "venv")
    if not executable.is_file() or not os.access(executable, os.X_OK) or not python.is_file() or not tools.is_dir():
        raise ValueError("runtime launcher/interpreter/tools are invalid")
    stamp = json.loads((repo / "install-stamp.json").read_text())
    if stamp.get("commit") != manifest["sourceCommit"] or stamp.get("updateMechanism") != "external":
        raise ValueError("runtime source/update ownership does not match")
    if not (repo / "LICENSE").is_file():
        raise ValueError("Hermes MIT license missing")
    for entry in root.iterdir():
        if entry.name in FORBIDDEN_ROOTS:
            raise ValueError("profile/build state present: " + entry.name)
    binaries = []
    expected_arch = "arm64" if manifest["target"] == "darwin-arm64" else "x86_64"
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            if name in FORBIDDEN_FILES or (name.startswith(".env.") and name not in (".env.example", ".env.sample", ".env.template")):
                raise ValueError("profile/credential file present: " + str(path.relative_to(root)))
            if path.is_symlink():
                if os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(root.resolve()) or not path.exists():
                    raise ValueError("invalid runtime symlink: " + str(path.relative_to(root)))
            elif path.is_file():
                with path.open("rb") as stream:
                    if stream.read(4) in MACHO:
                        archs = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).split()
                        if expected_arch not in archs:
                            raise ValueError("Mach-O architecture mismatch: " + str(path.relative_to(root)))
                        binaries.append(path)
    return manifest, [(root, python)], binaries


def rehash(root, python):
    # Same API used by official scripts/bundles/payload.py::rehash_tools.
    # -I/-S/-B avoids profile loading, site hooks and code-cache writes.
    code = """import pathlib,sys
root=pathlib.Path(sys.argv[1]);sys.path.insert(0,str(root/'hermes-agent'))
from pm.lock import Facts
facts=Facts(root/'tools/facts.json',strict=True)
facts.refresh_digests(root/'tools')
facts.path.chmod(0o644)
"""
    subprocess.run([str(python), "-I", "-S", "-B", "-c", code, str(root)], check=True,
                   env={"PATH": "/usr/bin:/bin"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--identity", default=None)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    source = args.source.absolute()
    manifest, _, binaries = validate(source)
    available_archs = set(manifest["payloads"]) if "payloads" in manifest else {
        "arm64" if manifest["target"] == "darwin-arm64" else "x86_64"}
    requested_archs = os.environ.get("ARCHS", "").split()
    if requested_archs and not set(requested_archs).issubset(available_archs):
        raise ValueError("Hermes runtime architectures {} do not cover ARCHS={}".format(
            ",".join(sorted(available_archs)), " ".join(requested_archs)))
    if args.verify_only:
        print("Hermes runtime valid: {} ({} Mach-O files)".format(
            ",".join(sorted(available_archs)), len(binaries)))
        return
    requested_destination = args.destination.absolute()
    if requested_destination.name != "Hermes" or requested_destination.is_symlink():
        raise ValueError("destination must be a real parent's Hermes directory")
    destination = requested_destination.parent.resolve() / requested_destination.name
    if source.resolve() == destination.resolve() or source.resolve().is_relative_to(destination.resolve()) or destination.resolve().is_relative_to(source.resolve()):
        raise ValueError("source and destination must be separate trees")
    destination.parent.mkdir(parents=True, exist_ok=True)
    identity = args.identity if args.identity is not None else os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
    signing = bool(identity) and os.environ.get("CODE_SIGNING_ALLOWED", "YES") != "NO"
    with tempfile.TemporaryDirectory(prefix=".hermes-stage-", dir=destination.parent) as scratch:
        staged = Path(scratch) / "Hermes"
        shutil.copytree(source, staged, symlinks=True)
        _, runtimes, binaries = validate(staged)
        if signing:
            # Official Hermes' inherited macOS policy includes this entitlement.
            # A hardened ad-hoc/self-signed Python otherwise cannot import its
            # signed native wheels because those signatures have no Team ID.
            entitlements = Path(scratch) / "python-entitlements.plist"
            entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.disable-library-validation": True}))
            for binary in sorted(binaries, key=lambda path: len(path.parts), reverse=True):
                command = ["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime"]
                command += ["--timestamp=none"] if identity == "-" else ["--timestamp"]
                if any(binary.resolve() == python.resolve() for _, python in runtimes):
                    command += ["--entitlements", str(entitlements)]
                subprocess.run(command + [str(binary)], check=True, stdout=subprocess.DEVNULL)
                subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(binary)], check=True,
                               stdout=subprocess.DEVNULL)
            host_arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
            host_python = None
            for native_root, python in runtimes:
                native_manifest = json.loads((native_root / "manifest.json").read_text())
                native_arch = "arm64" if native_manifest["target"] == "darwin-arm64" else "x86_64"
                if native_arch == host_arch:
                    host_python = python
                    break
            if host_python is None:
                raise ValueError("signing/digest refresh requires a host-compatible bundled Python")
            for native_root, _ in runtimes:
                rehash(native_root, host_python)
            validate(staged)
        if destination.exists():
            if not destination.is_dir():
                raise ValueError("existing destination is not a directory")
            shutil.rmtree(destination)
        staged.rename(destination)
    print("Staged {} Hermes runtime; {} nested Mach-O files; signing {}".format(
        ",".join(sorted(available_archs)), len(binaries), "completed" if signing else "not requested"))


if __name__ == "__main__":
    main()
