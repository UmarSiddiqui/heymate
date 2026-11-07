#!/usr/bin/env bash
set -euo pipefail
CUA_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CUA_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heymate-cua-client.XXXXXX")"
trap 'rm -rf "$CUA_TEST_DIR"' EXIT
python3 - "$CUA_TEST_ROOT" "$CUA_TEST_DIR" <<'PY'
from pathlib import Path
import json, shutil, sys
root, scratch = map(Path, sys.argv[1:])
source = scratch/'Sources/HeyMate'; source.mkdir(parents=True)
tests = scratch/'Tests/HeyMateTests'; tests.mkdir(parents=True)
package = json.dumps(str(root/'Packages/HeyMateComputerUse'))
(scratch/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HeyMateCuaClient", platforms: [.macOS(.v14)],
    dependencies: [.package(path: '''+package+''')],
    targets: [.target(name: "HeyMate", dependencies: ["HeyMateComputerUse"]),
              .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"])],
    swiftLanguageModes: [.v5])
''')
shutil.copy2(root/'HeyMate/CuaDriverClient.swift', source/'CuaDriverClient.swift')
# Only the app's installed-driver lookup needs an app-bound dependency. The
# tested MCP process, requests, cancellation and termination are production code.
(source/'CuaDriverSetup.swift').write_text('''import HeyMateComputerUse
@MainActor final class CuaDriverSetup {
    static let shared = CuaDriverSetup()
    var installation: CuaDriverInstallation = .missing
}
''')
shutil.copy2(root/'HeyMateTests/CuaDriverClientTests.swift', tests/'CuaDriverClientTests.swift')
PY
swift test --package-path "$CUA_TEST_DIR"
