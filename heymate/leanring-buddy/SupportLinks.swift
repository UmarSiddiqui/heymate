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

    static let repositoryURLString = "https://github.com/farzaa/clicky"

    /// Bug reports and feature requests both open GitHub issues with the
    /// matching template preselected, so nothing depends on a mail client
    /// being configured.
    static let destinations: [Destination] = [
        Destination(
            id: "report-a-bug",
            title: "Report a bug",
            subtitle: "Open a GitHub issue with what went wrong.",
            symbolName: "ladybug",
            url: URL(string: "\(repositoryURLString)/issues/new?labels=bug&template=bug_report.md")!
        ),
        Destination(
            id: "request-a-feature",
            title: "Request a feature",
            subtitle: "Tell us what HeyMate should be able to do.",
            symbolName: "lightbulb",
            url: URL(string: "\(repositoryURLString)/issues/new?labels=enhancement&template=feature_request.md")!
        ),
        Destination(
            id: "discussions",
            title: "Community",
            subtitle: "Ask questions and see what other people are building.",
            symbolName: "bubble.left.and.bubble.right",
            url: URL(string: "\(repositoryURLString)/discussions")!
        ),
        Destination(
            id: "source",
            title: "Source code",
            subtitle: "Read the code that runs on your machine.",
            symbolName: "chevron.left.forwardslash.chevron.right",
            url: URL(string: repositoryURLString)!
        )
    ]

    @MainActor
    static func open(_ destination: Destination) {
        NSWorkspace.shared.open(destination.url)
    }
}
