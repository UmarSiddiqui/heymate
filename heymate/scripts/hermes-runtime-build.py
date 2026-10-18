#!/usr/bin/env python3
"""Build a headless, relocatable Hermes payload using pinned official PM APIs.

Run with the pinned Hermes Python. Inputs are source, binary tools and a uv
wheel cache only. No profile credentials, sessions or selected environments
are copied. Output must not exist. Downloads are disabled unless requested.
"""
import argparse
from email.parser import BytesParser
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def collect_licenses(root, tools_facts):
    extra = root / "third-party-licenses"
    extra.mkdir(exist_ok=True)
    version = tools_facts["uv"]["version"]
    licenses = Path(__file__).with_name("hermes-runtime-licenses")
    for suffix in ("LICENSE-MIT", "LICENSE-APACHE"):
        name = "uv-" + version + "-" + suffix
        shutil.copy2(licenses / name, extra / name)
    inventory = []
    for metadata_path in root.rglob("*.dist-info/METADATA"):
        metadata = BytesParser().parsebytes(metadata_path.read_bytes())
        inventory.append({"name": metadata.get("Name"), "version": metadata.get("Version"),
                          "licenseExpression": metadata.get("License-Expression"),
                          "license": metadata.get("License"),
                          "licenseClassifiers": [value for value in metadata.get_all("Classifier", []) if value.startswith("License")],
                          "declaredLicenseFiles": metadata.get_all("License-File", []),
                          "metadata": str(metadata_path.relative_to(root))})
    texts = []
    files = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        upper = path.name.upper()
        if not upper.startswith(("LICENSE", "COPYING", "NOTICE")) or path.suffix.lower() in (".py", ".pyc", ".so"):
            continue
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        relative = str(path.relative_to(root))
        files.append({"path": relative, "sha256": hashlib.sha256(data).hexdigest()})
        texts.append("\n" + "=" * 72 + "\n" + relative + "\n" + "=" * 72 + "\n" + text)
    report = {"schema": 1, "pythonDistributions": inventory, "licenseFiles": files,
              "reviewStatus": "Collected shipped notices; not a legal compliance certification.",
              "omittedGPLTool": "ffmpeg"}
    (root / "license-inventory.json").write_text(json.dumps(report, indent=2) + "\n")
    (root / "THIRD_PARTY_LICENSES.txt").write_text("Shipped Hermes runtime license notices\n" + "".join(texts))


def contained(root, relative):
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe relative path: {relative}")
    value = root / path
    if not value.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"escaped payload path: {relative}")
    return value


