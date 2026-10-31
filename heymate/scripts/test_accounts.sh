#!/usr/bin/env bash
# Run production account/client sources without launching a HeyMate GUI,
# reading the real Keychain, or sending production network requests.
set -euo pipefail
account_source_root="$(cd "$(dirname "$0")/.." && pwd)"
account_checks_root="$(mktemp -d "${TMPDIR:-/tmp}/heymate-account-tests.XXXXXX")"
trap 'rm -rf "$account_checks_root"' EXIT
mkdir -p "$account_checks_root/Sources" "$account_checks_root/Tests"
cp "$account_source_root/HeyMate/FirebaseAccountClient.swift" "$account_checks_root/Sources/"
cp "$account_source_root/HeyMate/GoogleOAuthFlow.swift" "$account_checks_root/Sources/"
cp "$account_source_root/HeyMate/HeyMateAccount.swift" "$account_checks_root/Sources/"
cp "$account_source_root/HeyMateTests/GoogleOAuthFlowTests.swift" "$account_checks_root/Tests/"
cp "$account_source_root/HeyMateTests/HeyMateAccountTests.swift" "$account_checks_root/Tests/"
cp "$account_source_root/HeyMateTests/FirebaseAccountClientTests.swift" "$account_checks_root/Tests/"
cat > "$account_checks_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "HeyMateAccountChecks",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HeyMate", path: "Sources", swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"], path: "Tests")
    ]
)
SWIFT
swift test --package-path "$account_checks_root"
