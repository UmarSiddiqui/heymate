//
//  CuaDriverVersion.swift
//  HeyMateComputerUse
//

import Foundation

public struct CuaDriverVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Reads `cua-driver --version` output ("cua-driver 0.34.0") or a bare
    /// "0.34.0". Pre-release and build suffixes are ignored.
    public init?(versionOutput: String) {
        let token = versionOutput
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .first(where: { $0.first?.isNumber == true })
        guard let token else { return nil }
        let core = token.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? token
        let parts = core.split(separator: ".").map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
