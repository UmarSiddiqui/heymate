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

struct CuaDriverWindowReadContractTests {
    let modern = CuaDriverWindowReadContract(inputSchema: [
        "properties": ["tree_format": ["enum": ["markdown", "elements", "both"]]]
    ])

    @Test func modernTreesIncludeStructuredControlsAndMarkdownText() {
        let arguments = modern.arguments(["pid": 42, "window_id": 7, "include_screenshot": false])
        #expect(arguments["tree_format"] as? String == "both")
        #expect(arguments["pid"] as? Int == 42)
        #expect(arguments["include_screenshot"] as? Bool == false)
    }

    @Test func oldDriversReceiveNoUnsupportedFormatArgument() {
        let legacy = CuaDriverWindowReadContract(inputSchema: ["properties": [:]])
        #expect(legacy.arguments(["pid": 42])["tree_format"] == nil)
        let unknown = CuaDriverWindowReadContract(inputSchema: [
            "properties": ["tree_format": ["enum": ["markdown"]]]
        ])
        #expect(unknown.arguments(["pid": 42])["tree_format"] == nil)
    }

    @Test func geometryOnlyReadsKeepTheirCaptureContract() {
        let arguments = modern.arguments(["include_accessibility_tree": false, "max_image_dimension": 0])
        #expect(arguments["tree_format"] == nil)
        #expect(arguments["include_accessibility_tree"] as? Bool == false)
        #expect(arguments["max_image_dimension"] as? Int == 0)
    }
}

struct CuaDriverTextReplacementPolicyTests {
    func tree(parentRole: String = "AXGroup") -> [String: Any] {
        ["elements_complete": true, "truncated": false, "elements": [
            ["element_index": 0, "role": "AXWindow", "depth": 0],
            ["element_index": 1, "parent_index": 0, "role": parentRole, "depth": 1],
            ["element_index": 2, "parent_index": 1, "role": "AXTextField", "element_token": "s00000001:2", "depth": 2]
        ]]
    }

    @Test func completeNativeFieldCanUseValueReplacement() {
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: tree()) == ["s00000001:2"])
    }

    @Test func webFieldsCannotUseNativeValueReplacement() {
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: tree(parentRole: "AXWebArea")).isEmpty)
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: tree(parentRole: "AXWebView")).isEmpty)
    }

    @Test func partialAndUnprovenTreesCannotUseValueReplacement() {
        var partial = tree()
        partial["truncated"] = true
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: partial).isEmpty)
        partial = tree()
        partial.removeValue(forKey: "elements_complete")
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: partial).isEmpty)
    }

    @Test func brokenAncestryAndCyclesAreRefused() {
        var state = tree()
        var elements = state["elements"] as! [[String: Any]]
        elements[1]["parent_index"] = 99
        state["elements"] = elements
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: state).isEmpty)
        elements[1]["parent_index"] = 2
        state["elements"] = elements
        #expect(CuaDriverTextReplacementPolicy.nativeTextTokens(in: state).isEmpty)
    }

    @Test func toolSuccessAloneDoesNotProveReplacement() {
        #expect(!CuaDriverTextReplacementPolicy.confirmsReplacement([:]))
        #expect(!CuaDriverTextReplacementPolicy.confirmsReplacement(["effect": "unverifiable"]))
        #expect(!CuaDriverTextReplacementPolicy.confirmsReplacement(["effect": "confirmed"]))
        #expect(CuaDriverTextReplacementPolicy.confirmsReplacement([
            "effect": "confirmed", "evidence": [["kind": "value_readback"]]
        ]))
    }
}

struct CuaDriverInstallationTests {
    let executable = URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver")

    @Test func classifiesByVersion() {
        #expect(CuaDriverInstallation.classify(executable: nil, versionOutput: nil) == .missing)
        #expect(CuaDriverInstallation.classify(executable: executable, versionOutput: "cua-driver 0.22.2")
            == .outdated(executable: executable, version: CuaDriverVersion(major: 0, minor: 22, patch: 2)))
        #expect(CuaDriverInstallation.classify(executable: executable, versionOutput: "cua-driver 0.34.0")
            == .outdated(executable: executable, version: CuaDriverVersion(major: 0, minor: 34, patch: 0)))
        let ready = CuaDriverInstallation.classify(executable: executable, versionOutput: "cua-driver 0.38.0")
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
