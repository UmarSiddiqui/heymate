#!/usr/bin/env bash
# Run actual local memory storage/retrieval against disposable data only.
set -euo pipefail
MEMORY_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEMORY_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heymate-memory-core.XXXXXX")"
trap 'rm -rf "$MEMORY_TEST_DIR"' EXIT
python3 - "$MEMORY_TEST_ROOT" "$MEMORY_TEST_DIR" <<'PY'
from pathlib import Path
import shutil, sys
root, scratch = map(Path, sys.argv[1:])
source = scratch/'Sources/HeyMate'; source.mkdir(parents=True)
tests = scratch/'Tests/HeyMateTests'; tests.mkdir(parents=True)
(scratch/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HeyMateMemoryCore", platforms: [.macOS(.v14)],
    targets: [.target(name: "HeyMate", swiftSettings: [.defaultIsolation(MainActor.self)],
                      linkerSettings: [.linkedLibrary("sqlite3")]),
              .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"])],
    swiftLanguageModes: [.v5])
''')
for name in ['MemoryRepository', 'MemoryRecall', 'MemorySearchIndex', 'HeyMateDataDirectory']:
    shutil.copy2(root/f'HeyMate/{name}.swift', source/f'{name}.swift')
for name in ['MemoryRepositoryTests', 'MemoryRecallTests']:
    shutil.copy2(root/f'HeyMateTests/{name}.swift', tests/f'{name}.swift')
PY
HEYMATE_TEST_DATA_ROOT="$MEMORY_TEST_DIR/profile" swift test --package-path "$MEMORY_TEST_DIR"