def validate(root):
    manifest = json.loads((root / "manifest.json").read_text())
    for key in ("executablePath", "runtimePath"):
        if not contained(root, manifest[key]).exists():
            raise ValueError(f"missing {key}")
    for directory, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink() and (os.path.isabs(os.readlink(path)) or
                                     not path.resolve().is_relative_to(root.resolve()) or not path.exists()):
                raise ValueError(f"invalid payload symlink: {path.relative_to(root)}")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--tools", type=Path, help="existing official pinned tool store; required offline")
    parser.add_argument("--cache", type=Path, help="existing uv wheel cache; required offline")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--allow-downloads", action="store_true")
    parser.add_argument("--bootstrap", action="store_true", help="prepare official pinned tools then run builder on their Python")
    args = parser.parse_args()
    if not args.allow_downloads and (args.tools is None or args.cache is None):
        parser.error("offline builds require --tools and --cache; use --allow-downloads for explicit official PM acquisition")
    source, out = args.source.resolve(), args.out.absolute()
    if out != out.resolve() or out.exists():
        raise ValueError("output must be a new, non-symlinked directory")
    revision = subprocess.check_output(["git", "rev-parse", args.commit + "^{commit}"], cwd=source, text=True).strip()
    if revision != args.commit:
        raise ValueError("pass the exact 40-character source commit")
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if head != revision:
        raise ValueError("builder checkout must be at selected source commit")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=source, check=True)
    # Public pinned acquisition needs no provider or repository credential.
    # Remove credentials before the bootstrap's first official PM import too.
    for key in list(os.environ):
        if (key.endswith(("API_KEY", "AUTH_TOKEN", "ACCESS_TOKEN", "_TOKEN", "_SECRET", "_PASSWORD"))
                or key.startswith(("OPENAI_", "ANTHROPIC_", "AWS_", "AZURE_", "NOUS_"))):
            os.environ.pop(key, None)
    if sys.version_info < (3, 11):
        parser.error("official Hermes build APIs require host Python 3.11+; use a CI Python setup before --bootstrap")
    if args.bootstrap:
        if not args.allow_downloads:
            parser.error("--bootstrap requires explicit --allow-downloads")
        scratch = out.parent / (out.name + ".bootstrap")
        scratch.mkdir(parents=True, exist_ok=False)
        os.environ.update(HERMES_HOME=str(scratch / "profile"),
                          HERMES_RUNTIME_DIR=str(scratch / "tools"),
                          HERMES_DISABLE_LAZY_INSTALLS="1", PYTHONDONTWRITEBYTECODE="1")
        sys.path.insert(0, str(source))
        from pm.build_operations import prepare_tools
        from pm.registry import get_package
        from pm.store import current_target
        target = current_target()
        prepare_tools(("python", "uv", "ripgrep", "node", "npm"), out=scratch / "tools", target=target)
        facts = json.loads((scratch / "tools/facts.json").read_text())["packages"]
        python = get_package("python").binary(scratch / "tools" / facts["python"]["entry"], target)
        command = [str(python), "-I", "-B", str(Path(__file__).resolve()),
                   "--source", str(source), "--commit", revision, "--tools", str(scratch / "tools"),
                   "--out", str(out), "--allow-downloads"]
        if args.cache is not None:
            command += ["--cache", str(args.cache.resolve())]
        raise SystemExit(subprocess.run(command, env=dict(os.environ), check=False).returncode)
    # Isolation applies before importing any official package-manager code.
    out.mkdir(parents=True)
    build = out.parent / (out.name + ".build")
    if build.exists():
        raise ValueError("build scratch already exists")
    build.mkdir()
    os.environ.update(HERMES_HOME=str(build / "profile"),
                      HERMES_RUNTIME_DIR=str(out / "tools"),
                      HERMES_DISABLE_LAZY_INSTALLS="1", PYTHONDONTWRITEBYTECODE="1",
                      UV_CACHE_DIR=str(build / "uv-cache"))
    sys.path.insert(0, str(source))
    from scripts.bundles.payload import (INERT_SNAPSHOT_DIRS, snapshot, record_tools,
                                        seal_pm_runtime, relativize_links)
    from scripts.build.agent import assemble
    from scripts.build.inputs import AgentInputs, RESOURCE_ENV, dependency_site
    from pm.operations import build_environment, stage_manager_runtime
    from pm.registry import get_package
    from pm.store import current_target, tree_digest
    from pm.features import installed_extras, write_features
    from scripts.write_install_stamp import write_stamp
    from pm.build_operations import prepare_tools

    target = current_target()
    if not target.startswith("darwin-"):
        raise ValueError("this helper currently packages macOS only")
    snapshot(source, revision, out / "hermes-agent", exclude=INERT_SNAPSHOT_DIRS)
    repo = out / "hermes-agent"
    names = ("python", "uv", "ripgrep", "node", "npm")
    # FFmpeg is deliberately optional: the available static build is GPLv3+
    # and cannot ship until corresponding-source obligations are addressed.
    tool_source = args.tools
    if tool_source is None:
        tool_source = build / "downloaded-tools"
        prepare_tools(names, out=tool_source, target=target, cache=build / "uv-cache")
    facts = json.loads((tool_source / "facts.json").read_text())["packages"]
    recorded = {}
    (out / "tools").mkdir()
    # Keep the initial native engine compact. Optional browser/node/media tools
    # require a separate explicit product decision; no silent runtime download.
    for name in names:
        fact = facts[name]
        if fact.get("target") not in (target, "any"):
            raise ValueError(f"wrong architecture for {name}")
        entry = contained(tool_source.resolve(), fact["entry"])
        if fact.get("digest") != tree_digest(entry):
            raise ValueError(f"changed prepared tool: {name}")
        shutil.copytree(entry, out / "tools" / fact["entry"], symlinks=True)
        recorded[name] = fact["entry"]
    record_tools(out, repo / "pm/lock.json", target, recorded)
    python = get_package("python").binary(out / "tools" / recorded["python"], target)
    if args.cache is not None:
        shutil.copytree(args.cache, build / "uv-cache", symlinks=True, dirs_exist_ok=True)
    else:
        (build / "uv-cache").mkdir(exist_ok=True)
    stage_manager_runtime(python=python, destination=out / "pm-runtime", project=repo / "pm",
                          offline=not args.allow_downloads, cache=build / "uv-cache")
    seal_pm_runtime(out, python)
    build_environment(source=repo, out=out / "venv", python=python,
                      extras=("all", "web", "acp"), sealed=True,
                      offline=not args.allow_downloads, explicit=True,
                      cache=build / "uv-cache", env=dict(os.environ), timeout=1800)
    features = installed_extras(repo, out / "venv", python_exe=python)
    write_features(features, out)
    site = dependency_site(out / "venv", facts["python"]["version"], target)
    inputs = AgentInputs(project=repo / "pyproject.toml", code=repo, repo="hermes-agent",
                         placement="contained", target=target, python=python,
                         site_packages=site, environment=out / "venv", pm_runtime=out / "pm-runtime",
                         tools=out / "tools", resources={name: repo / name for name in RESOURCE_ENV},
                         frontends={}, ref=revision, features=out / "enabled-features.json")
    assemble(inputs, out)
    relativize_links(out)
    # Official packaged provenance: the runtime must report the admitted commit
    # after git metadata has been excluded, and updates belong to HeyMate.
    os.environ["HERMES_BUILD_COMMIT"] = revision
    os.environ["HERMES_DESKTOP_VARIANT"] = "runtime"
    write_stamp(repo / "install-stamp.json", update_mechanism="external",
                commit=revision, distribution="desktop-app", runtime_dir="..")
    manifest = json.loads((out / "manifest.json").read_text())
    manifest.update(executablePath="bin/hermes", runtimePath="tools", sourceCommit=revision,
                    product="HeyMate headless Hermes", features=features,
                    omittedTools=["ffmpeg", "chromium", "agent-browser", "cua-driver"])
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    collect_licenses(out, facts)
    validate(out)
    print(json.dumps({"payload": str(out), "target": target, "sourceCommit": revision,
                      "executablePath": "bin/hermes", "runtimePath": "tools"}, indent=2))


if __name__ == "__main__":
    main()
