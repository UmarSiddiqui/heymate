//
//  VoiceRouter.swift
//  HeyMate
//
//  The free first pass of voice routing. It settles what plain word
//  matching can settle (local shortcuts, an explicit "agent,", questions
//  about the screen) and hands anything genuinely ambiguous to
//  `VoiceIntentClassifier`, which costs a round trip.
//
//  Keep this small. Every rule added here has to stay true forever, while
//  the classifier generalises; a missed case is almost always a fix to the
//  classifier's prompt, not a new rule here.
//
//  Every predicate takes text already passed through
//  `SpokenText.normalizedSpokenCommandText`: lowercase, single-spaced,
//  without punctuation or apostrophes ("whats", "dont").
//

import Foundation

nonisolated enum VoiceRouteDecision: Equatable {
    case local(LocalVoiceAction)
    case agent
    case hybrid
    case confirmDestructive
    case talk
    /// Nothing free could decide this one. `VoiceIntentClassifier` gets a
    /// turn, and if it fails, `fallbackDecision` decides.
    case needsClassification
}

nonisolated enum VoiceRouter {
    /// Decides for free whatever can be decided for free, in this order:
    /// 1. a local shortcut (volume, open an app) never pays a round trip;
    /// 2. a sensitive or sweeping destructive request is confirmed first,
    ///    unless the user explicitly addressed an agent;
    /// 3. an explicit "agent," means the user already chose;
    /// 4. a question plus background work is both at once (checked before
    ///    the screen question, or the background half would be lost);
    /// 5. a question about the screen, or pointing at something visible
    ///    without naming anything durable, is Talk.
    static func decide(_ transcript: String) -> VoiceRouteDecision {
        if let local = LocalVoiceAction.parse(transcript) {
            return .local(local)
        }
        let text = SpokenText.normalizedSpokenCommandText(SpokenText.normalizedCommandCandidate(from: transcript))
        let addressedAgent = AgentInvocation.explicitPrefixTask(transcript) != nil

        if !addressedAgent && isSensitiveOrDestructiveAgentTaskRequest(text) { return .confirmDestructive }
        if addressedAgent { return .agent }
        if containsHybridForegroundCue(text) && containsHybridBackgroundCue(text) { return .hybrid }
        if isScreenQuestion(text) || isPerceptionQuestion(text) { return .talk }
        if containsReferentialWorkTarget(text) && !containsDurableWorkTarget(text) { return .talk }
        return .needsClassification
    }

    /// Used when the classifier can't be reached: the older prefix-and-
    /// coding-noun rule, so an outage routes as well as before, not worse.
    static func fallbackDecision(_ transcript: String) -> VoiceRouteDecision {
        AgentInvocation.isAgentRequest(transcript) ? .agent : .talk
    }

    /// A question opener plus a reference to something visible: "what does
    /// this error mean", but not "clean up my Downloads folder".
    static func isScreenQuestion(_ text: String) -> Bool {
        Patterns.questionOpener.matches(text) && Patterns.screenReference.matches(text)
    }

    /// "What am I looking at" points at nothing, yet only the screen answers it.
    static func isPerceptionQuestion(_ text: String) -> Bool {
        Patterns.perception.matches(text)
    }

    static func looksLikeAgentWork(_ text: String) -> Bool {
        containsAgentWorkAction(text) && containsDurableWorkTarget(text)
    }

    static func containsAgentWorkAction(_ text: String) -> Bool {
        Patterns.workAction.matches(text)
    }

    static func containsDurableWorkTarget(_ text: String) -> Bool {
        Patterns.durableTarget.matches(text)
    }

    /// Anything touching credentials, permissions or production, or a
    /// destructive verb aimed broadly ("all", "everything") or at files,
    /// repositories, history and the like.
    static func isSensitiveOrDestructiveAgentTaskRequest(_ text: String) -> Bool {
        if Patterns.sensitiveTarget.matches(text) { return true }
        guard Patterns.destructiveVerb.matches(text) else { return false }
        return Patterns.broadScope.matches(text) || Patterns.destructibleTarget.matches(text)
    }

    static func containsHybridForegroundCue(_ text: String) -> Bool {
        Patterns.foregroundCue.matches(text)
    }

    static func containsHybridBackgroundCue(_ text: String) -> Bool {
        Patterns.backgroundCue.matches(text)
    }

    static func containsReferentialWorkTarget(_ text: String) -> Bool {
        Patterns.referential.matches(text)
    }

    // MARK: - Vocabulary

    private nonisolated enum Patterns {
        static let questionOpener = TextPattern.anyOf([
            "what", "why", "how", "who", "when", "where", "which",
            "explain", "describe", "tell me", "whats", "whos",
        ], atStart: true)

        static let screenReference = TextPattern.anyOf([
            "this", "that", "it", "here", "screen", "display", "visible", "selected",
            "highlighted", "window", "page", "says", "saying", "shown", "showing",
        ])

        static let perception = TextPattern.anyOf(
            ["looking at", "you see", "i see", "seeing", "in front of me"]
                + ["screen", "display", "monitor"].map { "on my \($0)" }
        )

        static let workAction = TextPattern.anyOf([
            "check", "look at", "take a look", "inspect", "review", "audit", "fix", "modify",
            "change", "update", "edit", "build", "create", "make", "write", "draft", "research",
            "search", "find", "summarise", "summarize", "organize", "clean up", "cleanup", "test",
            "run", "install", "compare", "read", "move", "rename", "delete", "prune", "optimise",
            "optimize", "wire", "implement", "add", "remove", "route", "delegate", "ensure",
            "verify", "validate", "confirm", "diagnose", "investigate", "repair", "polish",
            "improve", "finish", "sort out", "deal with", "take care of", "make sure",
            "look into", "figure out",
        ])

        static let durableTarget = TextPattern.anyOf([
            "heymate", "github", "repo", "repository", "codebase", "project", "app", "settings",
            "preference", "preferences", "log", "logs", "memory", "skill", "skills", "desktop",
            "download", "downloads", "document", "documents", "folder", "folders", "file", "files",
            "code", "diff", "git", "branch", "pull request", "pr", "issue", "issues", "bug", "test",
            "tests", "build", "swift", "xcode", "email", "gmail", "calendar", "spreadsheet", "sheet",
            "doc", "slides", "voice", "computer use", "tool", "tools", "tooling", "model", "models",
        ])

        static let destructiveVerb = TextPattern.anyOf([
            "delete", "remove", "erase", "wipe", "destroy", "drop", "revoke", "reset", "nuke",
            "clear", "purge", "uninstall", "terminate", "kill",
        ])

        static let broadScope = TextPattern.anyOf(["all", "everything", "entire", "whole"])

        static let destructibleTarget = TextPattern.anyOf([
            "file", "files", "folder", "folders", "directory", "directories", "repo", "repository",
            "branch", "branches", "commit", "commits", "tag", "tags", "history", "database",
            "databases", "keychain", "account", "accounts",
        ])

        static let sensitiveTarget = TextPattern.anyOf([
            "account", "accounts", "credential", "credentials", "password", "passwords", "token",
            "tokens", "api key", "apikey", "secret", "secrets", "permission", "permissions", "auth",
            "ssh", "private key", "keychain", "database", "databases", "prod", "production",
            "system settings",
        ])

        static let foregroundCue = TextPattern.anyOf([
            "what", "why", "how", "who", "when", "where", "explain", "tell me", "describe",
            "summarise", "summarize", "answer", "quick answer", "quick thought", "quick view",
            "what do you think", "do you think",
        ])

        static let backgroundCue = TextPattern.anyOf(
            [
                "background", "agent", "agents", "agent mode", "do the work", "work on it",
                "take care of it", "combination of the two",
            ]
            + ["fix", "implement", "patch", "research", "find", "check", "review", "update",
               "change", "build", "create"].map { "also \($0)" }
            + ["while you", "while youre"].flatMap { ["\($0) at it", "\($0) doing that"] }
        )

        static let referential = TextPattern.anyOf(
            ["this", "that", "it", "here", "the thing from before"]
            + ["file", "screen", "window", "page", "repo", "repository", "project", "app"].map { "current \($0)" }
            + ["file", "code", "screen", "window", "page"].map { "visible \($0)" }
            + ["text", "file", "code", "region"].map { "selected \($0)" }
            + ["current", "visible", "selected"].flatMap { adjective in
                ["thing", "part", "file", "code", "screen", "window", "page"].map { "the \(adjective) \($0)" }
            }
            + ["talked", "discussed"].flatMap { ["what we \($0) about", "what we just \($0) about"] }
        )
    }
}
