import Foundation
import Testing
@testable import HeyMate

@Suite("Contextual connector suggestion")
struct ContextualConnectorSuggestionTests {
    @Test("YouTube host and subdomains map to one toolkit")
    func youtubeMapping() {
        #expect(ContextualConnectorSuggestionMonitor.suggestion(for: URL(string: "https://youtube.com/watch?v=1")!)?.toolkitSlug == "youtube")
        #expect(ContextualConnectorSuggestionMonitor.suggestion(for: URL(string: "https://m.youtube.com/shorts/1")!)?.toolkitSlug == "youtube")
        #expect(ContextualConnectorSuggestionMonitor.suggestion(for: URL(string: "https://example.com")!) == nil)
    }

    @Test("Relevant app pages map to their Composio toolkit")
    func commonAppMappings() {
        let expectations: [(String, String)] = [
            ("https://mail.google.com/mail/u/0/", "gmail"),
            ("https://calendar.google.com/calendar/u/0/r", "googlecalendar"),
            ("https://drive.google.com/drive/my-drive", "googledrive"),
            ("https://github.com/anthropics/skills", "github"),
            ("https://app.slack.com/client/workspace/channel", "slack"),
            ("https://www.notion.so/workspace", "notion"),
            ("https://www.figma.com/design/file", "figma"),
            ("https://trello.com/b/board", "trello"),
            ("https://app.asana.com/0/project/list", "asana")
        ]

        for (urlString, expectedToolkitSlug) in expectations {
            #expect(
                ContextualConnectorSuggestionMonitor.suggestion(for: URL(string: urlString)!)?.toolkitSlug
                    == expectedToolkitSlug
            )
        }
        #expect(ContextualConnectorSuggestionMonitor.suggestion(for: URL(string: "https://evilgithub.com")!) == nil)
    }

    @MainActor
    @Test("No suppresses while Not now expires")
    func choicesPersist() {
        let suiteName = "ContextualConnectorSuggestionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var currentDate = Date(timeIntervalSince1970: 1_000)
        let provider = StubBrowserPageURLProvider(url: URL(string: "https://youtube.com/watch?v=1"))
        let monitor = ContextualConnectorSuggestionMonitor(
            browserPageURLProvider: provider,
            userDefaults: defaults,
            now: { currentDate }
        )

        monitor.refresh()
        let initialSuggestion = monitor.suggestion!
        monitor.snooze(initialSuggestion)
        monitor.refresh()
        #expect(monitor.suggestion == nil)

        currentDate.addTimeInterval(ContextualConnectorSuggestionMonitor.defaultSnoozeDuration + 1)
        monitor.refresh()
        #expect(monitor.suggestion != nil)

        monitor.declinePermanently(monitor.suggestion!)
        monitor.refresh()
        #expect(monitor.suggestion == nil)
    }
}

private struct StubBrowserPageURLProvider: BrowserPageURLProviding {
    let url: URL?
    func currentFrontmostBrowserURL() -> URL? { url }
}
