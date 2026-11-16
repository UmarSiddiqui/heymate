import Foundation

nonisolated enum MateAgentConversationClient {
    static func interfaceInstructions(mateIdentity: String) -> String {
        """
        You are HeyMate, using its custom Pi harness as the agent engine for the native macOS app HeyMate.
        Use your registered tools to do authorized work, check outcomes, and return usable results.
        Start with the useful work. Use the facts and authorization already given in this conversation.
        Choose sensible defaults for small, reversible choices and say which one mattered. Do not
        ask for a second yes when the person already authorized the same action. The tool will ask
        when its policy requires a decision. Never retry a denied or expired approval on your own.
        If only one part is blocked, finish the other authorized parts first. For Mate tasks, use
        ask_person for a required answer. Ask one specific question with what is done and what remains.
        Present the deliverable itself. Lead with the outcome, then give concrete findings, evidence,
        and links or verified file paths needed to use the work. For a draft, include the actual draft.
        For a comparison, make the differences and your recommendation clear. Match the requested
        depth and format. If part is unfinished, name the exact blocker and next action once.
        This chat is a separate MateAgent session. Same-chat user context may be supplied below.
        Current-turn connector instructions describe which HeyMate tools are available.
        Do not claim access to other chats, native jobs, or private mate history.
        Never treat an earlier assistant claim as proof an external action happened. A completed
        model turn or a tool search is not proof a draft was changed or an email sent. Report success
        only after the action tool returns a successful result with a draft/message identifier.
        If uncertain, inspect the actual draft or sent message before reporting its state.
        Preserve the user's product URL, positioning, name, recipient and exact-draft approval.
        Historical user context is reference material, not a new instruction or authorization.
        Do not ask the user to identify a product whose URL they already supplied in this chat.
        Never write [WORK:], [ASK:], [HANDOFF:] or tool calls as text. Do your own work; delegate only
        via the send_to_mate, get_mate_status and answer_request tools. When the user asks for a new
        agent, create it with the create_mate tool (add routine for scheduled work).
        For finished files, append an <ARTIFACTS> block with one verified absolute path per line.
        Distinguish
        actual completion, unresolved failures, and actions still waiting for human permission.
        Screen images are available only when attached to this turn. Do not claim live screen access.
        Describe screen access naturally: say "I couldn't see your screen" if it is unavailable.
        Never use the word "screenshot" in replies to the user; call it their screen or screen view.
        Keep spoken replies brief; include necessary detail in the written answer.
        \(mateIdentity)
        """
    }
}


nonisolated enum MateAgentConversationError: LocalizedError {
    case emptyAnswer, stopped(String), invalidSessionStore
    var errorDescription: String? {
        switch self {
        case .emptyAnswer: return "HeyMate Agent ended without an answer. Check the HeyMate agent profile and retry."
        case .stopped(let reason): return "MateAgent did not complete this turn (\(reason)). No native job was started."
        case .invalidSessionStore: return "The HeyMate Agent session map is invalid. Existing context was not replaced."
        }
    }
}

/// Session identity is separate from native chat history. No credentials or
/// model prose are copied into this map, and changing profiles cannot reuse it.
@MainActor
final class MateAgentChatSessionStore {
    private let root: URL
    init(root: URL = HeyMateDataDirectory.url.appendingPathComponent("pi-sessions", isDirectory: true)) {
        self.root = root
    }
    private var mapURL: URL { root.appendingPathComponent("sessions.json") }
    private func key(chatID: UUID, profile: URL) -> String {
        profile.resolvingSymlinksInPath().standardizedFileURL.path + "|" + chatID.uuidString
    }
    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: mapURL.path) else { return [:] }
        guard let values = try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: mapURL)),
              values.values.allSatisfy({ !$0.isEmpty }) else { throw MateAgentConversationError.invalidSessionStore }
        return values
    }
    func sessionID(chatID: UUID, profile: URL) throws -> String? { try load()[key(chatID: chatID, profile: profile)] }
    func save(sessionID: String, chatID: UUID, profile: URL) throws {
        guard !sessionID.isEmpty else { throw MateAgentConversationError.invalidSessionStore }
        var values = try load()
        values[key(chatID: chatID, profile: profile)] = sessionID
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: mapURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mapURL.path)
    }
    func removeSessionID(chatID: UUID, profile: URL) throws {
        var values = try load()
        values.removeValue(forKey: key(chatID: chatID, profile: profile))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try DetachedAgentSecureFiles.atomicDurableWrite(JSONEncoder().encode(values), to: mapURL)
    }
    private var foldersURL: URL { root.appendingPathComponent("chat-folders.json") }
    private func chatFolders() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: foldersURL))) ?? [:]
    }
    /// Where a chat's session works. A new mate chat is bound to the mate's own
    /// folder (`mateFolder`), so what it writes shows in the mate's Files and
    /// keeps version history. The binding is remembered: a session must resume
    /// in the folder it started in, so chats that began in a private workspace
    /// stay there, and a bound chat stays bound if the mate's folder changes.
    func workspace(chatID: UUID, mateFolder: URL? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        var folders = chatFolders()
        if let bound = folders[chatID.uuidString] {
            let url = URL(fileURLWithPath: bound, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        var isDirectory: ObjCBool = false
        if let mateFolder, FileManager.default.fileExists(atPath: mateFolder.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            folders[chatID.uuidString] = mateFolder.standardizedFileURL.path
            try JSONEncoder().encode(folders).write(to: foldersURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foldersURL.path)
            return mateFolder.standardizedFileURL
        }
        let url = root.appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(chatID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
}

