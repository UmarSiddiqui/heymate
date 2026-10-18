#!/usr/bin/env python3
"""Probe a bundled runtime with a new empty profile; never send a model prompt."""
import argparse
import json
import os
from pathlib import Path
import platform
import secrets
import subprocess
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = args.payload.resolve()
    manifest = json.loads((root / "manifest.json").read_text())
    if "payloads" in manifest:
        arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x86_64"
        root = root / manifest["payloads"][arch]
        manifest = json.loads((root / "manifest.json").read_text())
    home = args.out.absolute()
    home.mkdir(parents=True, exist_ok=False)
    token = secrets.token_urlsafe(32)
    ready = home / "ready.json"
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
           "HERMES_HOME": str(home), "HERMES_RUNTIME_DIR": str(root / manifest["runtimePath"]),
           "HERMES_DISABLE_LAZY_INSTALLS": "1", "HERMES_DESKTOP": "1",
           "HERMES_DASHBOARD_SESSION_TOKEN": token, "HERMES_DESKTOP_READY_FILE": str(ready),
           "PYTHONPYCACHEPREFIX": str(home / "pycache"), "PYTHONDONTWRITEBYTECODE": "1"}
    executable = root / manifest["executablePath"]
    report = {"modelCalls": 0, "sourceCommit": manifest["sourceCommit"]}
    for name, command in (("version", ["--version"]), ("acpCheck", ["acp", "--check"])):
        checked = subprocess.run([str(executable), *command], cwd=home, env=env,
                                 text=True, capture_output=True, timeout=45)
        report[name] = {"exit": checked.returncode, "passed": checked.returncode == 0}
    with (home / "server.log").open("w") as log:
        child = subprocess.Popen([str(executable), "serve", "--isolated", "--host", "127.0.0.1", "--port", "0"],
                                 cwd=home, env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 60
            while not ready.exists() and time.monotonic() < deadline and child.poll() is None:
                time.sleep(0.2)
            report["ready"] = ready.exists()
            if ready.exists():
                port = json.loads(ready.read_text())["port"]

                def get(path):
                    request = urllib.request.Request("http://127.0.0.1:" + str(port) + path,
                                                     headers={"X-Hermes-Session-Token": token})
                    with urllib.request.urlopen(request, timeout=20) as response:
                        return json.load(response)

                health, identity, status = get("/api/health"), get("/api/host/identity"), get("/api/status")
                report.update(health=health, pidMatches=identity.get("pid") == child.pid,
                              headless=identity.get("servesSpa") is False,
                              homeMatches=status.get("hermes_home") == str(home),
                              commitMatches=health.get("commit") == manifest["sourceCommit"])
            else:
                report["processExit"] = child.poll()
        finally:
            child.terminate()
            try:
                child.wait(timeout=8)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    report["passed"] = (all(report[name]["passed"] for name in ("version", "acpCheck")) and
                        all(report.get(name) for name in ("ready", "pidMatches", "headless", "homeMatches", "commitMatches")))
    (home / "smoke-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
