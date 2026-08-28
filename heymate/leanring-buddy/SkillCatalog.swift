//
//  SkillCatalog.swift
//  leanring-buddy
//
//  Multi-source skill discovery. `SkillFiles.swift` knows how to parse one
//  Markdown skill and how to load a single flat folder of them. This file
//  sits above that: it knows WHERE skills come from (the app's own folder,
//  the skills a user already keeps for Claude Code, and — later — a remote
//  registry), how much each source is trusted, and which of the discovered
//  skills the user has actually switched on.
//
//  Two on-disk layouts are supported by the scanner:
//    1. Flat        — `<directory>/<anything>.md`
//    2. Claude Code — `<directory>/<skill-name>/SKILL.md`
//  Both parse through the same SkillMarkdownParser, which accepts either
//  `trigger:` (HeyMate's key) or `description:` (Claude Code's key).
//

import Combine
import Foundation

// MARK: - Where a skill came from

/// The provenance of a discovered skill. A skill's instructions are injected
/// into the system prompt of an agent that can run tools, so the user must be
/// able to see where the text originated before switching it on.
nonisolated enum SkillOrigin: Equatable, Hashable, Codable {

    /// Shipped inside the app and seeded into the user's own skills folder on
    /// first launch (`DefaultSkillCatalog`).
    case bundledDefault

    /// A Markdown file the user placed in HeyMate's own skills folder
    /// (Application Support/heymate/skills).
    case userSkillsFolder

    /// A skill in the user's personal Claude Code folder (`~/.claude/skills`).
    /// Written by the user for another agent, so HeyMate reads it but never
    /// writes to it.
    case claudeCodeUserFolder

    /// A skill inside a specific project's `.claude/skills` folder. The
    /// absolute path of the project root is carried so the UI can say which
    /// project a skill belongs to when two projects define the same name.
    case claudeCodeProjectFolder(projectRootPath: String)

    /// Installed from a remote registry. `registryIdentifier` names the
    /// registry it came from so a "verified" badge can be earned per source
    /// rather than granted to every remote skill.
    case remoteRegistry(registryIdentifier: String)

    /// Short, stable, human-meaningless prefix used to build a skill
    /// identifier that stays unique when two sources define the same name.
    var identifierPrefix: String {
        switch self {
        case .bundledDefault:
            return "bundled"
        case .userSkillsFolder:
            return "user"
        case .claudeCodeUserFolder:
            return "claude-user"
        case .claudeCodeProjectFolder(let projectRootPath):
            return "claude-project(\(projectRootPath))"
        case .remoteRegistry(let registryIdentifier):
            return "registry(\(registryIdentifier))"
        }
    }

    /// Short label for the origin badge in the skills UI.
    var displayLabel: String {
        switch self {
        case .bundledDefault:
            return "Built in"
        case .userSkillsFolder:
            return "Your folder"
        case .claudeCodeUserFolder:
            return "Claude Code"
        case .claudeCodeProjectFolder(let projectRootPath):
            let projectFolderName = URL(fileURLWithPath: projectRootPath).lastPathComponent
            return "Project · \(projectFolderName)"
        case .remoteRegistry(let registryIdentifier):
            return registryIdentifier
        }
    }

    var trustTier: SkillTrustTier {
        switch self {
        case .bundledDefault:
            return .shippedWithApp
        case .userSkillsFolder, .claudeCodeUserFolder, .claudeCodeProjectFolder:
            return .authoredLocally
        case .remoteRegistry(let registryIdentifier):
            return registryIdentifier == AnthropicSkillRegistry.registryIdentifier
                ? .remoteVerified
                : .remoteUnverified
        }
    }

    /// Whether HeyMate may manage the file backing a skill. Remote registry
    /// files here are app-installed copies; source repositories and files a
    /// user keeps for another tool remain strictly read-only.
    var isWritableByHeyMate: Bool {
        switch self {
        case .bundledDefault, .userSkillsFolder, .remoteRegistry:
            return true
        case .claudeCodeUserFolder, .claudeCodeProjectFolder:
            return false
        }
    }
}

