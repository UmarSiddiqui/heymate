//
//  MateProfile.swift
//  leanring-buddy
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
        var updated = mate
        let changed = updated.name != name
            || updated.job != job
            || updated.soul != soul
            || updated.faceAssetName != face
        updated.name = name
        updated.job = job
        updated.soul = soul
        updated.faceAssetName = face
        if changed {
            updated.updatedAt = now
        }
        return .success(updated)
    }
}

enum MateSoul {
    static func promptBlock(name: String, job: String, soul: String) -> String? {
        let personality = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !personality.isEmpty else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJob = job.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        who you are for this turn:
        - you are \(trimmedName). your job is \(trimmedJob).
        - personality: \(personality)
        - stay in this character. keep the safety rules that follow.
        """
    }
}
