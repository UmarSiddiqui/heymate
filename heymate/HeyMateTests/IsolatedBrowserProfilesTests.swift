import Foundation
import Testing
@testable import HeyMate

/// Per-mate persistent profiles, migration, least-recently-used closing and
/// full-page extract, with the same fake transport pattern as
/// IsolatedBrowserWorkersTests. No Chrome or CuaDriver is started.
@MainActor
struct IsolatedBrowserProfilesTests {
    private final class Driver: BrowserWorkerTransport {
        var calls: [(String, [String: Any])] = []
        var stopped = false
        var scrolls = 0
        /// Viewport text for each scroll position; the last one repeats.
        var viewports: [String] = ["Fixture content"]
        func start() async throws {}
        func stop() { stopped = true }
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            guard !stopped else { throw CancellationError() }
            calls.append((tool, arguments))
            switch tool {
            case "browser_prepare": return ["prepared": true, "prepared_pid": 9_999_999, "side_effects": ["copied_profile_data": false]]
            case "list_windows": return ["windows": [["pid": 9_999_999, "window_id": 456]]]
            case "end_session": return ["active": false]
            case "browser_pointer": scrolls += 1; return ["effect": "confirmed"]
            case "get_browser_state" where arguments["pid"] != nil:
                return ["binding_quality": "exact", "target_id": "owned-target", "tabs": [["tab_id": "owned-tab"]]]
            case "get_browser_state":
                return ["page": ["title": "Fixture", "url": "https://fixture.test/\(scrolls)"],
                        "outline": viewports[min(scrolls, viewports.count - 1)],
                        "refs": [["ref": "p1:0", "role": "button", "name": "Send", "actions": ["click"]]]]
            default: return ["effect": "confirmed"]
            }
        }
    }

    private func defaults() -> UserDefaults {
        let name = "heymate-browser-profiles-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func open(_ pool: IsolatedBrowserWorkers, mate: UUID, scope: String = "turn") async -> (text: String, isError: Bool) {
        await pool.perform(arguments: ["op": "open", "url": "https://fixture.test"], owner: mate.uuidString + "/chat",
                           scope: scope, mateID: mate) { _, _ in true }
    }

    @Test func legacySingleMateMigratesAndEveryMateGetsItsOwnProfile() async throws {
        let preferences = defaults()
        let legacy = UUID(), other = UUID()
        preferences.set(legacy.uuidString, forKey: IsolatedBrowserProfiles.legacyPreferenceKey)
        var drivers: [Driver] = []
        let pool = IsolatedBrowserWorkers(preferences: preferences, factory: {
            let driver = Driver(); drivers.append(driver); return driver
        }, mode: { .fullAccess })
        #expect(pool.isPersistent(legacy))
        #expect(preferences.string(forKey: IsolatedBrowserProfiles.legacyPreferenceKey) == nil)
        #expect(preferences.stringArray(forKey: IsolatedBrowserProfiles.preferenceKey) == [legacy.uuidString])
        #expect(pool.setPersistentBrowser(true, for: other))
        #expect(IsolatedBrowserWorkers(preferences: preferences).persistentMateIDs == [legacy, other])

        #expect(await !open(pool, mate: legacy).isError)
        #expect(await !open(pool, mate: other).isError)
        let names = drivers.compactMap { driver in
            (driver.calls.first { $0.0 == "browser_prepare" }?.1["profile"] as? [String: Any])?["name"] as? String
        }
        // The migrated mate keeps the profile name it always had, so its sign-ins survive.
        #expect(names == ["heymate-mate-" + legacy.uuidString.lowercased(), "heymate-mate-" + other.uuidString.lowercased()])
        #expect(pool.live[legacy]?.url == "https://fixture.test/0")
        #expect(pool.live[legacy]?.isWorking == true)
        pool.finishTurn(owner: legacy.uuidString + "/chat", scope: "turn", cancelled: false, mateID: legacy)
        #expect(pool.live[legacy]?.isWorking == false)
        pool.setPersistentBrowser(false, for: other)
        #expect(!pool.isPersistent(other) && drivers[1].stopped)
        pool.stopAll()
    }

    @Test func openingBeyondTheCapClosesTheLeastRecentlyUsedIdleProfile() async throws {
        let preferences = defaults()
        let a = UUID(), b = UUID(), c = UUID()
        var drivers: [Driver] = []
        let pool = IsolatedBrowserWorkers(preferences: preferences, maximumPersistent: 2, factory: {
            let driver = Driver(); drivers.append(driver); return driver
        }, mode: { .fullAccess })
        for mate in [a, b, c] { pool.setPersistentBrowser(true, for: mate) }
        #expect(await !open(pool, mate: a).isError)
        #expect(await !open(pool, mate: b).isError)
        // Both are mid-turn: no room, nothing closed.
        #expect(await open(pool, mate: c).isError)
        #expect(!drivers[0].stopped && !drivers[1].stopped)
        pool.finishTurn(owner: b.uuidString + "/chat", scope: "turn", cancelled: false, mateID: b)
        pool.finishTurn(owner: a.uuidString + "/chat", scope: "turn", cancelled: false, mateID: a)
        // a was used before b, so a closes even though it finished last.
        #expect(await !open(pool, mate: c).isError)
        #expect(drivers[0].stopped && !drivers[1].stopped)
        #expect(IsolatedBrowserProfiles.profilesToClose(open: [
            .init(mateID: a, lastUsed: 1, busy: false), .init(mateID: b, lastUsed: 2, busy: false)
        ], opening: c, maximum: 1) == [a, b])
        #expect(IsolatedBrowserProfiles.profilesToClose(open: [.init(mateID: a, lastUsed: 1, busy: false)],
                                                        opening: a, maximum: 1) == [])
        pool.stopAll()
    }

    @Test func takeoverOfOneMateLeavesOtherMatesBrowsing() async throws {
        let a = UUID(), b = UUID()
        let pool = IsolatedBrowserWorkers(preferences: defaults(), factory: { Driver() }, mode: { .fullAccess }, show: { _ in true })
        pool.setPersistentBrowser(true, for: a); pool.setPersistentBrowser(true, for: b)
        #expect(await pool.takeOver(for: a) == nil)
        #expect(pool.control(for: a) == .person && pool.control(for: b) == .mate)
        #expect(await pool.takeOver(for: b) != nil)
        #expect(await open(pool, mate: a).isError)
        #expect(await !open(pool, mate: b).isError)
        #expect(await pool.liveImage(for: a) == nil)
        pool.handBack(for: a)
        #expect(pool.control(for: a) == .mate && pool.controlledMateID == nil)
        pool.stopAll()
    }

    @Test func fullPageExtractStitchesViewportsAndCapsWithAMarker() async throws {
        let driver = Driver()
        driver.viewports = ["Top\nMiddle", "Middle\nBottom", "Middle\nBottom"]
        let pool = IsolatedBrowserWorkers(factory: { driver }, mode: { .fullAccess })
        let page = await pool.perform(arguments: ["op": "open", "url": "https://fixture.test"], owner: "m/c", scope: "turn") { _, _ in true }
        let tab = Int(page.text.components(separatedBy: "Isolated tab ").last?.prefix(while: { $0.isNumber }) ?? "") ?? 0
        let whole = await pool.perform(arguments: ["op": "extract", "tab_id": tab, "mode": "page"], owner: "m/c", scope: "turn") { _, _ in true }
        #expect(!whole.isError)
        #expect(whole.text.contains("Untrusted page content"))
        #expect(whole.text.contains("Top\nMiddle\nBottom"))
        #expect(whole.text.contains("over 3 viewports"))
        #expect(!whole.text.contains(BrowserPageText.truncationMarker))

        driver.scrolls = 0
        driver.viewports = (0..<40).map { step in (0..<30).map { "step \(step) line \($0) " + String(repeating: "x", count: 80) }.joined(separator: "\n") }
        let capped = await pool.perform(arguments: ["op": "extract", "tab_id": tab, "mode": "page"], owner: "m/c", scope: "turn") { _, _ in true }
        #expect(capped.text.contains(BrowserPageText.truncationMarker))
        #expect(driver.scrolls < BrowserPageText.maximumSteps)
        let viewport = await pool.perform(arguments: ["op": "extract", "tab_id": tab], owner: "m/c", scope: "turn") { _, _ in true }
        #expect(!viewport.text.contains("viewports"))
        pool.finishTurn(owner: "m/c", scope: "turn", cancelled: true)

        var lines = ["a", "b", "c"]
        #expect(BrowserPageText.merge(&lines, ["b", "c", "d"]) == 1 && lines == ["a", "b", "c", "d"])
        #expect(BrowserPageText.merge(&lines, ["c", "d"]) == 0)
        #expect(BrowserPageText.capped(["12345"], limit: 3).text.hasPrefix("123\n\n["))
    }
}
