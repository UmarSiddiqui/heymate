#!/usr/bin/env bash
# Run production routine models/scheduler tests without launching HeyMate.
# Xcode's scripts/typecheck.sh --tests also checks the full integration target.
set -euo pipefail
ROUTINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROUTINE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heymate-routines.XXXXXX")"
trap 'rm -rf "$ROUTINE_TEST_DIR"' EXIT
python3 - "$ROUTINE_ROOT" "$ROUTINE_TEST_DIR" <<'PY'
from pathlib import Path
import sys, shutil
root, scratch = map(Path, sys.argv[1:])
source = scratch/'Sources/HeyMate'; source.mkdir(parents=True)
tests = scratch/'Tests/HeyMateTests'; tests.mkdir(parents=True)
(scratch/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HeyMateRoutines", platforms: [.macOS(.v14)],
    targets: [.target(name: "HeyMate", swiftSettings: [.defaultIsolation(MainActor.self)]),
              .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"])],
    swiftLanguageModes: [.v5])
''')
for name in ['MateRoutine', 'MateRoutineScheduler', 'RoutinePhraseParser']:
    shutil.copy2(root/f'HeyMate/{name}.swift', source/f'{name}.swift')
# Manager/store integration needs the app host; Xcode checks those tests.
# Run the unchanged parser, accounting, scheduler, editing and wake tests here.
s = (root/'HeyMateTests/MateRoutineTests.swift').read_text()
a = s.index('@MainActor\nstruct MateRoutineUpdateTests')
b = s.index('@MainActor\nprivate final class FakeRoutinePower')
(tests/'MateRoutineTests.swift').write_text(s[:a] + s[b:])
# Prompt notes are independent from the rest of the harness declarations.
(source/'HarnessTurnNotes.swift').write_text(
    (root/'HeyMate/HarnessTurnNotes.swift').read_text().split('struct HarnessReplyChrome:')[0])
s = (root/'HeyMateTests/HarnessTurnNotesTests.swift').read_text()
a = s.index('    @MainActor @Test func jobTitlesUseTheTaskNotTheNotes()')
(tests/'HarnessTurnNotesTests.swift').write_text(s[:a] + '}\n')
PY
swift test --package-path "$ROUTINE_TEST_DIR"
