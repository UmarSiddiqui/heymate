#!/usr/bin/env bash
# Exercise production analytics with disposable defaults and injected transport.
# Never launches HeyMate or sends a production event.
set -euo pipefail
analytics_source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
analytics_checks_root="$(mktemp -d "${TMPDIR:-/tmp}/heymate-analytics-tests.XXXXXX")"
trap 'rm -rf "$analytics_checks_root"' EXIT
mkdir -p "$analytics_checks_root/Sources" "$analytics_checks_root/Tests"
cp "$analytics_source_root/HeyMate/HeyMateAnalytics.swift" "$analytics_checks_root/Sources/"
cp "$analytics_source_root/HeyMate/AppBundleConfiguration.swift" "$analytics_checks_root/Sources/"
cp "$analytics_source_root/HeyMateTests/UsageAnalyticsTests.swift" "$analytics_checks_root/Tests/"
cat > "$analytics_checks_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "HeyMateAnalyticsChecks",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HeyMate", path: "Sources", swiftSettings: [
            .defaultIsolation(MainActor.self),
            .enableUpcomingFeature("IsolatedDefaultValues")
        ]),
        .testTarget(name: "HeyMateTests", dependencies: ["HeyMate"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
SWIFT
swift test --package-path "$analytics_checks_root"