/// How much a skill's text is trusted, in the order it should be presented.
/// Lower `rawValue` sorts first in the library so the safest skills lead.
nonisolated enum SkillTrustTier: Int, Comparable, Codable, CaseIterable {
    case shippedWithApp = 0
    case authoredLocally = 1
    case remoteVerified = 2
    case remoteUnverified = 3

    var displayLabel: String {
        switch self {
        case .shippedWithApp:
            return "Built in"
        case .authoredLocally:
            return "On this Mac"
        case .remoteVerified:
            return "Verified"
        case .remoteUnverified:
            return "Unverified"
        }
    }

    /// Whether the user should be shown the full skill text and an explicit
    /// warning before this skill is allowed to affect a prompt.
    var requiresReviewBeforeActivation: Bool {
        self == .remoteUnverified
    }

    nonisolated static func < (lhs: SkillTrustTier, rhs: SkillTrustTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - A skill plus its provenance

/// One parsed skill together with where it was found. `SkillFile` alone is
/// deliberately provenance-free (it is what gets injected into a prompt);
/// everything the UI needs to describe or trust a skill lives out here.
nonisolated struct DiscoveredSkill: Equatable, Identifiable {
    let skill: SkillFile
    let origin: SkillOrigin
    /// The file the skill was parsed from — `Open in Finder` targets this and
    /// the UI shows it as the provenance line.
    let fileURL: URL
    let remoteMetadata: RemoteSkillDescriptor?

    init(
        skill: SkillFile,
        origin: SkillOrigin,
        fileURL: URL,
        remoteMetadata: RemoteSkillDescriptor? = nil
    ) {
        self.skill = skill
        self.origin = origin
        self.fileURL = fileURL
        self.remoteMetadata = remoteMetadata
    }

    /// Unique across sources: two folders may both define `code-explainer`.
    var identifier: String { "\(origin.identifierPrefix):\(skill.name)" }
    var id: String { identifier }

    var trustTier: SkillTrustTier { origin.trustTier }
}

// MARK: - Scanning directories

nonisolated enum SkillDirectoryScanner {

    /// The file name Claude Code uses for a skill inside its own folder.
    static let claudeCodeSkillFileName = "SKILL.md"

    /// Scans one directory for skills in either supported layout and tags
    /// every result with `origin`.
    ///
    /// Flat layout wins where both exist for the same name: a `.md` at the top
    /// level is HeyMate's own format and is parsed first, then nested
    /// `<name>/SKILL.md` folders are added for any name not already seen.
    /// A missing or unreadable directory yields an empty array rather than an
    /// error — an absent `~/.claude/skills` is the normal case, not a fault.
    static func scan(
        directoryURL: URL,
        origin: SkillOrigin,
        fileManager: FileManager = .default
    ) -> [DiscoveredSkill] {
        guard let directoryEntryURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
        ) else { return [] }

        let sortedDirectoryEntryURLs = directoryEntryURLs
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var discoveredSkills: [DiscoveredSkill] = []
        var alreadyDiscoveredSkillNames: Set<String> = []

        // Pass 1 — flat `*.md` files (HeyMate's own layout).
        for entryURL in sortedDirectoryEntryURLs where entryURL.pathExtension.lowercased() == "md" {
            guard let discoveredSkill = parseSkill(atFileURL: entryURL, origin: origin) else { continue }
            guard !alreadyDiscoveredSkillNames.contains(discoveredSkill.skill.name) else { continue }
            alreadyDiscoveredSkillNames.insert(discoveredSkill.skill.name)
            discoveredSkills.append(discoveredSkill)
        }

        // Pass 2 — `<skill-name>/SKILL.md` folders (Claude Code's layout).
        for entryURL in sortedDirectoryEntryURLs {
            var entryIsDirectory: ObjCBool = false
            let entryExists = fileManager.fileExists(atPath: entryURL.path, isDirectory: &entryIsDirectory)
            guard entryExists, entryIsDirectory.boolValue else { continue }

            let nestedSkillFileURL = entryURL.appendingPathComponent(claudeCodeSkillFileName)
            guard fileManager.fileExists(atPath: nestedSkillFileURL.path) else { continue }
            guard let discoveredSkill = parseSkill(atFileURL: nestedSkillFileURL, origin: origin) else { continue }
            guard !alreadyDiscoveredSkillNames.contains(discoveredSkill.skill.name) else { continue }
            alreadyDiscoveredSkillNames.insert(discoveredSkill.skill.name)
            discoveredSkills.append(discoveredSkill)
        }

        return discoveredSkills
    }

    /// Scans every local source in trust order and returns one merged list.
    /// Identifiers stay unique because each source stamps its own origin, so
    /// the same skill name appearing in two folders produces two entries the
    /// user can tell apart rather than one silently shadowing the other.
    static func scanAllLocalSources(
        heyMateSkillsDirectoryURL: URL,
        claudeCodeUserSkillsDirectoryURL: URL?,
        claudeCodeProjectRootPaths: [String] = [],
        fileManager: FileManager = .default
    ) -> [DiscoveredSkill] {
        var allDiscoveredSkills: [DiscoveredSkill] = []

        let bundledDefaultFileNames = Set(DefaultSkillCatalog.skills.map(\.fileName))
        let heyMateDiscoveredSkills = scan(
            directoryURL: heyMateSkillsDirectoryURL,
            origin: .userSkillsFolder,
            fileManager: fileManager
        )
        allDiscoveredSkills += heyMateDiscoveredSkills.map { discoveredSkill in
            guard bundledDefaultFileNames.contains(discoveredSkill.fileURL.lastPathComponent) else {
                return discoveredSkill
            }
            return DiscoveredSkill(
                skill: discoveredSkill.skill,
                origin: .bundledDefault,
                fileURL: discoveredSkill.fileURL
            )
        }

        if let claudeCodeUserSkillsDirectoryURL {
            allDiscoveredSkills += scan(
                directoryURL: claudeCodeUserSkillsDirectoryURL,
                origin: .claudeCodeUserFolder,
                fileManager: fileManager
            )
        }

        for projectRootPath in claudeCodeProjectRootPaths {
            let projectSkillsDirectoryURL = URL(fileURLWithPath: projectRootPath, isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
            allDiscoveredSkills += scan(
                directoryURL: projectSkillsDirectoryURL,
                origin: .claudeCodeProjectFolder(projectRootPath: projectRootPath),
                fileManager: fileManager
            )
        }

        return allDiscoveredSkills
    }

    /// Project roots already used by HeyMate agent runs are the only project
    /// folders scanned automatically. This avoids walking arbitrary parts of
    /// the user's disk while still finding project-scoped Claude Code skills.
    static func uniqueProjectRootPaths(from agentRuns: [AgentRun]) -> [String] {
        var seenProjectRootPaths: Set<String> = []
        return agentRuns.compactMap { agentRun in
            let standardizedProjectRootPath = URL(
                fileURLWithPath: agentRun.workspacePath,
                isDirectory: true
            ).standardizedFileURL.path
            guard seenProjectRootPaths.insert(standardizedProjectRootPath).inserted else {
                return nil
            }
            return standardizedProjectRootPath
        }
    }

    /// `~/.claude/skills`, or nil when it does not exist. Nil is the signal to
    /// hide the Claude Code section entirely rather than show an empty one.
    static func defaultClaudeCodeUserSkillsDirectory(
        fileManager: FileManager = .default
    ) -> URL? {
        let claudeCodeSkillsDirectoryURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)

        var directoryExistsAsDirectory: ObjCBool = false
        let directoryExists = fileManager.fileExists(
            atPath: claudeCodeSkillsDirectoryURL.path,
            isDirectory: &directoryExistsAsDirectory
        )
        guard directoryExists, directoryExistsAsDirectory.boolValue else { return nil }
        return claudeCodeSkillsDirectoryURL
    }

    private static func parseSkill(atFileURL fileURL: URL, origin: SkillOrigin) -> DiscoveredSkill? {
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8),
              let parsedSkill = SkillMarkdownParser.parse(markdown)
        else { return nil }
        return DiscoveredSkill(skill: parsedSkill, origin: origin, fileURL: fileURL)
    }
}

