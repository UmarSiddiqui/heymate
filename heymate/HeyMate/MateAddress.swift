//
//  MateAddress.swift
//  HeyMate
//
//  "Tell Inbox Scout I like this" routes the rest of the sentence to that
//  mate. Parsing never calls a model.
//

import Foundation

nonisolated struct MateAddress: Equatable {
    let mateName: String
    let message: String
}

nonisolated enum MateAddressParser {
    static func parse(_ text: String) -> MateAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pattern = #"(?i)^(?:please\s+)?(?:tell|ask|message)\s+(.+?)\s+(?:that|to)\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = expression.firstMatch(in: trimmed, range: range),
              match.numberOfRanges == 3,
              let nameRange = Range(match.range(at: 1), in: trimmed),
              let messageRange = Range(match.range(at: 2), in: trimmed) else { return nil }
        let name = String(trimmed[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let message = String(trimmed[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !message.isEmpty else { return nil }
        return MateAddress(mateName: name, message: message)
    }

    /// Who a message is for and what it says, when it names an agent.
    /// "ask Clerk to merge these" works as before. So do the shorter forms
    /// people type: "@Clerk merge these", "Clerk, merge these",
    /// "hey Clerk merge these", "have Clerk merge these" and
    /// "get Clerk to merge these". The short forms need the agent's exact
    /// name, so an ordinary sentence with a comma goes nowhere.
    static func resolve(_ text: String, mates: [Mate]) -> (mate: Mate, message: String)? {
        if let address = parse(text), let mate = match(address.mateName, mates: mates) {
            return (mate, address.message)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = mates
            .filter { !$0.archived && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.name.count > $1.name.count }
        for mate in candidates {
            let name = mate.name.trimmingCharacters(in: .whitespaces)
            let openings = [
                "@\(name) ", "@\(name), ", "@\(name): ", "\(name), ", "\(name): ",
                "hey \(name), ", "hey \(name) ", "have \(name) ", "get \(name) to "
            ]
            for opening in openings {
                guard let range = trimmed.range(
                    of: opening, options: [.anchored, .caseInsensitive, .diacriticInsensitive]
                ) else { continue }
                let message = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !message.isEmpty { return (mate, message) }
            }
        }
        return nil
    }

    /// Longest mate name contained in the spoken name, so "the Inbox Scout"
    /// still lands on Inbox Scout.
    static func match(_ spokenName: String, mates: [Mate]) -> Mate? {
        let spoken = FileMateStore.normalized(spokenName)
        guard !spoken.isEmpty else { return nil }
        let candidates = mates.filter { !$0.archived }
        return candidates
            .filter { spoken.contains(FileMateStore.normalized($0.name)) }
            .max { FileMateStore.normalized($0.name).count < FileMateStore.normalized($1.name).count }
    }
}
