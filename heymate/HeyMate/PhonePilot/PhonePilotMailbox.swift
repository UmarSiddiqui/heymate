import Foundation

struct PhonePilotTask: Identifiable {
    let id: UUID
    let status: String
    let request: Data
    let result: Data?
    let createdAt: Date
    let updateTime: String
}

@MainActor
final class PhonePilotMailbox {
    private let session: URLSession
    private let database: URL
    private let name: String

    init(projectID: String, session: URLSession? = nil, emulator: URL? = nil) {
        name = "projects/\(projectID)/databases/(default)/documents"
        let origin = emulator ?? URL(string: "https://firestore.googleapis.com")!
        database = origin.appending(path: "v1/\(name)")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 16
        self.session = session ?? URLSession(configuration: config, delegate: PhonePilotNoRedirects(), delegateQueue: nil)
    }

    func pending(_ channel: PhonePilotChannel, token: String, statuses: [String]) async throws -> [PhonePilotTask] {
        let parent = collection(channel)
        let query: [String: Any] = [
            "from": [["collectionId": "tasks"]],
            "where": ["fieldFilter": ["field": ["fieldPath": "status"], "op": "IN",
                                      "value": ["arrayValue": ["values": statuses.map { ["stringValue": $0] }]]]],
            "limit": 25
        ]
        let body = try await request(database.appending(path: parent + ":runQuery"), token: token,
                                     body: ["structuredQuery": query])
        guard let rows = body as? [[String: Any]] else { throw PhonePilotError.invalidResponse }
        return try rows.compactMap { row in
            guard let doc = row["document"] else { return nil }
            return try decode(doc, channel: channel)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func task(_ channel: PhonePilotChannel, id: UUID, token: String) async throws -> PhonePilotTask? {
        do {
            let body = try await request(database.appending(path: path(channel, id)), token: token)
            return try decode(body, channel: channel)
        } catch let error as HTTPFailure where error.code == 404 { return nil }
    }

    func enqueue(_ channel: PhonePilotChannel, id: UUID, envelope: Data, token: String) async throws {
        try await write(channel, id: id, token: token, fields: [
            "status": ["stringValue": "queued"], "version": ["integerValue": "1"],
            "requestEnvelope": ["bytesValue": envelope.base64EncodedString()]
        ], precondition: ["exists": false])
    }

    func transition(_ channel: PhonePilotChannel, task: PhonePilotTask, status: String, result: Data? = nil,
                    token: String) async throws {
        var fields = ["status": ["stringValue": status]]
        if let result { fields["resultEnvelope"] = ["bytesValue": result.base64EncodedString()] }
        do {
            try await write(channel, id: task.id, token: token, fields: fields,
                            precondition: ["updateTime": task.updateTime], updating: true)
        } catch PhonePilotError.notEnrolled {
            // Rules may reject a now-invalid transition before Firestore checks
            // the timestamp precondition. Only report a race once we verify it.
            if let current = try? await self.task(channel, id: task.id, token: token),
               current.updateTime != task.updateTime { throw PhonePilotError.conflict }
            throw PhonePilotError.notEnrolled
        }
    }

    func delete(_ channel: PhonePilotChannel, task: PhonePilotTask, token: String) async throws {
        try await commit(["delete": "\(name)/\(path(channel, task.id))",
                          "currentDocument": ["updateTime": task.updateTime]], token: token)
    }

    func uploadAttachments(_ chunks: [(UUID, Data)], channel: PhonePilotChannel, token: String) async throws {
        let writes: [[String: Any]] = chunks.map { id, bytes in
            ["update": ["name": attachmentPath(channel, id),
                        "fields": ["envelope": ["bytesValue": bytes.base64EncodedString()]]],
             "currentDocument": ["exists": false]]
        }
        try await commit(writes, token: token)
    }

    func attachmentData(_ ids: [UUID], channel: PhonePilotChannel, token: String) async throws -> [UUID: Data] {
        let paths = Dictionary(uniqueKeysWithValues: ids.map { (attachmentPath(channel, $0), $0) })
        let response = try await request(URL(string: database.absoluteString + ":batchGet")!, token: token,
                                         body: ["documents": Array(paths.keys)])
        guard let rows = response as? [[String: Any]], rows.count == ids.count else {
            throw PhonePilotError.invalidResponse
        }
        var found: [UUID: Data] = [:]
        for row in rows {
            guard let document = row["found"] as? [String: Any],
                  let path = document["name"] as? String, let id = paths[path],
                  let fields = document["fields"] as? [String: [String: String]],
                  let encoded = fields["envelope"]?["bytesValue"], let bytes = Data(base64Encoded: encoded),
                  found[id] == nil else { throw PhonePilotError.invalidResponse }
            found[id] = try channel.open(Data.self, data: bytes, taskID: id, direction: .attachment)
        }
        return found
    }

    func deleteAttachments(_ ids: [UUID], channel: PhonePilotChannel, token: String) async throws {
        guard !ids.isEmpty else { return }
        try await commit(ids.map { ["delete": attachmentPath(channel, $0)] }, token: token)
    }

    private func attachmentPath(_ channel: PhonePilotChannel, _ id: UUID) -> String {
        "\(name)/companionPilot/\(channel.uid)/pairs/\(channel.pairID.uuidString)/attachmentChunks/\(id.uuidString)"
    }

    private func collection(_ channel: PhonePilotChannel) -> String {
        "companionPilot/\(channel.uid)/pairs/\(channel.pairID.uuidString)"
    }

    private func path(_ channel: PhonePilotChannel, _ id: UUID) -> String {
        collection(channel) + "/tasks/" + id.uuidString
    }

    private func write(_ channel: PhonePilotChannel, id: UUID, token: String, fields: [String: [String: String]],
                       precondition: [String: Any], updating: Bool = false) async throws {
        let timestamps = updating ? ["updatedAt"] : ["createdAt", "updatedAt"]
        var write: [String: Any] = [
            "update": ["name": "\(name)/\(path(channel, id))", "fields": fields],
            "currentDocument": precondition,
            "updateTransforms": timestamps.map { ["fieldPath": $0, "setToServerValue": "REQUEST_TIME"] }
        ]
        if updating { write["updateMask"] = ["fieldPaths": fields.keys.sorted()] }
        try await commit(write, token: token)
    }

    private func commit(_ write: [String: Any], token: String) async throws {
        try await commit([write], token: token)
    }

    private func commit(_ writes: [[String: Any]], token: String) async throws {
        _ = try await request(URL(string: database.absoluteString + ":commit")!, token: token, body: ["writes": writes])
    }

    private func decode(_ value: Any, channel: PhonePilotChannel) throws -> PhonePilotTask {
        guard let doc = value as? [String: Any], let resource = doc["name"] as? String,
              let part = resource.split(separator: "/").last, let id = UUID(uuidString: String(part)),
              resource == "\(name)/\(path(channel, id))",
              let updateTime = doc["updateTime"] as? String,
              let fields = doc["fields"] as? [String: [String: Any]],
              fields["version"]?["integerValue"] as? String == "1",
              let status = fields["status"]?["stringValue"] as? String,
              let envelope = fields["requestEnvelope"]?["bytesValue"] as? String,
              let data = Data(base64Encoded: envelope),
              let timestamp = fields["createdAt"]?["timestampValue"] as? String,
              let createdAt = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(timestamp))
                ?? (try? Date.ISO8601FormatStyle().parse(timestamp)) else { throw PhonePilotError.invalidResponse }
        let result = (fields["resultEnvelope"]?["bytesValue"] as? String).flatMap { Data(base64Encoded: $0) }
        return PhonePilotTask(id: id, status: status, request: data, result: result, createdAt: createdAt, updateTime: updateTime)
    }

    private struct HTTPFailure: Error { let code: Int }

    private func request(_ url: URL, token: String, body: [String: Any]? = nil) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PhonePilotError.unavailable }
        switch response.statusCode {
        case 200..<300: return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
        case 403: throw PhonePilotError.notEnrolled
        case 409, 412: throw PhonePilotError.conflict
        case 404: throw HTTPFailure(code: 404)
        default:
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
            if let status = payload?["error"]?["status"] as? String,
               ["FAILED_PRECONDITION", "ALREADY_EXISTS", "ABORTED"].contains(status) {
                throw PhonePilotError.conflict
            }
            throw PhonePilotError.unavailable
        }
    }
}

final class PhonePilotNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
                               completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