// MARK: - Which skills are switched on

/// Decides, for a newly discovered skill the user has never seen, whether it
/// starts active. Kept separate from storage so the rule is testable and
/// stated in one place.
nonisolated enum SkillActivationPolicy {

    /// Skills in HeyMate's own folder were put there for HeyMate, so they
    /// start on — that preserves the pre-catalog behaviour where every loaded
    /// skill reached the prompt. Everything discovered elsewhere starts off:
    /// Claude Code skills were written for a different agent, and remote
    /// skills must be reviewed before they can shape an answer.
    static func startsActive(origin: SkillOrigin) -> Bool {
        switch origin {
        case .bundledDefault, .userSkillsFolder:
            return true
        case .claudeCodeUserFolder, .claudeCodeProjectFolder, .remoteRegistry:
            return false
        }
    }
}

/// Persists which discovered skills the user switched on, and in what order
/// they take precedence when several match the same transcript.
///
/// Storage is by skill identifier, so a skill that disappears (folder deleted,
/// file renamed) and comes back later keeps its state, and two same-named
/// skills from different folders never share one switch.
@MainActor
final class SkillActivationStore: ObservableObject {

    private enum StorageKey {
        static let explicitlyActivatedIdentifiers = "skills.explicitlyActivatedIdentifiers"
        static let explicitlyDeactivatedIdentifiers = "skills.explicitlyDeactivatedIdentifiers"
        static let priorityOrderedIdentifiers = "skills.priorityOrderedIdentifiers"
    }

