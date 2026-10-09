// swift-tools-version: 6.0
//
// HeyMateComputerUse — the first module carved out of the app target.
//
// Holds everything about computer use that can be decided without AppKit or
// a running app: which Cua driver release HeyMate trusts, where an installed
// driver lives, which of its tools a job may call, and how those tools are
// handed to a Claude or Codex child. Pure values, tested with `swift test`
// in seconds instead of an Xcode app build.

import PackageDescription

let package = Package(
    name: "HeyMateComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HeyMateComputerUse", targets: ["HeyMateComputerUse"])
    ],
    targets: [
        .target(name: "HeyMateComputerUse"),
        .testTarget(name: "HeyMateComputerUseTests", dependencies: ["HeyMateComputerUse"])
    ]
)
