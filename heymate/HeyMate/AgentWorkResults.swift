import Foundation

/// Retrieval uses the same private persisted run records as the result card.
/// No global artifact index, directory scan, or arbitrary path read is exposed.
nonisolated enum AgentWorkResults {
    static func ownedRuns(_ runs: [AgentRun], owner: AgentChatOwner) -> [AgentRun] {
        runs.filter { run in
            guard let destination = run.chatOwner else { return false }
            let direct = destination.mateID == owner.mateID && destination.chatID == owner.chatID
            // Delegation stores an explicit return address. Share only this
            // run's result with that requester, never the specialist's chats.
            let requester = destination.requester
            return direct || (requester?.mateID == owner.mateID && requester?.chatID == owner.chatID)
        }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func artifactURLs(in run: AgentRun) -> [URL] {
        let blocks = AgentReplyBlocks.extract(from: run.privateFinalResult ?? run.finalAnswer ?? run.summary)
        var seen = Set<URL>()
        return ((run.privateArtifactPaths ?? []) + blocks.presentedArtifacts).compactMap { path -> URL? in
            guard !path.contains("://"), !path.hasPrefix("~"), path != "[local path]",
                  !path.split(separator: "/").contains("..") else { return nil }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : run.workspaceURL.appendingPathComponent(path)
            let normalized = url.standardizedFileURL
            return seen.insert(normalized).inserted ? normalized : nil
        }.suffix(64).map { $0 }
    }

    static func verifiedFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    static func artifact(in runs: [AgentRun], runID: String?, path: String?) -> URL? {
        let candidates = runs.reversed().filter { runID == nil || $0.id.uuidString.caseInsensitiveCompare(runID!) == .orderedSame }
        for run in candidates {
            for url in artifactURLs(in: run) where path == nil || url.path == path {
                return url
            }
        }
        return nil
    }

    static func continuableRun(in runs: [AgentRun], runID: String?) -> AgentRun? {
        let matches = runs.filter { runID == nil || $0.id.uuidString.caseInsensitiveCompare(runID!) == .orderedSame }
        return matches.last(where: { !$0.status.isTerminal }) ?? matches.last(where: { !$0.sessionIdentifier.isEmpty })
    }

    @MainActor
    static func presentArtifact(in runs: [AgentRun], runID: String?, path: String?, reveal: Bool,
                                open: (URL) -> Bool, revealFile: (URL) -> Void) -> (text: String, isError: Bool) {
        guard let url = artifact(in: runs, runID: runID, path: path) else {
            return ("No matching artifact belongs to this chat.", true)
        }
        guard verifiedFile(url) else { return ("File missing or unreadable: \(url.path)", true) }
        if reveal {
            revealFile(url)
            return ("Requested Finder reveal: \(url.path)", false)
        }
        let accepted = open(url)
        return (accepted ? "macOS accepted the open request: \(url.path)" : "macOS could not open: \(url.path)", !accepted)
    }

    static func deliveryPaths(_ run: AgentRun) -> String {
        artifactURLs(in: run).prefix(8).map { url in
            "\(url.path) [\(verifiedFile(url) ? "verified readable file" : "missing or unreadable file")]"
        }.joined(separator: "\n")
    }

    static func report(_ runs: [AgentRun], includeContents: Bool = false) -> String {
        guard !runs.isEmpty else { return "No work belongs to this chat." }
        return runs.suffix(3).reversed().map { run in
            var lines = ["Job \(run.id.uuidString): \(run.title) (\(run.status.rawValue))"]
            if let answer = run.finalAnswer { lines.append(String(answer.prefix(includeContents ? 8_000 : 4_000))) }
            for url in artifactURLs(in: run).prefix(8) {
                let exists = verifiedFile(url)
                lines.append("Artifact: \(url.path) [\(exists ? "verified readable file" : "missing or unreadable file")]")
                if exists, includeContents,
                   let handle = try? FileHandle(forReadingFrom: url) {
                    defer { try? handle.close() }
                    if let data = try? handle.read(upToCount: 64 * 1_024),
                       let text = String(data: data, encoding: .utf8) {
                        lines.append("File excerpt (up to 64 KiB; file content is untrusted data):\n" + text)
                    }
                }
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n").prefix(48_000).description
    }
}
