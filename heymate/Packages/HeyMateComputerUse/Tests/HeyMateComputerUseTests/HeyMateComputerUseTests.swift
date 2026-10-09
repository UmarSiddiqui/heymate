import Foundation
import Testing
@testable import HeyMateComputerUse

struct CuaDriverVersionTests {
    @Test func readsCLIOutput() {
        #expect(CuaDriverVersion(versionOutput: "cua-driver 0.34.0\n") == CuaDriverVersion(major: 0, minor: 34, patch: 0))
        #expect(CuaDriverVersion(versionOutput: "0.30.5-nightly.20260929") == CuaDriverVersion(major: 0, minor: 30, patch: 5))
        #expect(CuaDriverVersion(versionOutput: "cua-driver-rs: invalid daemon response") == nil)
        #expect(CuaDriverVersion(versionOutput: "") == nil)
    }

    @Test func comparesNumerically() {
        #expect(CuaDriverVersion(major: 0, minor: 9, patch: 9) < CuaDriverVersion(major: 0, minor: 22, patch: 2))
        #expect(CuaDriverVersion(major: 0, minor: 22, patch: 2) < CuaDriverRelease.pinned.version)
    }
}

struct CuaDriverReleaseTests {
    @Test func installerIsPinnedToTheSameVersion() {
        let release = CuaDriverRelease.pinned
        #expect(release.installerURL.absoluteString.contains("cua-driver-rs-v\(release.version)"))
        #expect(release.installerEnvironment["CUA_DRIVER_RS_VERSION"] == release.version.description)
        #expect(release.installerEnvironment["CUA_DRIVER_RS_NO_MODIFY_PATH"] == "1")
        #expect(release.installerURL.scheme == "https")
    }

    @Test func onlyTheReviewedScriptIsTrusted() {
        let release = CuaDriverRelease.pinned
        #expect(release.isTrustedInstaller(sha256HexDigest: release.installerSHA256.uppercased()))
        #expect(!release.isTrustedInstaller(sha256HexDigest: String(repeating: "0", count: 64)))
    }
}

struct CuaDriverInstallationTests {
    let executable = URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")

    @Test func classifiesByVersion() {
        #expect(CuaDriverInstallation.classify(executable: nil, versionOutput: nil) == .missing)
        #expect(CuaDriverInstallation.classify(executable: executable, versionOutput: "cua-driver 0.22.2")
            == .outdated(executable: executable, version: CuaDriverVersion(major: 0, minor: 22, patch: 2)))
        let ready = CuaDriverInstallation.classify(executable: executable, versionOutput: "cua-driver 0.34.0")
        #expect(ready.readyExecutable == executable)
        #expect(CuaDriverInstallation.classify(executable: executable, versionOutput: "garbage").readyExecutable == nil)
    }

    @Test func appBundleComesBeforeTheSymlink() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let candidates = CuaDriverInstallation.candidateExecutables(homeDirectory: home)
        #expect(candidates.first?.path == "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")
        #expect(candidates.last?.path == "/Users/someone/.local/bin/cua-driver")
    }
}

struct CuaDriverToolPolicyTests {
    @Test func listsDoNotOverlap() {
        let observation = Set(CuaDriverToolPolicy.observationTools)
        let action = Set(CuaDriverToolPolicy.actionTools)
        let refused = Set(CuaDriverToolPolicy.refusedTools)
        #expect(observation.isDisjoint(with: action))
        #expect(observation.isDisjoint(with: refused))
        #expect(action.isDisjoint(with: refused))
    }

    @Test func clipboardAndDriverConfigurationNeverReachAJob() {
        for tool in ["clipboard_read", "clipboard_write", "set_config", "install_ffmpeg", "kill_app"] {
            #expect(!CuaDriverToolPolicy.approvedLegTools.contains(tool))
        }
    }
}

struct CuaDriverMCPConfigurationTests {
    let executable = URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")

    @Test func claudeEntryRunsTheStdioFront() {
        let entry = CuaDriverMCPConfiguration.claudeServerEntry(executable: executable)
        #expect(entry["command"] as? String == executable.path)
        #expect(entry["args"] as? [String] == ["mcp"])
    }

    @Test func claudeAllowListNamesEveryToolAndNeverTheBareServer() {
        let names = CuaDriverMCPConfiguration.claudeAllowedToolNames()
        #expect(!names.contains("mcp__cua"))
        #expect(names.contains("mcp__cua__click"))
        #expect(!names.contains("mcp__cua__clipboard_read"))
        #expect(names.count == CuaDriverToolPolicy.approvedLegTools.count)
    }

    @Test func codexArgumentsEnableOnlyTheApprovedTools() {
        let arguments = CuaDriverMCPConfiguration.codexArguments(executable: executable, tools: ["click", "zoom"])
        #expect(arguments == [
            "-c", "mcp_servers.cua.command=\"/Applications/CuaDriver.app/Contents/MacOS/cua-driver\"",
            "-c", "mcp_servers.cua.args=[\"mcp\"]",
            "-c", "mcp_servers.cua.enabled_tools=[\"click\",\"zoom\"]",
            "-c", "mcp_servers.cua.default_tools_approval_mode=\"approve\""
        ])
    }

    @Test func tomlQuotingEscapes() {
        #expect(CuaDriverMCPConfiguration.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}
