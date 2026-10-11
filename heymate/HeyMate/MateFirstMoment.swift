import Foundation

/// Application-owned creation state, kept separate from assistant messages.
/// Copy is local and truthful even when no provider is available.
nonisolated struct MateFirstMoment: Codable, Equatable {
    var name: String
    var role: String
    var starter: MateStarterSuggestion?

    var confirmation: String { "\(name) was created · \(role)" }

    static func chat(for mate: Mate) -> ChatSession {
        var chat = ChatSession.empty()
        chat.mateID = mate.id
        chat.firstMoment = MateFirstMoment(name: mate.name, role: mate.job, starter: starter(for: mate))
        chat.messages = [ChatMessage(id: UUID(), role: .assistant, text: greeting(for: mate), createdAt: chat.createdAt)]
        return chat
    }

    static func greeting(for mate: Mate) -> String {
        switch specialty(for: mate) {
        case .teacher:
            let style = (mate.job + " " + mate.soul).lowercased()
            if style.range(of: #"\b(patient|one step|step by step|step-by-step)\b"#, options: .regularExpression) != nil {
                return "I'm \(mate.name). Tell me what you're making or learning, and we'll work through one step at a time."
            }
            return "I'm \(mate.name). Tell me what you want to learn and what you've tried so far."
        case .codeReviewer:
            return "I'm \(mate.name). Share a small change and what you want checked. I'll focus on the most useful feedback."
        case .custom:
            return "I'm \(mate.name). Tell me what you'd like help with first, and we'll choose a useful starting point."
        }
    }

    static func starter(for mate: Mate) -> MateStarterSuggestion {
        switch specialty(for: mate) {
        case .teacher:
            return MateStarterSuggestion(label: "Choose something to learn", prompt: "Help me learn one task in the app I'm using. Ask what I want to achieve before starting.")
        case .codeReviewer:
            return MateStarterSuggestion(label: "Review a small change", prompt: "Help me review a small change. Ask which project or snippet to use before starting.")
        case .custom:
            return MateStarterSuggestion(label: "Describe a first task", prompt: "Help me choose a first task for your role: \(mate.job). Ask what outcome I want before starting.")
        }
    }

    private enum Specialty { case teacher, codeReviewer, custom }

    private static func specialty(for mate: Mate) -> Specialty {
        // Only the saved role chooses a specialty. A personality constraint
        // mentioning "coding jobs" cannot invent one.
        let role = mate.job.lowercased()
        if role.range(of: #"\b(tutor|teacher|teaches|teaching|instructor)\b"#, options: .regularExpression) != nil {
            return .teacher
        }
        if role.range(of: #"\b(code|coding|software|pull request)\b"#, options: .regularExpression) != nil,
           role.range(of: #"\b(review|reviewer|reviews|reviewing)\b"#, options: .regularExpression) != nil {
            return .codeReviewer
        }
        return .custom
    }
}

nonisolated struct MateStarterSuggestion: Codable, Equatable {
    var label: String
    var prompt: String
}

extension CompanionManager {
    /// Draft only: this path never sends, captures the screen, or starts work.
    func useMateStarterInComposer() -> String? {
        guard currentChat.messages.allSatisfy({ $0.role == .assistant }),
              (currentChat.draftText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let starter = currentChat.firstMoment?.starter else { return nil }
        currentChat.firstMoment?.starter = nil
        updateCurrentDraft(starter.prompt)
        return starter.prompt
    }

    func dismissMateStarter() {
        guard currentChat.firstMoment?.starter != nil else { return }
        currentChat.firstMoment?.starter = nil
        persistCurrentChatIfNeeded()
    }
}
