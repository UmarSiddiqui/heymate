//
//  CuaDriverInstallation.swift
//  HeyMateComputerUse
//
//  Where an installed driver is, and whether HeyMate can use it.
//

import Foundation

public enum CuaDriverInstallation: Equatable, Sendable {
    /// No driver on this Mac.
    case missing
    /// A driver older than the pinned release. Its daemon speaks an older
    /// contract and a current `mcp` front refuses it, so it is upgraded
    /// rather than used.
    case outdated(executable: URL, version: CuaDriverVersion)
    case ready(executable: URL, version: CuaDriverVersion)

    /// The executable an MCP config may point at, only when ready.
    public var readyExecutable: URL? {
        if case .ready(let executable, _) = self { return executable }
        return nil
    }

    /// The app bundle's binary first: it is the identity the TCC grants
    /// belong to, and the installer's ~/.local/bin entry is only a symlink
    /// to it.
    public static func candidateExecutables(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"),
            homeDirectory.appendingPathComponent("Applications/CuaDriver.app/Contents/MacOS/cua-driver"),
            homeDirectory.appendingPathComponent(".local/bin/cua-driver")
        ]
    }

    /// Classifies a found executable by its reported version against the
    /// minimum HeyMate needs.
    public static func classify(
        executable: URL?,
        versionOutput: String?,
        minimum: CuaDriverVersion = CuaDriverRelease.pinned.version
    ) -> CuaDriverInstallation {
        guard let executable else { return .missing }
        guard let versionOutput, let version = CuaDriverVersion(versionOutput: versionOutput) else {
            // Present but unreadable: treat as something to reinstall over.
            return .outdated(executable: executable, version: CuaDriverVersion(major: 0, minor: 0, patch: 0))
        }
        return version < minimum
            ? .outdated(executable: executable, version: version)
            : .ready(executable: executable, version: version)
    }
}
