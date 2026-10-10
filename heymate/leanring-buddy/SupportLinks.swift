//
//  SupportLinks.swift
//  leanring-buddy
//
//  The outbound URLs the support section opens. Kept as one table so a moved
//  community link is a single edit rather than a grep across view files.
//

import AppKit
import Foundation

nonisolated enum SupportLinks {

    struct Destination: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbolName: String
        let url: URL
    }

    static let repositoryURLString = "https://github.com/UmarSiddiqui/heymate"
    static let permissionsPageURLString = "https://getheymate.vercel.app/permissions"
    static let feedbackEmailAddress = "umarsiddiqui3037+heymate@gmail.com"

    /// Issue URLs name the forms in `.github/ISSUE_TEMPLATE/`; rename them together.
    static let destinations: [Destination] = [
        Destination(
            id: "report-a-bug",
            title: "Report a bug",
            subtitle: "Open a GitHub issue with what went wrong.",
            symbolName: "ladybug",
            url: URL(string: "\(repositoryURLString)/issues/new?template=bug.yml")!
        ),
        Destination(
            id: "request-a-feature",
            title: "Request a feature",
            subtitle: "Tell us what HeyMate should be able to do.",
            symbolName: "lightbulb",
            url: URL(string: "\(repositoryURLString)/issues/new?template=feature.yml")!
        ),
        Destination(
            id: "email-feedback",
            title: "Email feedback",
            subtitle: "Write to the developer. Your version and Mac are filled in.",
            symbolName: "envelope",
            url: feedbackEmailURL
        ),
        Destination(
            id: "permissions",
            title: "Why each permission",
            subtitle: "What HeyMate does with every access it asks for.",
            symbolName: "hand.raised",
            url: URL(string: permissionsPageURLString)!
        ),
        Destination(
            id: "issues",
            title: "Browse issues",
            subtitle: "See known problems and requested improvements.",
            symbolName: "list.bullet.rectangle",
            url: URL(string: "\(repositoryURLString)/issues")!
        ),
        Destination(
            id: "source",
            title: "Source code",
            subtitle: "Read the code that runs on your machine.",
            symbolName: "chevron.left.forwardslash.chevron.right",
            url: URL(string: repositoryURLString)!
        ),
        Destination(
            id: "licenses",
            title: "Licenses",
            subtitle: "HeyMate's license and notices for code it builds on.",
            symbolName: "doc.text",
            url: URL(string: "\(repositoryURLString)/blob/main/heymate/THIRD_PARTY_NOTICES.md")!
        )
    ]

    /// A mailto draft carrying the details every report needs, so the first
    /// reply doesn't have to ask which build and which Mac.
    static var feedbackEmailURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: "HeyMate feedback"),
            URLQueryItem(name: "body", value: "\n\n---\n\(diagnosticsSummary)")
        ]
        return components.url ?? URL(string: "mailto:\(feedbackEmailAddress)")!
    }

    static var diagnosticsSummary: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "Apple silicon"
        #else
        let architecture = "Intel"
        #endif
        return """
        HeyMate \(version) (\(build))
        \(ProcessInfo.processInfo.operatingSystemVersionString), \(architecture)
        """
    }

    @MainActor
    static func open(_ destination: Destination) {
        NSWorkspace.shared.open(destination.url)
    }
}
