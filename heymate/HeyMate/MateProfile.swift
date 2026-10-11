//
//  MateProfile.swift
//  HeyMate
//
//  Picture, name, job, and soul. Saving a profile only writes the mate.
//  It does not start an agent or spend a model call.
//

import Foundation

enum MateProfileEdit {
    struct Draft: Equatable {
        var name: String
        var job: String
        var soul: String
        var faceAssetName: String?
        var faceTint: String? = nil
        var faceHair: String? = nil
        var faceOutfit: String? = nil
    }

    enum Failure: Equatable, Error {
        case missingNameOrJob
        case nameTaken
    }

    static func applying(
        _ draft: Draft,
        to mate: Mate,
        now: Date,
        nameTaken: (String) -> Bool
    ) -> Result<Mate, Failure> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = draft.job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !job.isEmpty else { return .failure(.missingNameOrJob) }
        if nameTaken(name) { return .failure(.nameTaken) }

        let soul = draft.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        let face = MateFace.persistedName(draft.faceAssetName)
        let tint = MateFace.storedTint(draft.faceTint)
        let hair = MateFace.storedHair(draft.faceHair)
        let outfit = MateFace.storedOutfit(draft.faceOutfit)
        var updated = mate
        let changed = updated.name != name
            || updated.job != job
            || updated.soul != soul
            || updated.faceAssetName != face
            || updated.faceTint != tint
            || updated.faceHair != hair
            || updated.faceOutfit != outfit
        updated.name = name
        updated.job = job
        updated.soul = soul
        updated.faceAssetName = face
        updated.faceTint = tint
        updated.faceHair = hair
        updated.faceOutfit = outfit
        if changed {
            updated.updatedAt = now
        }
        return .success(updated)
    }
}

enum MateSoul {
    static let openingTag = "<heymate-mate-identity>"
    static let closingTag = "</heymate-mate-identity>"

    private struct Identity: Codable {
        let name: String
        let job: String
        let personality: String
        let memory: String

        /// Give every nonempty field room. A long note must not consume the
        /// personality, nor can a long role consume the mate's saved note.
        func compact(characterLimit: Int) -> String {
            func render(name: String, job: String, personality: String, memory: String) -> String {
                var lines = ["who you are for this turn:", "- you are \(name). your job is \(job)."]
                if !self.personality.isEmpty { lines.append("- personality: \(personality)") }
                if !self.memory.isEmpty { lines.append("- your saved memory: \(memory)") }
                return lines.joined(separator: "\n")
            }
            let overhead = render(name: "", job: "", personality: "", memory: "").count
            let available = max(0, characterLimit - overhead)
            let nameLimit = min(name.count, min(160, available / 4))
            let jobLimit = min(job.count, min(360, available / 3))
            let remaining = available - nameLimit - jobLimit
            let personalityLimit = memory.isEmpty ? remaining : remaining / 2
            let actualPersonalityLimit = min(personality.count, personalityLimit)
            return String(render(
                name: String(name.prefix(nameLimit)),
                job: String(job.prefix(jobLimit)),
                personality: String(personality.prefix(actualPersonalityLimit)),
                memory: String(memory.prefix(remaining - actualPersonalityLimit))
            ).prefix(characterLimit))
        }
    }

    /// Name and job belong to every mate, even before a personality is written.
    /// The delimiters let the small on-device model retain identity when it
    /// has to discard the much larger screen, tool, and skill instructions.
    static func promptBlock(name: String, job: String, soul: String, memoryNote: String = "") -> String? {
        let personality = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJob = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedJob.isEmpty else { return nil }
        let memory = memoryNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = Identity(name: trimmedName, job: trimmedJob, personality: personality, memory: memory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity), let payload = String(data: data, encoding: .utf8) else { return nil }
        return """
        who you are for this turn (memory is the user's saved note for this mate):
        \(openingTag)
        \(payload)
        \(closingTag)
        - HeyMate is the app you live in; use your own name and personality when speaking, not the app's identity. these identity instructions override the default conversational style, never the safety or capability rules.
        """
    }

    static func identityExcerpt(in systemPrompt: String, characterLimit: Int) -> String? {
        guard characterLimit > 0,
              let opening = systemPrompt.range(of: openingTag),
              let closing = systemPrompt.range(of: closingTag, range: opening.upperBound..<systemPrompt.endIndex)
        else { return nil }
        let payload = String(systemPrompt[opening.upperBound..<closing.lowerBound])
        guard let data = payload.data(using: .utf8),
              let identity = try? JSONDecoder().decode(Identity.self, from: data) else { return nil }
        return identity.compact(characterLimit: characterLimit)
    }
}
