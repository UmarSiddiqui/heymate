//
//  CuaDriverRelease.swift
//  HeyMateComputerUse
//
//  The one Cua driver release HeyMate installs.
//
//  Cua's driver (github.com/trycua/cua, MIT) is a background computer-use
//  daemon: it reads accessibility trees, captures single windows, and
//  delivers clicks and keys to a target app without stealing focus. On macOS
//  it lives at /Applications/CuaDriver.app (com.trycua.driver), and that app
//  identity — not HeyMate — holds the Accessibility and Screen Recording
//  grants. `cua-driver mcp` is a thin stdio front for that daemon.
//
//  HeyMate does not reimplement Cua's installer. That script preserves TCC
//  grants across compatible upgrades, rolls back an interrupted install, and
//  checks every archive against the release's SHA256SUMS. HeyMate downloads
//  that script from a pinned release, refuses it unless it matches the hash
//  below, and runs it with the version pinned — so what lands on the Mac is
//  exactly the release reviewed here, fetched only when the user asks for
//  computer use.
//

import Foundation

public struct CuaDriverRelease: Equatable, Sendable {
    public var version: CuaDriverVersion
    public var installerURL: URL
    /// SHA256 of the installer script, as published in the release's
    /// SHA256SUMS. A mismatch means the script is not the reviewed one.
    public var installerSHA256: String

    public init(version: CuaDriverVersion, installerURL: URL, installerSHA256: String) {
        self.version = version
        self.installerURL = installerURL
        self.installerSHA256 = installerSHA256
    }

    /// Reviewed 2026-10-09. The driver binary is Developer ID signed by
    /// Cua AI, Inc. (YCK386LBJ7). Bump all three together.
    public static let pinned = CuaDriverRelease(
        version: CuaDriverVersion(major: 0, minor: 34, patch: 0),
        installerURL: URL(string: "https://github.com/trycua/cua/releases/download/cua-driver-rs-v0.34.0/_install-rust.sh")!,
        installerSHA256: "06f239c68ef03d4b57cd04a0eebe228b627003b1856a764abff431600ea2a9d7"
    )

    /// The environment the installer runs with: the version pinned, and the
    /// user's shell profile left alone (HeyMate resolves the driver by path,
    /// not through PATH).
    public var installerEnvironment: [String: String] {
        [
            "CUA_DRIVER_RS_VERSION": version.description,
            "CUA_DRIVER_RS_NO_MODIFY_PATH": "1"
        ]
    }

    /// Whether downloaded installer bytes are the reviewed script.
    public func isTrustedInstaller(sha256HexDigest: String) -> Bool {
        sha256HexDigest.lowercased() == installerSHA256
    }
}
