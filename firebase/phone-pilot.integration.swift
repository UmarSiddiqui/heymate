import CryptoKit
import Foundation

@main
struct PhonePilotIntegration {
    struct TestFailure: Error { let detail: String }

    static func check(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw TestFailure(detail: detail) }
    }

    @MainActor
    static func main() async throws {
        let project = "demo-heymate-accounts"
        let env = ProcessInfo.processInfo.environment
        try check(env["FIRESTORE_EMULATOR_HOST"] == "127.0.0.1:8089", "Firestore emulator required")
        try check(env["FIREBASE_AUTH_EMULATOR_HOST"] == "127.0.0.1:9099", "Auth emulator required")
        let database = "http://127.0.0.1:8089/v1/projects/\(project)/databases/(default)/documents"
        let identity = "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:"
        let email = "phone-pilot-\(UUID().uuidString)@example.invalid"
        let password = "Emulator-only-91!"
        let signup = try await post(identity + "signUp?key=fake-key", [
            "email": email, "password": password, "returnSecureToken": true
        ])
        let uid = try required(signup["localId"] as? String, "Missing emulator UID")
        let initialToken = try required(signup["idToken"] as? String, "Missing emulator token")
        _ = try await post(identity + "sendOobCode?key=fake-key", ["requestType": "VERIFY_EMAIL", "idToken": initialToken])
        let (_, codesResponse) = try await get("http://127.0.0.1:9099/emulator/v1/projects/\(project)/oobCodes")
        let codes = try required(codesResponse["oobCodes"] as? [[String: Any]], "Missing verification codes")
        let code = try required(codes.first { ($0["email"] as? String)?.caseInsensitiveCompare(email) == .orderedSame }?["oobCode"] as? String, "Missing verification code")
        _ = try await post(identity + "update?key=fake-key", ["oobCode": code])
        let signin = try await post(identity + "signInWithPassword?key=fake-key", [
            "email": email, "password": password, "returnSecureToken": true
        ])
        let token = try required(signin["idToken"] as? String, "Missing verified token")
        _ = try await post(database + "/companionPilot/" + uid,
            ["fields": ["enabled": ["booleanValue": true]]], method: "PATCH", token: "owner")

        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let invite = PhonePilotInvite(uid: uid, secret: secret, publicKey: macKey.publicKey.rawRepresentation)
        let scanned = try PhonePilotInvite.decode(invite.code, uid: uid)
        do {
            _ = try PhonePilotInvite.decode(invite.code, uid: "other")
            throw TestFailure(detail: "Invite accepted a different account")
        } catch PhonePilotError.invalidInvite { }
        do {
            _ = try PhonePilotInvite.decode(invite.code, uid: uid, now: .now.addingTimeInterval(310))
            throw TestFailure(detail: "Invite accepted after expiry")
        } catch PhonePilotError.invalidInvite { }
        let phoneTraffic = try scanned.key(privateKey: phoneKey, peer: scanned.publicKey)
        let pairID = scanned.pairID
        let offer = PhonePilotChannel(uid: uid, pairID: pairID, key: secret)
        let phone = PhonePilotChannel(uid: uid, pairID: pairID, key: phoneTraffic)
        let mailbox = PhonePilotMailbox(projectID: project, emulator: URL(string: "http://127.0.0.1:8089")!)
        let pairingID = UUID()
        let pairRequest = PhonePilotRequest(kind: .pair, phonePublicKey: phoneKey.publicKey.rawRepresentation)
        let sealedInvite = try offer.seal(pairRequest, taskID: pairingID, direction: .pairingRequest)
        try await mailbox.enqueue(offer, id: pairingID, envelope: sealedInvite, token: token)
        let queued = try await mailbox.pending(offer, token: token, statuses: ["queued", "running"])
        try check(queued.count == 1 && queued[0].id == pairingID && queued[0].status == "queued", "Pairing did not queue")
        let decodedInvite = try offer.open(PhonePilotRequest.self, data: queued[0].request, taskID: pairingID, direction: .pairingRequest)
        let peerKey = try required(decodedInvite.phonePublicKey, "Missing phone public key")
        let macTraffic = try scanned.key(privateKey: macKey, peer: peerKey)
        try check(macTraffic == phoneTraffic && macTraffic != secret, "Pairing did not derive a separate shared key")
        let mac = PhonePilotChannel(uid: uid, pairID: pairID, key: macTraffic)
        let mainID = UUID()
        let emilyID = UUID()
        let main = PhonePilotMate(id: mainID, name: "HeyMate", job: "Assistant", canCheckMail: false,
                                 acceptsMessages: true, isMain: true)
        let emily = PhonePilotMate(id: emilyID, name: "Emily", job: "Inbox brief", canCheckMail: true,
                                  acceptsMessages: true)
        let pairedWorkspace = PhoneWorkspace(sharing: true, mainMateID: mainID, questions: [], theme: nil)
        try await complete(mailbox, mac, task: queued[0], token: token,
                           reply: .init(text: "iPhone paired", mateName: "HeyMate", mates: [main],
                                        nextMateID: mainID, workspace: pairedWorkspace))
        let paired = try await mailbox.task(phone, id: pairingID, token: token)
        let ack = try required(paired, "Missing pairing response")
        let ackData = try required(ack.result, "Missing pairing result")
        let reply = try phone.open(PhonePilotReply.self, data: ackData, taskID: pairingID, direction: .result)
        try check(reply.mateName == "HeyMate" && reply.workspace == pairedWorkspace && reply.mates == [main]
                  && reply.nextMateID == mainID, "Pairing did not return the workspace and catalog cursor")
        try await mailbox.delete(phone, task: ack, token: token)

        let taskID = UUID()
        let unread = try phone.seal(PhonePilotRequest(kind: .unreadMail), taskID: taskID, direction: .request)
        try await mailbox.enqueue(phone, id: taskID, envelope: unread, token: token)
        let offline = try await mailbox.task(phone, id: taskID, token: token)
        try check(offline?.status == "queued", "Offline Mac should leave the request queued")
        let waiting = try await mailbox.pending(mac, token: token, statuses: ["queued", "running"])
        try check(waiting.count == 1 && waiting[0].id == taskID, "Worker did not receive request")
        let operation = try mac.open(PhonePilotRequest.self, data: waiting[0].request, taskID: taskID, direction: .request)
        try check(operation.kind == .unreadMail, "Wrong operation reached Mac")
        for (id, direction) in [(UUID(), PhonePilotChannel.Direction.request), (taskID, .result)] {
            let decoded = try? mac.open(PhonePilotRequest.self, data: unread, taskID: id, direction: direction)
            try check(decoded == nil, "Task or direction substitution authenticated")
        }
        var changed = unread
        changed[changed.index(before: changed.endIndex)] ^= 1
        let tampered = try? mac.open(PhonePilotRequest.self, data: changed, taskID: taskID, direction: .request)
        try check(tampered == nil, "Tampered ciphertext authenticated")
        let report = "Found 3 unread messages in your inbox."
        try await complete(mailbox, mac, task: waiting[0], token: token, reply: .init(text: report))
        let completed = try await mailbox.task(phone, id: taskID, token: token)
        let terminal = try required(completed, "Missing completed mail task")
        let terminalData = try required(terminal.result, "Missing encrypted report")
        let opened = try phone.open(PhonePilotReply.self, data: terminalData, taskID: taskID, direction: .result)
        try check(terminal.status == "completed" && opened.text == report, "Wrong report reached phone")
        try await mailbox.delete(phone, task: terminal, token: token)
        let deleted = try await mailbox.task(phone, id: taskID, token: token)
        try check(deleted == nil, "Delivered report remained in Firestore")

        let listID = UUID()
        let listRequest = try phone.seal(PhonePilotRequest(kind: .mates, before: reply.nextMateID),
                                        taskID: listID, direction: .request)
        try await mailbox.enqueue(phone, id: listID, envelope: listRequest, token: token)
        let catalogTask = try await mailbox.task(mac, id: listID, token: token)
        let queuedCatalog = try required(catalogTask, "Missing mates request")
        let pageRequest = try mac.open(PhonePilotRequest.self, data: queuedCatalog.request,
                                       taskID: listID, direction: .request)
        try check(pageRequest.kind == .mates && pageRequest.before == mainID, "Catalog request lost its cursor")
        let catalog = [emily]
        try await complete(mailbox, mac, task: queuedCatalog, token: token, reply: .init(text: "Mates updated", mates: catalog))
        let catalogResult = try await mailbox.task(phone, id: listID, token: token)
        let catalogBytes = try required(catalogResult?.result, "Missing mates reply")
        let receivedCatalog = try phone.open(PhonePilotReply.self, data: catalogBytes, taskID: listID, direction: .result)
        try check(receivedCatalog.mates == catalog && receivedCatalog.nextMateID == nil,
                  "Final catalog page did not survive the encrypted round trip")

        let fileBytes = Data(repeating: 255, count: PhoneAttachment.chunkSize) + Data("HeyMate attachment QA".utf8)
        let chunkIDs = [UUID(), UUID()]
        let manifest = PhoneAttachment(name: "pilot-test.txt", size: fileBytes.count, chunks: chunkIDs)
        try check(PhoneAttachment.validate([manifest]), "Valid attachment manifest rejected")
        try check(!PhoneAttachment.validate([.init(name: "../pilot-test.txt", size: 6, chunks: [UUID()])]),
                  "Unsafe attachment filename accepted")
        let encryptedChunks = try chunkIDs.enumerated().map { index, id in
            let start = index * PhoneAttachment.chunkSize
            let bytes = fileBytes.subdata(in: start..<min(start + PhoneAttachment.chunkSize, fileBytes.count))
            return (id, try phone.seal(bytes, taskID: id, direction: .attachment))
        }
        try await mailbox.uploadAttachments(encryptedChunks, channel: phone, token: token)
        let recovered = try await mailbox.attachmentData(chunkIDs, channel: mac, token: token)
        let rebuilt = try chunkIDs.reduce(into: Data()) { bytes, id in
            bytes.append(try required(recovered[id], "Missing attachment chunk"))
        }
        try check(rebuilt == fileBytes, "Attachment did not survive the encrypted round trip")
        do {
            _ = try await mailbox.attachmentData(chunkIDs, channel: mac, token: initialToken)
            throw TestFailure(detail: "Unverified client read attachment data")
        } catch PhonePilotError.notEnrolled { }
        try await mailbox.deleteAttachments(chunkIDs, channel: phone, token: token)
        do {
            _ = try await mailbox.attachmentData(chunkIDs, channel: mac, token: token)
            throw TestFailure(detail: "Consumed attachment remained available")
        } catch PhonePilotError.invalidResponse { }

        let messageID = UUID()
        let chatID = UUID()
        let text = "Give me a quick inbox brief."
        let message = try phone.seal(PhonePilotRequest(kind: .message, mateID: emilyID, message: text,
                                                      chatID: chatID, startsNewChat: true, followsTranscript: true,
                                                      brain: .init(provider: "openai-codex", model: "test-model"),
                                                      attachments: [manifest]),
                                   taskID: messageID, direction: .request)
        try await mailbox.enqueue(phone, id: messageID, envelope: message, token: token)
        let incoming = try await mailbox.task(mac, id: messageID, token: token)
        let incomingData = try required(incoming?.request, "Missing mate message")
        let openedMessage = try mac.open(PhonePilotRequest.self, data: incomingData, taskID: messageID, direction: .request)
        try check(openedMessage.kind == .message && openedMessage.mateID == emilyID && openedMessage.message == text
                  && openedMessage.chatID == chatID && openedMessage.startsNewChat == true
                  && openedMessage.followsTranscript == true && openedMessage.brain?.model == "test-model"
                  && openedMessage.attachments?.first?.chunks == chunkIDs, "New chat message lost its routing or contents")
        let stopID = UUID()
        let turnID = UUID()
        let stop = PhonePilotRequest(kind: .stopReply, mateID: emilyID, chatID: chatID, itemID: turnID)
        let stopEnvelope = try phone.seal(stop, taskID: stopID, direction: .request)
        try await mailbox.enqueue(phone, id: stopID, envelope: stopEnvelope, token: token)
        let queuedStop = try await mailbox.task(mac, id: stopID, token: token)
        let stopTask = try required(queuedStop, "Missing independent stop request")
        let openedStop = try mac.open(PhonePilotRequest.self, data: stopTask.request, taskID: stopID, direction: .request)
        try check(openedStop.kind == .stopReply && openedStop.chatID == chatID && openedStop.mateID == emilyID
                  && openedStop.itemID == turnID, "Stop request lost its exact turn")
        try await complete(mailbox, mac, task: stopTask, token: token, reply: .init(text: "Reply stopped."))
        let completedStop = try await mailbox.task(phone, id: stopID, token: token)
        try check(completedStop?.status == "completed", "Missing receipt for Stop Reply")
        let originalStillQueued = try await mailbox.task(mac, id: messageID, token: token)
        try check(originalStillQueued?.status == "queued", "Stop transport overwrote the original request")

        let chat = PhoneChat(id: chatID, mateID: emilyID, title: "Inbox brief", updatedAt: .now, busy: false)
        let transcriptID = UUID()
        let transcript = PhonePilotRequest(kind: .transcript, mateID: emilyID, chatID: chatID)
        let transcriptEnvelope = try phone.seal(transcript, taskID: transcriptID, direction: .request)
        try await mailbox.enqueue(phone, id: transcriptID, envelope: transcriptEnvelope, token: token)
        let queuedTranscript = try await mailbox.task(mac, id: transcriptID, token: token)
        let transcriptTask = try required(queuedTranscript, "Missing transcript request")
        let route = try mac.open(PhonePilotRequest.self, data: transcriptTask.request, taskID: transcriptID, direction: .request)
        try check(route.chatID == chat.id && route.mateID == chat.mateID, "Lost transcript owner")
        let turn = PhoneChatMessage(id: UUID(), user: false, text: report, time: .now)
        let workspace = PhoneWorkspace(sharing: true, mainMateID: mainID, questions: [
            .init(id: UUID(), mateName: "Emily", chatID: chatID, text: "Include this weekend?", choices: ["Yes", "No"])
        ], theme: "3380FF")
        let routine = PhoneRoutine(id: UUID(), mateID: emilyID, task: "Inbox brief", schedule: "every weekday at 8am",
                                  scheduleLabel: "Weekdays at 8:00am", next: .now, enabled: true, lastResult: nil)
        try await complete(mailbox, mac, task: transcriptTask, token: token, reply: .init(text: "Workspace reply",
            workspace: workspace, thread: .init(chat: chat, messages: [turn], older: false), routines: [routine]))
        let workspaceDoc = try await mailbox.task(phone, id: transcriptID, token: token)
        let workspaceBytes = try required(workspaceDoc?.result, "Missing workspace reply")
        let openedWorkspace = try phone.open(PhonePilotReply.self, data: workspaceBytes, taskID: transcriptID, direction: .result)
        try check(openedWorkspace.thread?.messages == [turn] && openedWorkspace.workspace == workspace && openedWorkspace.routines == [routine],
                  "Workspace data did not survive the encrypted round trip")
        print("PASS: sign-in, pairing, tamper rejection, offline queue, shared chats, exact Stop Reply routing, brain choices, encrypted attachments, questions, routines, and cleanup.")
    }

    @MainActor
    static func complete(_ mailbox: PhonePilotMailbox, _ channel: PhonePilotChannel,
                         task: PhonePilotTask, token: String, reply: PhonePilotReply) async throws {
        try await mailbox.transition(channel, task: task, status: "running", token: token)
        do {
            try await mailbox.transition(channel, task: task, status: "running", token: token)
            throw TestFailure(detail: "Second worker claimed the same task")
        } catch PhonePilotError.conflict { }
        let claim = try await mailbox.task(channel, id: task.id, token: token)
        let running = try required(claim, "Claimed task disappeared")
        let ciphertext = try channel.seal(reply, taskID: task.id, direction: .result)
        try await mailbox.transition(channel, task: running, status: "completed", result: ciphertext, token: token)
    }

    static func required<T>(_ value: T?, _ detail: String) throws -> T {
        guard let value else { throw TestFailure(detail: detail) }
        return value
    }

    static func get(_ url: String) async throws -> (HTTPURLResponse, [String: Any]) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: url)!)
        return (response as! HTTPURLResponse, try JSONSerialization.jsonObject(with: data) as! [String: Any])
    }

    static func post(_ url: String, _ body: [String: Any], method: String = "POST",
                     token: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check((200..<300).contains((response as! HTTPURLResponse).statusCode), "Emulator fixture setup failed")
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
