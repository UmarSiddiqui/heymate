// Vendored/adapted from vinzdg/codenotch, MIT. Revision 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Upstream: Sources/Sessions/GeminiCLIActivity.swift; see Codenotch-PROVENANCE.md for local changes.
import Foundation

/// Notices when Gemini CLI is working.
///
/// Its chat recordings hold no pid — nothing in the JSONL names the process —
/// so `CNProcessLiveness` has nothing to verify and recency is the only signal
/// there is. It is a good one: the CLI appends a `$set lastUpdated` patch on
/// every message, so a file written moments ago is a turn in progress. Cursor
/// and Antigravity stand on the same substitute.
nonisolated enum CNGeminiCLIActivity {
    static func read(root: URL, staleAfter: TimeInterval, now: Date = Date()) -> [CNAgentSession] {
        guard let projects = try? CNReadBudget.directory(root) else { return [] }

        var newest: (session: URL, project: URL, modified: Date)?
        for project in projects {
            let chats = project.appendingPathComponent("chats")
            guard let files = try? CNReadBudget.directory(chats) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate else { continue }
                if newest == nil || modified > newest!.modified {
                    newest = (file, project, modified)
                }
            }
        }

        // An older session is a finished turn, and showing it as work in
        // progress would be a guess dressed as a fact.
        guard let newest, now.timeIntervalSince(newest.modified) >= -5, now.timeIntervalSince(newest.modified) <= staleAfter else { return [] }
        return [CNAgentSession(
            id: "gemini-api.\(newest.session.deletingPathExtension().lastPathComponent)",
            name: "Gemini CLI",
            detail: CNL10n.t("Working in \(projectName(of: newest.project))"),
            state: .busy,
            waitingFor: nil,
            since: newest.modified
        )]
    }

    /// The directory is named after a hash of the working directory, which says
    /// nothing to whoever reads the tooltip; the CLI writes the path that hash
    /// stands for beside it, and the last component of that path is the folder
    /// the user knows the project by.
    private static func projectName(of project: URL) -> String {
        let marker = project.appendingPathComponent(".project_root")
        if let text = try? CNReadBudget.text(marker) {
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
        }
        return project.lastPathComponent
    }
}