    private let userDefaults: UserDefaults

    /// Skills the user switched ON by hand. Held separately from the OFF set
    /// so that a skill the user has never touched can still follow
    /// `SkillActivationPolicy` when its default changes in a later release.
    @Published private(set) var explicitlyActivatedIdentifiers: Set<String>

    /// Skills the user switched OFF by hand.
    @Published private(set) var explicitlyDeactivatedIdentifiers: Set<String>

    /// User-chosen precedence, highest first. Identifiers absent from this
    /// list fall in behind the ones present, in discovery order.
    @Published private(set) var priorityOrderedIdentifiers: [String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.explicitlyActivatedIdentifiers = Set(
            userDefaults.stringArray(forKey: StorageKey.explicitlyActivatedIdentifiers) ?? []
        )
        self.explicitlyDeactivatedIdentifiers = Set(
            userDefaults.stringArray(forKey: StorageKey.explicitlyDeactivatedIdentifiers) ?? []
        )
        self.priorityOrderedIdentifiers =
            userDefaults.stringArray(forKey: StorageKey.priorityOrderedIdentifiers) ?? []
    }

    /// Whether this skill's instructions may reach a prompt right now.
    func isActive(_ discoveredSkill: DiscoveredSkill) -> Bool {
        if explicitlyActivatedIdentifiers.contains(discoveredSkill.identifier) { return true }
        if explicitlyDeactivatedIdentifiers.contains(discoveredSkill.identifier) { return false }
        return SkillActivationPolicy.startsActive(origin: discoveredSkill.origin)
    }

    func setActive(_ shouldBeActive: Bool, for discoveredSkill: DiscoveredSkill) {
        let identifier = discoveredSkill.identifier
        if shouldBeActive {
            explicitlyActivatedIdentifiers.insert(identifier)
            explicitlyDeactivatedIdentifiers.remove(identifier)
        } else {
            explicitlyDeactivatedIdentifiers.insert(identifier)
            explicitlyActivatedIdentifiers.remove(identifier)
        }
        persist()
    }

    /// Clears every explicit choice, returning all skills to their policy
    /// defaults. Backs the library's "Reset to defaults" control.
    func resetAllActivationChoices() {
        explicitlyActivatedIdentifiers = []
        explicitlyDeactivatedIdentifiers = []
        priorityOrderedIdentifiers = []
        persist()
    }

    /// Replaces the precedence list. Only identifiers the user actually
    /// arranged are stored; the rest keep discovery order.
    func setPriorityOrder(_ orderedIdentifiers: [String]) {
        priorityOrderedIdentifiers = orderedIdentifiers
        persist()
    }

    /// The active skills, highest precedence first. This is the list that
    /// feeds retrieval, so its order decides which skill wins when several
    /// match a transcript equally well.
    func activeSkillsInPriorityOrder(from discoveredSkills: [DiscoveredSkill]) -> [DiscoveredSkill] {
        let activeSkills = discoveredSkills.filter { isActive($0) }

        // Identifiers the user explicitly ordered sort ahead of the rest, in
        // the user's order; everything else keeps the order it was discovered.
        var rankByIdentifier: [String: Int] = [:]
        for (rank, identifier) in priorityOrderedIdentifiers.enumerated() {
            rankByIdentifier[identifier] = rank
        }

        return activeSkills.enumerated().sorted { lhs, rhs in
            let lhsRank = rankByIdentifier[lhs.element.identifier]
            let rhsRank = rankByIdentifier[rhs.element.identifier]
            switch (lhsRank, rhsRank) {
            case let (leftRank?, rightRank?):
                return leftRank < rightRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private func persist() {
        userDefaults.set(
            Array(explicitlyActivatedIdentifiers).sorted(),
            forKey: StorageKey.explicitlyActivatedIdentifiers
        )
        userDefaults.set(
            Array(explicitlyDeactivatedIdentifiers).sorted(),
            forKey: StorageKey.explicitlyDeactivatedIdentifiers
        )
        userDefaults.set(
            priorityOrderedIdentifiers,
            forKey: StorageKey.priorityOrderedIdentifiers
        )
    }
}
