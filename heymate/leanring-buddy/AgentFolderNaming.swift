//
//  AgentFolderNaming.swift
//  leanring-buddy
//
//  Sandbox path rules for agent jobs. Voice/typed launches always mint a
//  new folder under ~/Projects/heymate so a run cannot silently write into
//  an existing repo. Short IDs keep two similar prompts from colliding.
//

import Foundation

nonisolated enum AgentFolderNaming {

    static let parentDirectoryName = "heymate"
    static let maximumSlugLength = 40
    static let fallbackSlug = "agent"

    /// `~/Projects/heymate`. Created by the launcher on first use, not here.
    static func sandboxParentURL(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(parentDirectoryName, isDirectory: true)
    }

    /// Lowercase hyphenated slug, max 40 chars. Unusable input → `agent`.
    static func slug(from prompt: String) -> String {
        let lowered = prompt.lowercased()
        var slugCharacters: [Character] = []
        var lastWasHyphen = false

        for character in lowered {
            if character.isLetter || character.isNumber {
                slugCharacters.append(character)
                lastWasHyphen = false
            } else if !lastWasHyphen && !slugCharacters.isEmpty {
                slugCharacters.append("-")
                lastWasHyphen = true
            }
        }

        while slugCharacters.last == "-" {
            slugCharacters.removeLast()
        }

        var slug = String(slugCharacters)
        if slug.count > maximumSlugLength {
            slug = String(slug.prefix(maximumSlugLength))
            while slug.last == "-" {
                slug.removeLast()
            }
        }

        return slug.isEmpty ? fallbackSlug : slug
    }

    /// First 4 hex chars of a UUID, lowercase, no hyphens.
    static func shortID(from uuid: UUID) -> String {
        String(uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
    }

    static func folderName(prompt: String, uuid: UUID) -> String {
        "\(slug(from: prompt))-\(shortID(from: uuid))"
    }

    static func sandboxFolderURL(
        prompt: String,
        uuid: UUID,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        sandboxParentURL(homeDirectoryURL: homeDirectoryURL)
            .appendingPathComponent(folderName(prompt: prompt, uuid: uuid), isDirectory: true)
    }
}
