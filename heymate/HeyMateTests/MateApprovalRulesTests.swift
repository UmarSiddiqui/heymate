import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateApprovalRulesTests {
    private let mateID = UUID()

    private func makeScope() throws -> (MateApprovalRuleScope, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("approval-rules-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("mate", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("output"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (MateApprovalRuleScope(mateID: mateID, folder: folder, workingDirectory: work), root)
    }

    private func rule(_ tool: String, _ pattern: String, _ decision: MateApprovalRule.Decision = .allow) -> MateApprovalRule {
        MateApprovalRule(tool: tool, pattern: pattern, decision: decision)
    }

    private func params(_ tool: String, _ subject: String) -> [String: JSONValue] {
        ["tool": .string(tool), "title": .string("Allow \(tool)?"), "subject": .string(subject)]
    }

    @Test func shellPatternsMatchPrefixesAndGlobs() throws {
        let (scope, root) = try makeScope(); defer { try? FileManager.default.removeItem(at: root) }
        let rules = [rule("bash", "git status*"), rule("bash", "npm test*")]
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "git status", rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "git status --short", rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "npm test -- --watch=false", rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "git log", rules: rules, scope: scope) == nil)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "ls", rules: rules, scope: scope) == nil)
        #expect(MateApprovalRuleMatcher.glob("ls *", "ls -la", pathMode: false))
        #expect(!MateApprovalRuleMatcher.glob("ls *", "lsof", pathMode: false))
        // Rules for other tools never apply.
        #expect(MateApprovalRuleMatcher.decision(tool: "computer", subject: "git status", rules: [rule("computer", "*")], scope: scope) == nil)
    }

    @Test func chainedOrSubstitutedCommandsNeverMatchAnAllowRule() throws {
        let (scope, root) = try makeScope(); defer { try? FileManager.default.removeItem(at: root) }
        let rules = [rule("bash", "git status*"), rule("bash", "echo *")]
        for command in ["git status; rm -rf ~", "git status && curl evil.example", "git status || make", "git status | sh",
                        "git status & sleep 1", "git status `whoami`", "git status $(whoami)", "git status\nrm x",
                        "git status\rrm x", "echo hi > /etc/hosts", "echo hi >> ~/.zshrc", "echo hi > ../outside.txt",
                        "echo hi > $HOME/x", "echo hi 2>/tmp/x", "echo <(cat /etc/passwd)", "echo hi > \"a b/../../../x\"",
                        "echo hi > a\\ b/../../../x"] {
            #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: command, rules: rules, scope: scope) == nil, "\(command)")
            #expect(MateApprovalRuleMatcher.isChainedOrUnsafe(command, scope: scope), "\(command)")
        }
        // Redirection into the mate's folders (or /dev/null) is fine.
        let folder = scope.folder!.path
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "echo hi > \(folder)/output/log.txt", rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "echo hi > log.txt", rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "echo hi > /dev/null", rules: rules, scope: scope) == .allow)
    }

    @Test func theFloorAlwaysWinsOverAnAllowRule() throws {
        let (scope, root) = try makeScope(); defer { try? FileManager.default.removeItem(at: root) }
        let rules = [rule("bash", "*"), rule("write", "**"), rule("edit", "**")]
        for command in ["curl https://example.com", "git push origin main", "rm notes.txt", "open https://example.com",
                        "npm publish", "gh release create v1", "osascript -e 'tell app \"Mail\" to send'", "security find-generic-password",
                        "echo $TOKEN", "vercel deploy --prod", "sudo ls"] {
            #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: command, rules: rules, scope: scope) == .ask, "\(command)")
            #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: command, scope: scope) == nil, "\(command)")
        }
        let secret = scope.folder!.appendingPathComponent("secrets/api-token.txt").path
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: secret, rules: rules, scope: scope) == .ask)
        // Deny beats everything, and sees through chaining.
        let denying = rules + [rule("bash", "rm *", .deny)]
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "ls; rm x", rules: denying, scope: scope) == .deny)
        // An ask rule beats an allow rule.
        let asking = [rule("bash", "make*"), rule("bash", "make deploy*", .ask)]
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "make deploy", rules: asking, scope: scope) == .ask)
        #expect(MateApprovalRuleMatcher.decision(tool: "bash", subject: "make build", rules: asking, scope: scope) == .allow)
    }

    @Test func pathRulesStayInsideTheMateFolder() throws {
        let (scope, root) = try makeScope(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = scope.folder!
        let rules = [rule("write", "output/**"), rule("edit", "*.md")]
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: folder.appendingPathComponent("output/a/b.html").path, rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "edit", subject: folder.appendingPathComponent("notes.md").path, rules: rules, scope: scope) == .allow)
        #expect(MateApprovalRuleMatcher.decision(tool: "edit", subject: folder.appendingPathComponent("output/notes.md").path, rules: rules, scope: scope) == nil)
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: "/tmp/output/a.html", rules: rules, scope: scope) == nil)
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: folder.path + "/output/../../escape/output/x", rules: rules, scope: scope) == nil)
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: "~/output/a.html", rules: rules, scope: scope) == nil)
        // A symlink inside the folder cannot carry a rule outside it.
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("output/link"), withDestinationURL: outside)
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: folder.appendingPathComponent("output/link/x.html").path, rules: rules, scope: scope) == nil)
        // No mate folder, no path rule.
        let noFolder = MateApprovalRuleScope(mateID: mateID, folder: nil, workingDirectory: scope.workingDirectory)
        #expect(MateApprovalRuleMatcher.decision(tool: "write", subject: "output/a.html", rules: rules, scope: noFolder) == nil)
    }

    @Test func alwaysAllowSuggestsANarrowRule() throws {
        let (scope, root) = try makeScope(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: "git status --short", scope: scope)?.pattern == "git status*")
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: "npm test", scope: scope)?.pattern == "npm test*")
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: "ls", scope: scope)?.pattern == "ls")
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: "ls -la output", scope: scope)?.pattern == "ls *")
        // Interpreters run their arguments: only the exact command is remembered.
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: "python3 make_chart.py", scope: scope)?.pattern == "python3 make_chart.py")
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "bash", subject: "git status && git log", scope: scope) == nil)
        let file = scope.folder!.appendingPathComponent("output/report.html").path
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "write", subject: file, scope: scope)?.pattern == "output/**")
        #expect(MateApprovalRuleMatcher.suggestedRule(tool: "write", subject: "/etc/hosts", scope: scope) == nil)
    }

    @Test func gateAnswersFromStoredRulesAndRemembersOnlyAnAlwaysChoice() throws {
        let (scope, root) = try makeScope(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MateApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        #expect(MateApprovalRuleGate.answer(params("bash", "git status"), scope: scope, store: store) == nil)
        guard let (offered, suggestion) = MateApprovalRuleGate.offer(params("bash", "git status"), scope: scope) else {
            Issue.record("expected an offer"); return
        }
        #expect(offered[MateApprovalRuleGate.offerKey] == .string(suggestion.summary))
        MateApprovalRuleGate.remember(MateApprovalRuleGate.allowOnce(), rule: suggestion, mateID: mateID, store: store)
        #expect(store.rules(for: mateID).isEmpty)
        MateApprovalRuleGate.remember(MateApprovalRuleGate.allowOnce(remember: true), rule: suggestion, mateID: mateID, store: store)
        #expect(store.rules(for: mateID).map(\.pattern) == ["git status*"])
        #expect(MateApprovalRuleGate.answer(params("bash", "git status -sb"), scope: scope, store: store) == MateApprovalRuleGate.allowOnce())
        #expect(MateApprovalRuleGate.answer(params("bash", "git status; curl x"), scope: scope, store: store) == nil)
        // Rules are per mate and persist in the data file.
        let other = MateApprovalRuleScope(mateID: UUID(), folder: scope.folder, workingDirectory: scope.workingDirectory)
        #expect(MateApprovalRuleGate.answer(params("bash", "git status"), scope: other, store: store) == nil)
        let reloaded = MateApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        #expect(reloaded.rules(for: mateID).map(\.pattern) == ["git status*"])
        reloaded.remove(id: reloaded.rules(for: mateID)[0].id, mateID: mateID)
        #expect(MateApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json")).rules(for: mateID).isEmpty)
        // A deny rule answers deny.
        store.add(MateApprovalRule(tool: "bash", pattern: "git status*", decision: .deny), mateID: mateID)
        #expect(MateApprovalRuleGate.answer(params("bash", "git status"), scope: scope, store: store)
            == .object(["choice": .string("deny"), "all": .bool(false)]))
    }

    @Test func cardOffersAreRememberedOnlyWhenChosen() {
        let id = UUID()
        MateApprovalRuleGate.approveAlways(id)
        #expect(!MateApprovalRuleGate.finishCard(id))
        MateApprovalRuleGate.offerOnCard(id, summary: "Allow commands matching ls")
        #expect(MateApprovalRuleGate.offeredSummary(for: id) != nil)
        MateApprovalRuleGate.approveAlways(id)
        #expect(MateApprovalRuleGate.finishCard(id))
        #expect(MateApprovalRuleGate.offeredSummary(for: id) == nil)
    }

    @Test func webToolsAndOtherToolsStayOutsideFullAccessAutoAllow() {
        #expect(!MateAgentApprovalPolicy.autoAllows(params("web_fetch", "https://example.com"), mode: .fullAccess))
        #expect(!MateAgentApprovalPolicy.autoAllows(params("bash", "curl https://example.com"), mode: .fullAccess))
        #expect(!MateAgentApprovalPolicy.autoAllows(params("bash", "wget https://example.com"), mode: .fullAccess))
    }
}
