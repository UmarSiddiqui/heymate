import Foundation
import Testing
@testable import HeyMate

struct SubscriptionCLIUpdateTests {
    @Test func keepingCLIsUpdatedIsOnUntilTurnedOff() {
        let defaults = isolatedDefaults("enabled")
        #expect(SubscriptionCLIUpdatePreference.isEnabled(in: defaults))
        SubscriptionCLIUpdatePreference.setEnabled(false, in: defaults)
        #expect(!SubscriptionCLIUpdatePreference.isEnabled(in: defaults))
        SubscriptionCLIUpdatePreference.setEnabled(true, in: defaults)
        #expect(SubscriptionCLIUpdatePreference.isEnabled(in: defaults))
    }

    @Test func automaticUpdateRunsOnceADay() {
        let defaults = isolatedDefaults("schedule")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(SubscriptionCLIUpdatePreference.shouldUpdateAutomatically(now: now, in: defaults))
        SubscriptionCLIUpdatePreference.markAutomaticUpdateFinished(at: now, in: defaults)
        #expect(!SubscriptionCLIUpdatePreference.shouldUpdateAutomatically(
            now: now.addingTimeInterval(60 * 60),
            in: defaults
        ))
        #expect(SubscriptionCLIUpdatePreference.shouldUpdateAutomatically(
            now: now.addingTimeInterval(SubscriptionCLIUpdatePreference.automaticInterval),
            in: defaults
        ))
        SubscriptionCLIUpdatePreference.setEnabled(false, in: defaults)
        #expect(!SubscriptionCLIUpdatePreference.shouldUpdateAutomatically(
            now: now.addingTimeInterval(SubscriptionCLIUpdatePreference.automaticInterval + 1),
            in: defaults
        ))
    }

    @Test func plansUseEachCLIsOwnInstaller() {
        let home = "/Users/example"
        let plans = SubscriptionCLIUpdatePlanner.plans { name in
            switch name {
            case "claude":
                return URL(fileURLWithPath: "\(home)/.local/bin/claude")
            case "codex":
                return URL(fileURLWithPath: "\(home)/.local/lib/node_modules/@openai/codex/bin/codex.js")
            case "npm":
                return URL(fileURLWithPath: "/usr/local/bin/npm")
            case "opencode":
                return URL(fileURLWithPath: "\(home)/.bun/install/global/node_modules/opencode-ai/bin/opencode.exe")
            default:
                return nil
            }
        }

        #expect(plans.count == 3)
        guard case .command(let claude) = plans[0] else {
            Issue.record("Claude should update itself")
            return
        }
        #expect(claude.updateArguments == ["update"])

        guard case .command(let codex) = plans[1] else {
            Issue.record("Codex should update through npm")
            return
        }
        #expect(codex.updateArguments == [
            "install", "-g", "--prefix", "\(home)/.local", "@openai/codex@latest"
        ])

        guard case .command(let opencode) = plans[2] else {
            Issue.record("OpenCode should upgrade in place")
            return
        }
        #expect(opencode.updateArguments == ["upgrade", "--method", "bun"])
    }

    @Test func homebrewCodexUsesBrewAndAMissingCLIIsSkipped() {
        let plans = SubscriptionCLIUpdatePlanner.plans { name in
            switch name {
            case "codex":
                return URL(fileURLWithPath: "/opt/homebrew/Cellar/codex/0.1/bin/codex")
            case "brew":
                return URL(fileURLWithPath: "/opt/homebrew/bin/brew")
            default:
                return nil
            }
        }
        #expect(plans[0] == .skipped(name: "Claude", reason: "not installed"))
        guard case .command(let codex) = plans[1] else {
            Issue.record("Homebrew Codex should use brew")
            return
        }
        #expect(codex.updateArguments == ["upgrade", "codex"])
        #expect(plans[2] == .skipped(name: "OpenCode", reason: "not installed"))
    }

    @Test func anUnchangedVersionStaysCurrentAndAFailureIsReported() {
        let current = SubscriptionCLIUpdater.interpret(
            cliName: "Codex",
            before: "0.157.1",
            after: "0.157.1",
            status: 0,
            output: "changed 0 packages"
        )
        #expect(current.line == "Codex is current (0.157.1)")

        let updated = SubscriptionCLIUpdater.interpret(
            cliName: "Claude",
            before: "2.1.245",
            after: "2.1.283",
            status: 0,
            output: "Successfully updated"
        )
        #expect(updated.line == "Claude updated to 2.1.283")

        let failed = SubscriptionCLIUpdater.interpret(
            cliName: "OpenCode",
            before: "1.18.25",
            after: nil,
            status: 1,
            output: "\u{001B}[31mnetwork failed\u{001B}[0m"
        )
        #expect(failed.line == "OpenCode failed: network failed")
    }

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suite = "SubscriptionCLIUpdateTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
