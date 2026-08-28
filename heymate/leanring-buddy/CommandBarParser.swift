//
//  CommandBarParser.swift
//  leanring-buddy
//
//  The "/" and "@" halves of the command bar, as one pure parser.
//
//  Both are deliberately thin: every command routes to something the app can
//  already do (open a desktop section, reveal the skills folder, clear memory)
//  and every context token names a store that already exists (the screen
//  capture path, the current lasso selection, loaded skills, durable memory,
//  clipboard history). Nothing here invents a new capability — it just gives
//  the typed input a way to reach them without a mouse.
//

import Foundation

/// A `/command` the user can type into any HeyMate composer.
nonisolated enum SlashCommand: String, CaseIterable, Identifiable {
    case help
    case chat
    case agents
    case connectors
    case skills
    case memory
    case privacy
    case settings
    case notch
    case clearMemory = "memory-clear"
    case checkForUpdates = "updates"

    var id: String { rawValue }

    /// What the user types after the slash. The first match wins, so aliases
    /// can be added here without touching the parser.
    var aliases: [String] {
        switch self {
        case .help: return ["help", "?"]
        case .chat: return ["chat"]
        case .agents: return ["agents", "agent"]
        case .connectors: return ["connectors", "integrations"]
        case .skills: return ["skills"]
        case .memory: return ["memory"]
        case .privacy: return ["privacy"]
        case .settings: return ["settings", "preferences"]
        case .notch: return ["notch"]
        case .clearMemory: return ["memory-clear", "forget"]
        case .checkForUpdates: return ["updates", "update"]
        }
    }

    var summary: String {
        switch self {
        case .help: return "List these commands"
        case .chat: return "Open the chat window"
        case .agents: return "Open agent runs"
        case .connectors: return "Open connectors"
        case .skills: return "Open skills"
        case .memory: return "Open what HeyMate remembers"
        case .privacy: return "Open privacy and excluded apps"
        case .settings: return "Open settings"
        case .notch: return "Open notch micro-app settings"
        case .clearMemory: return "Delete everything HeyMate remembers"
        case .checkForUpdates: return "Check for a new version"
        }
    }

    /// The desktop section this command opens, when it opens one.
    var desktopSection: DesktopSection? {
        switch self {
        case .chat: return .chat
        case .agents: return .agents
        case .connectors: return .connectors
        case .skills: return .skills
        case .memory: return .memory
        case .privacy: return .privacy
        case .settings: return .settings
        case .notch: return .notch
        case .help, .clearMemory, .checkForUpdates: return nil
        }
    }

    /// Clearing memory is not undoable, so the caller is expected to confirm
    /// before running it rather than acting on the keystroke.
    var requiresConfirmation: Bool { self == .clearMemory }
}

/// An `@token` naming a context source to attach to the message.
///
/// There is deliberately no `@screen` or `@region`: every Talk and typed
/// message already carries a screenshot, and a lasso selection is already
/// promoted to priority context when one exists. A token that claimed to add
/// them would be a label on something that always happens.
nonisolated enum ContextToken: String, CaseIterable, Identifiable {
    case skills
    case memory
    case clipboard

    var id: String { rawValue }

    var summary: String {
        switch self {
        case .skills: return "Attach your loaded skill files"
        case .memory: return "Attach what HeyMate remembers"
        case .clipboard: return "Attach the current clipboard text"
        }
    }
}

nonisolated enum CommandBarInput: Equatable {
    /// A recognized `/command`, with whatever followed it.
    case slashCommand(SlashCommand, argument: String)
    /// A leading slash that matched nothing. Kept distinct from ordinary text
    /// so the UI can say "no such command" instead of sending "/tskills" to
    /// the model as if it were a question.
    case unknownSlashCommand(String)
    /// Ordinary text, plus any context tokens found in it. `text` has the
    /// tokens removed so the model is not asked to interpret "@screen".
    case message(text: String, contextTokens: [ContextToken])

    static func == (lhs: CommandBarInput, rhs: CommandBarInput) -> Bool {
        switch (lhs, rhs) {
        case let (.slashCommand(leftCommand, leftArgument), .slashCommand(rightCommand, rightArgument)):
            return leftCommand == rightCommand && leftArgument == rightArgument
        case let (.unknownSlashCommand(leftName), .unknownSlashCommand(rightName)):
            return leftName == rightName
        case let (.message(leftText, leftTokens), .message(rightText, rightTokens)):
            return leftText == rightText && leftTokens == rightTokens
        default:
            return false
        }
    }
}

nonisolated enum CommandBarParser {

    /// Splits typed input into a command, an unknown command, or a message
    /// plus its context tokens. Only a *leading* slash is a command — "and/or"
    /// mid-sentence stays ordinary text.
    static func parse(_ rawInput: String) -> CommandBarInput {
        let trimmedInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedInput.hasPrefix("/") {
            return parseSlashCommand(trimmedInput)
        }

        return parseMessage(trimmedInput)
    }

    private static func parseSlashCommand(_ trimmedInput: String) -> CommandBarInput {
        let withoutSlash = String(trimmedInput.dropFirst())
        let separatorIndex = withoutSlash.firstIndex(where: { $0.isWhitespace })

        let commandName: String
        let argument: String
        if let separatorIndex {
            commandName = String(withoutSlash[withoutSlash.startIndex..<separatorIndex])
            argument = String(withoutSlash[separatorIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            commandName = withoutSlash
            argument = ""
        }

        let loweredCommandName = commandName.lowercased()
        guard !loweredCommandName.isEmpty else { return .unknownSlashCommand("") }

        // "/memory clear" is spelled two ways on purpose: as its own command
        // and as an argument to /memory, because both are what people type.
        if loweredCommandName == "memory", argument.lowercased() == "clear" {
            return .slashCommand(.clearMemory, argument: "")
        }

        for command in SlashCommand.allCases where command.aliases.contains(loweredCommandName) {
            return .slashCommand(command, argument: argument)
        }

        return .unknownSlashCommand(commandName)
    }

    private static func parseMessage(_ trimmedInput: String) -> CommandBarInput {
        var foundTokens: [ContextToken] = []
        var remainingWords: [String] = []

        for word in trimmedInput.split(separator: " ", omittingEmptySubsequences: true) {
            guard word.hasPrefix("@") else {
                remainingWords.append(String(word))
                continue
            }

            // Trailing punctuation is common when a token ends a sentence.
            let tokenName = String(word.dropFirst())
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
                .lowercased()

            guard let token = ContextToken(rawValue: tokenName) else {
                // An unrecognized @word is probably a name or a handle, so it
                // stays in the message rather than being swallowed.
                remainingWords.append(String(word))
                continue
            }

            if !foundTokens.contains(token) {
                foundTokens.append(token)
            }
        }

        let messageText = remainingWords
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return .message(text: messageText, contextTokens: foundTokens)
    }

    /// Rendered by `/help` and by the composer's hint row.
    static func helpText() -> String {
        let commandLines = SlashCommand.allCases.map { command in
            "/\(command.aliases[0]) — \(command.summary)"
        }
        let tokenLines = ContextToken.allCases.map { token in
            "@\(token.rawValue) — \(token.summary)"
        }
        return (commandLines + [""] + tokenLines).joined(separator: "\n")
    }
}
