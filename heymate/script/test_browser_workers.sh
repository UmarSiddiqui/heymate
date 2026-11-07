#!/usr/bin/env bash
set -euo pipefail
WORKER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/heymate-browser-workers.XXXXXX")"
WORKER_DATA="$(mktemp -d '/tmp/hmb-bridge.XXXXXX')"
export HEYMATE_NATIVE_BROWSER_TEST=1 HEYMATE_TEST_DATA_ROOT="$WORKER_DATA"
trap 'rm -rf "$WORKER_SCRATCH" "$WORKER_DATA"' EXIT
python3 - "$WORKER_ROOT" "$WORKER_SCRATCH" <<'PY'
from pathlib import Path
import json, shutil, sys
root, scratch = map(Path, sys.argv[1:])
source = scratch/'Sources/HeyMate'; source.mkdir(parents=True)
tests = scratch/'Tests/HeyMateTests'; tests.mkdir(parents=True)
(scratch/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HeyMateBrowserWorkers", platforms: [.macOS(.v14)],
    dependencies: [.package(path: '''+json.dumps(str(root/'Packages/HeyMateComputerUse'))+''')],
    targets: [.target(name: "HeyMate", dependencies: ["HeyMateComputerUse"]),
              .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"])], swiftLanguageModes: [.v5])
''')
for name in ['CuaDriverClient', 'IsolatedBrowserWorkers']:
 shutil.copy2(root/f'HeyMate/{name}.swift',source/f'{name}.swift')
bridge=(root/'HeyMate/BrowserBridge.swift').read_text()
(source/'BrowserBridge.swift').write_text(bridge)
policy=(root/'HeyMate/ApprovalMode.swift').read_text()
# The production browser approval floor is compiled unchanged; omit unrelated
# connector/computer convenience methods and provide their current-mode lookup.
floor=policy[policy.index('nonisolated enum ApprovalFloor'):]
(source/'ApprovalMode.swift').write_text('''import Foundation
nonisolated enum ApprovalMode { case askMe, fullAccess
 static func current() -> ApprovalMode { .askMe }
}
'''+floor)
(source/'AppDependencies.swift').write_text('''import Foundation
import HeyMateComputerUse
@MainActor final class CuaDriverSetup {
 static let shared = CuaDriverSetup()
 var installation: CuaDriverInstallation = .missing
}
struct AgentChatOwner { let mateID: UUID; let chatID: UUID }
enum HeyMateDataDirectory {
 static let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEYMATE_TEST_DATA_ROOT"]!)
 static let isHostingTests = false
}
''')
shutil.copy2(root/'HeyMateTests/IsolatedBrowserWorkersTests.swift',tests/'IsolatedBrowserWorkersTests.swift')
live=root/'HeyMateTests/IsolatedBrowserWorkersLiveTests.swift'
if live.exists(): shutil.copy2(live,tests/live.name)
shutil.copy2(root/'HeyMateTests/BrowserWorkerNativeBridgeTests.swift',tests/'BrowserWorkerNativeBridgeTests.swift')
PY
swift test --package-path "$WORKER_SCRATCH"
