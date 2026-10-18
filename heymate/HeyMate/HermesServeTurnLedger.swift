import Foundation

/// Private crash-recovery ledger. The pending turn's starting replay cursor
/// never advances until its terminal result and delivery key commit together.
/// Prompt prose and credentials are deliberately absent.
@MainActor
final class HermesServeTurnLedger {
    struct Pending: Codable, Equatable {
        let id: UUID
        let sessionID: String
        let startCheckpoint: HermesServeSession.Checkpoint
        let createdAt: Date
        var accepted = false
        var userRowID: Int?
    }
    struct Delivery: Codable, Equatable {
        let id: UUID
        var text: String
        let status: String
        let completionSequence: Int?
        var sessionID: String? = nil
        var delivered = false
        var key: String { "hermes-serve:\(id.uuidString)" }
    }
    struct Record: Codable, Equatable {
        var pending: Pending?
        var checkpoint: HermesServeSession.Checkpoint?
        var deliveries: [Delivery] = []
        var needsFreshSession: Bool = false
    }
    enum Failure: Error, LocalizedError {
        case corrupt, pendingTurn, missingPendingTurn
        var errorDescription: String? {
            switch self {
            case .corrupt: return "The Hermes recovery ledger is invalid. No replacement work was submitted."
            case .pendingTurn: return "Earlier Hermes work needs recovery before another task can start."
            case .missingPendingTurn: return "The Hermes result has no matching durable pending task. Its delivery was not marked complete."
            }
        }
    }
    private let root: URL
    private var file: URL { root.appendingPathComponent("turn-ledger.json") }
    init(root: URL = HeyMateDataDirectory.url.appendingPathComponent("hermes-serve", isDirectory: true)) { self.root = root }

    private func key(chatID: UUID, profile: URL) -> String {
        profile.resolvingSymlinksInPath().standardizedFileURL.path + "|" + chatID.uuidString
    }
    private func read() throws -> [String: Record] {
        guard DetachedAgentSecureFiles.pathExistsWithoutFollowingLinks(file) else { return [:] }
        do {
            try DetachedAgentSecureFiles.validateDirectory(root)
            let data = try DetachedAgentSecureFiles.readRegularFile(file, maximumByteCount: 16 * 1_024 * 1_024)
            let records = try JSONDecoder().decode([String: Record].self, from: data)
            guard records.values.allSatisfy({ record in
                record.deliveries.count <= 24 && Set(record.deliveries.map(\.id)).count == record.deliveries.count
                    && record.pending.map { !$0.sessionID.isEmpty && $0.startCheckpoint.lastSequence >= 0 } != false
            }) else { throw Failure.corrupt }
            return records
        } catch { throw Failure.corrupt }
    }
    private func write(_ records: [String: Record]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(records)
        guard data.count <= 16 * 1_024 * 1_024 else { throw Failure.corrupt }
        try DetachedAgentSecureFiles.atomicDurableWrite(data, to: file)
    }
    func record(chatID: UUID, profile: URL) throws -> Record {
        try read()[key(chatID: chatID, profile: profile)] ?? Record()
    }
    func begin(chatID: UUID, profile: URL, checkpoint: HermesServeSession.Checkpoint) throws -> Pending {
        var records = try read()
        let key = key(chatID: chatID, profile: profile)
        var record = records[key] ?? Record()
        guard record.pending == nil, !record.needsFreshSession else { throw Failure.pendingTurn }
        let pending = Pending(id: UUID(), sessionID: checkpoint.identity.storedID, startCheckpoint: checkpoint, createdAt: Date())
        record.pending = pending
        record.checkpoint = checkpoint
        records[key] = record
        try write(records)
        return pending
    }
    func markAccepted(chatID: UUID, profile: URL, userRowID: Int?) throws {
        var records = try read()
        let key = key(chatID: chatID, profile: profile)
        guard records[key]?.pending != nil else { throw Failure.missingPendingTurn }
        records[key]?.pending?.accepted = true
        records[key]?.pending?.userRowID = userRowID
        try write(records)
    }
    @discardableResult
    func complete(chatID: UUID, profile: URL, result: HermesServeSession.Result,
                  checkpoint: HermesServeSession.Checkpoint?, startFreshSession: Bool = false) throws -> Delivery {
        var records = try read()
        let key = key(chatID: chatID, profile: profile)
        guard var record = records[key], let pending = record.pending else { throw Failure.missingPendingTurn }
        let delivery = Delivery(id: pending.id, text: result.text, status: result.status, completionSequence: result.completionSequence, sessionID: pending.sessionID)
        record.pending = nil
        record.checkpoint = checkpoint
        record.needsFreshSession = startFreshSession
        // Retain bounded delivered metadata so an explicitly archived old
        // session remains attributable after a fresh context is created.
        if record.deliveries.count >= 24 { record.deliveries.removeAll { $0.delivered && $0.status != "unverified" } }
        guard record.deliveries.count < 24 else { throw Failure.corrupt }
        record.deliveries.append(delivery)
        records[key] = record
        try write(records)
        return delivery
    }
    func markDelivered(_ id: UUID, chatID: UUID, profile: URL) throws {
        var records = try read()
        let key = key(chatID: chatID, profile: profile)
        guard let index = records[key]?.deliveries.firstIndex(where: { $0.id == id }) else { return }
        records[key]?.deliveries[index].delivered = true
        records[key]?.deliveries[index].text = ""
        try write(records)
    }
    func confirmSessionReset(chatID: UUID, profile: URL) throws {
        var records = try read()
        let key = key(chatID: chatID, profile: profile)
        records[key]?.needsFreshSession = false
        try write(records)
    }
}
