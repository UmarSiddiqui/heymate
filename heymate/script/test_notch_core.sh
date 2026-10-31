#!/usr/bin/env bash
# Exercise actual notch readers/models without launching or signing HeyMate.
# The full app/test target is still checked by scripts/typecheck.sh --tests.
set -euo pipefail
NOTCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTCH_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heymate-notch-core.XXXXXX")"
trap 'rm -rf "$NOTCH_TEST_DIR"' EXIT
python3 - "$NOTCH_ROOT" "$NOTCH_TEST_DIR" <<'PY'
from pathlib import Path
import sys, shutil
root, scratch=map(Path,sys.argv[1:])
source=scratch/'Sources/HeyMate'; source.mkdir(parents=True)
tests=scratch/'Tests/HeyMateTests'; tests.mkdir(parents=True)
(scratch/'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "HeyMateNotchCore", platforms: [.macOS(.v14)],
    products: [.library(name: "HeyMate", targets: ["HeyMate"])],
    targets: [.target(name: "HeyMate", swiftSettings: [.defaultIsolation(MainActor.self)]),
              .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"])],
    swiftLanguageModes: [.v5])
''')
for file in (root/'HeyMate/Codenotch').glob('*.swift'): shutil.copy2(file,source/file.name)
for name in ['NotchUsageStore','NotchProviderCatalog','NotchCodenotchReader','NotchExternalActivity','NotchLayoutMath','NotchGlyphOutline','NotchCompactStatus','NotchOpenCue','NotchOpenRing']:
    shutil.copy2(root/f'HeyMate/{name}.swift',source/f'{name}.swift')
# Ring host declarations are independent from the rest of HeyMate's services.
view=(root/'HeyMate/NotchUsageView.swift').read_text().split('struct NotchUsageView:')[0]
# The compact usage host now shares a font token with the full app. Carry the
# actual token declaration without importing unrelated app services.
micro=next(line.strip() for line in (root/'HeyMate/DesignSystem.swift').read_text().splitlines() if 'static let micro = ' in line)
view += '\nenum DS { enum Fonts { ' + micro + ' } }\n'
(source/'NotchUsageRingHost.swift').write_text(view)
for file in (root/'HeyMateTests/Codenotch').glob('*.swift'): shutil.copy2(file,tests/file.name)
shutil.copy2(root/'HeyMateTests/NotchCodenotchIntegrationTests.swift',tests/'NotchCodenotchIntegrationTests.swift')
shutil.copy2(root/'HeyMateTests/NotchCompactStatusTests.swift',tests/'NotchCompactStatusTests.swift')
shutil.copy2(root/'HeyMateTests/NotchOpenCueTests.swift',tests/'NotchOpenCueTests.swift')
# The transition-model test needs NotchChatView's SwiftUI host; Xcode runs it.
s=(root/'HeyMateTests/NotchLayoutMathTests.swift').read_text()
a=s.index('    @Test func workspaceCanReverseMidMorphWithoutNeckOrContentJumping()')
b=s.index('    @',a+10)
(tests/'NotchLayoutMathTests.swift').write_text(s[:a]+s[b:])
# This one legacy test constructs the whole app's micro-app center. Xcode
# compiles it; every parser/cache test here remains the real test source.
s=(root/'HeyMateTests/NotchUsageTests.swift').read_text()
a=s.index('    @MainActor @Test func legacyMicroAppsNeverStartFromSavedPreferences()')
b=s.index('    @',a+10)
s=s[:a]+s[b:]
(tests/'NotchUsageTests.swift').write_text(s)
PY
swift test --package-path "$NOTCH_TEST_DIR" --parallel
