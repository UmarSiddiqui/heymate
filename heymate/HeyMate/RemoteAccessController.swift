//
//  RemoteAccessController.swift
//  HeyMate
//
//  Phone access: reach your mates from a phone browser on the same network.
//  Off by default. Lives in the app (not the agent runtime) because the
//  Inbox, proposals, questions and mate status are app state
//  (MateInboxStore, CompanionManager); the runtime's server and token are
//  never exposed. Every action calls the same CompanionManager function the
//  Mac's own buttons call, so the two cannot drift:
//    Approve / Skip  -> actOnMateProposal(id:action:)
//    Answer          -> answerMateInboxItem(id:answer:)
//    Message a mate  -> resumeMateChatInBackground(...), the Inbox's own path
//  Rules live in RemoteAccessCore.swift; this file only wires them up.
//

import AppKit
import Combine
import Foundation
import SystemConfiguration

@MainActor
final class RemoteAccessController: ObservableObject {
    static let shared = RemoteAccessController()
    static let enabledDefaultsKey = "phoneAccessEnabled"
    /// Set by MateInbox's approval path while a tool call waits on the Mac.
    static let permissionStepTitle = "Waiting for permission"

    @Published private(set) var isEnabled = false
    @Published private(set) var problem: String?
    @Published private(set) var devices: [RemoteDevice] = []
    @Published private(set) var log: [RemoteAuditEntry] = []
    @Published private(set) var pairing = RemotePairing()
    @Published private(set) var addressHost: String?

    private weak var companion: CompanionManager?
    private var server: RemoteAccessServer?
    private var requestLimiter = RemoteRateLimiter(capacity: 60, refillPerSecond: 1)
    private var actionLimiter = RemoteRateLimiter(capacity: 10, refillPerSecond: 0.2)
    private var pairLimiter = RemoteRateLimiter(capacity: 10, refillPerSecond: 1.0 / 30)
    private var pendingMessages: [UUID: PendingMessage] = [:]
    private var lastSeenSaved: [UUID: Date] = [:]
    private let fileURL: URL

    private struct PendingMessage {
        let deviceID: UUID
        let mateID: UUID
        let chatID: UUID
        let knownWork: Set<UUID>
        let sentAt: Date
    }

    private struct Stored: Codable {
        var devices: [RemoteDevice]
        var log: [RemoteAuditEntry]
    }

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent("phone-access.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            devices = RemoteDeviceRegistry.pruned(stored.devices, now: Date())
            log = stored.log
        }
    }

    // MARK: Switch

    /// Called at launch and whenever Settings shows Phone access. Resumes
    /// the listener only if the person left the switch on.
    func attach(_ companion: CompanionManager) {
        self.companion = companion
        if UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey), !isEnabled { setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard !HeyMateDataDirectory.isUnitTestHost, companion != nil else { return }
            UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
            startListening()
        } else {
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            let hadPhones = !devices.isEmpty
            server?.stop()
            server = nil
            isEnabled = false
            problem = nil
            pairing.cancel()
            pendingMessages.removeAll()
            requestLimiter.reset()
            actionLimiter.reset()
            pairLimiter.reset()
            devices.removeAll()
            if hadPhones { record(device: "This Mac", "Turned off Phone access; every phone was unpaired") }
            save()
        }
    }

    private func startListening() {
        let server = server ?? RemoteAccessServer { [weak self] request, peer in
            guard let self else { return .error(403) }
            return await self.handle(request, peer: peer)
        }
        server.onStateChange = { [weak self] message in
            guard let self else { return }
            self.problem = message
            if message != nil { self.isEnabled = false }
        }
        do {
            try server.start(port: RemoteAccessPolicy.port)
            self.server = server
            isEnabled = true
            problem = nil
            refreshAddress()
            HeyMateLog.log("📱 Phone access listening on port \(RemoteAccessPolicy.port)")
        } catch {
            isEnabled = false
            problem = "Couldn't start listening on this network."
        }
    }

    // MARK: Pairing and devices (Mac side)

    func startPairing() {
        guard isEnabled else { return }
        refreshAddress()
        pairing.start(code: RemotePairing.makeCode(), now: Date())
    }

    func cancelPairing() { pairing.cancel() }

    var pairingURL: String? {
        guard let code = pairing.code, let addressHost else { return nil }
        return "http://\(addressHost)/#pair=\(code)"
    }

    var pageURL: String? { addressHost.map { "http://\($0)/" } }

    func revoke(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        devices.removeAll { $0.id == id }
        pendingMessages = pendingMessages.filter { $0.value.deviceID != id }
        record(device: "This Mac", "Unpaired \(device.name)")
        save()
    }

    func refreshAddress() {
        let addresses = Self.localAddresses()
        let ipv4 = addresses.filter { !$0.address.contains(":") }
        let preferred = ipv4.first { $0.interface == "en0" } ?? ipv4.first { $0.interface.hasPrefix("en") } ?? ipv4.first
        addressHost = preferred.map { "\($0.address):\(RemoteAccessPolicy.port)" }
    }

    // MARK: Requests

    func handle(_ request: RemoteHTTPRequest, peer: RemoteAccessServer.Peer) async -> RemoteHTTPResponse {
        let now = Date()
        guard isEnabled, let companion else { return .error(403) }
        guard requestLimiter.allow(peer.key, now: now) else { return .error(429) }
        let token = request.cookies[RemoteAccessPolicy.cookieName]
        let device = RemoteDeviceRegistry.match(token: token, in: devices, now: now)
        let context = RemoteGate.Context(
            sourceAllowed: peer.isAllowed,
            allowedHosts: Self.allowedHosts(),
            deviceTokenValid: device != nil,
            expectedCSRF: device == nil ? nil : token.map(RemoteToken.csrf)
        )
        let route: RemoteRoute
        switch RemoteGate.evaluate(request, context) {
        case .reject(let status): return .error(status)
        case .allow(let allowed): route = allowed
        }
        if route.changesState, route != .pair, !actionLimiter.allow(peer.key, now: now) { return .error(429) }
        if let device { touch(device.id, now: now) }

        switch route {
        case .page: return .text(RemoteAccessPage.html, type: "text/html; charset=utf-8")
        case .script: return .text(RemoteAccessPage.script, type: "text/javascript; charset=utf-8")
        case .style: return .text(RemoteAccessPage.css, type: "text/css; charset=utf-8")
        case .pair: return pair(request, peer: peer, now: now)
        case .state:
            guard let device, let token else { return .error(401) }
            return .json(state(companion, device: device, token: token))
        case .approveProposal, .skipProposal:
            guard let device, let body = decode(IDBody.self, request), let id = UUID(uuidString: body.id) else { return .error(400) }
            return proposal(id, approve: route == .approveProposal, companion: companion, device: device)
        case .answerQuestion:
            guard let device, let body = decode(AnswerBody.self, request), let id = UUID(uuidString: body.id) else { return .error(400) }
            return answer(id, text: body.answer, companion: companion, device: device)
        case .sendMessage:
            guard let device, let body = decode(MessageBody.self, request), let mateID = UUID(uuidString: body.mate) else { return .error(400) }
            return message(mateID, text: body.text, companion: companion, device: device, now: now)
        case .readReply:
            guard let device, let raw = request.query["id"], let id = UUID(uuidString: raw) else { return .error(404) }
            return reply(id, companion: companion, device: device, now: now)
        case .signOut:
            guard let device else { return .error(401) }
            devices.removeAll { $0.id == device.id }
            pendingMessages = pendingMessages.filter { $0.value.deviceID != device.id }
            record(device: device.name, "Unpaired itself")
            save()
            var response = RemoteHTTPResponse.json(["ok": true])
            response.setCookie = RemoteHTTPResponse.clearingCookie
            return response
        }
    }

    private struct IDBody: Decodable { let id: String }
    private struct AnswerBody: Decodable { let id: String; let answer: String }
    private struct MessageBody: Decodable { let mate: String; let text: String }
    private struct PairBody: Decodable { let code: String }

    private func decode<T: Decodable>(_ type: T.Type, _ request: RemoteHTTPRequest) -> T? {
        try? JSONDecoder().decode(type, from: request.body)
    }

    private func pair(_ request: RemoteHTTPRequest, peer: RemoteAccessServer.Peer, now: Date) -> RemoteHTTPResponse {
        guard pairLimiter.allow("pair", now: now), pairLimiter.allow("pair:" + peer.key, now: now) else { return .error(429) }
        guard let body = decode(PairBody.self, request) else { return .error(400) }
        switch pairing.attempt(body.code, now: now) {
        case .paired:
            let token = RemoteToken.make()
            let device = RemoteDevice(id: UUID(),
                name: RemoteDeviceRegistry.label(userAgent: request.header("user-agent"), existing: devices),
                tokenHash: RemoteToken.hash(token), pairedAt: now, lastSeenAt: now)
            devices = RemoteDeviceRegistry.adding(device, to: RemoteDeviceRegistry.pruned(devices, now: now))
            record(device: device.name, "Paired")
            save()
            var response = RemoteHTTPResponse.json(["ok": true])
            response.setCookie = RemoteHTTPResponse.sessionCookie(token: token)
            return response
        case .wrongCode:
            record(device: "Unpaired device", "Tried a wrong pairing code")
            return .error(403)
        case .lockedOut:
            record(device: "Unpaired device", "Pairing locked after too many wrong codes")
            return .error(429)
        case .expired, .noCode:
            return .error(403)
        }
    }

    // MARK: Snapshot

    private func excludedNames(_ companion: CompanionManager) -> [String] {
        let ids = companion.excludedAppBundleIds
        let names = ids.compactMap { id -> String? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return RemoteRedaction.excludedNames(bundleIDs: ids, displayNames: names)
    }

    private func inboxInputs(_ companion: CompanionManager) -> [RemoteInboxInput] {
        let inbox = companion.mateInbox
        let live = Set(companion.mates.filter { !$0.archived }.map(\.id))
        var inputs: [RemoteInboxInput] = inbox.pendingItems.filter { live.contains($0.mateID) }.compactMap { item in
            let source: RemoteInboxSource
            switch item.kind {
            case .question(let prompt, _, let choices): source = .question(prompt: prompt, choices: choices)
            case .signIn(let site, _, _, _): source = .signIn(site: site)
            case .routineFailed(_, let summary): source = .routineFailed(summary: summary)
            case .proposal(let proposal): source = .proposal(title: proposal.title, whyNow: proposal.whyNow)
            case .appliedChange: return nil
            }
            return RemoteInboxInput(id: item.id, mateName: item.mateName, createdAt: item.createdAt, source: source)
        }
        inputs += inbox.work.filter { live.contains($0.mateID) && Self.waitsForPermission($0) }.map {
            RemoteInboxInput(id: $0.id, mateName: $0.mateName, createdAt: $0.updatedAt, source: .waitingForPermission)
        }
        return inputs.sorted { $0.createdAt > $1.createdAt }
    }

    private static func waitsForPermission(_ work: MateInboxWork) -> Bool {
        work.state == .running && work.currentStep?.title == permissionStepTitle
    }

    private func state(_ companion: CompanionManager, device: RemoteDevice, token: String) -> RemoteStatePayload {
        let names = excludedNames(companion)
        let inbox = companion.mateInbox
        let mates = companion.mates.filter { !$0.archived }.map { mate -> RemoteMateEntry in
            let work = inbox.work.filter { $0.mateID == mate.id }.sorted { $0.updatedAt > $1.updatedAt }
            let waiting = inbox.pendingItems(forMate: mate.id).contains { $0.proposal == nil }
                || work.contains { $0.state == .needsInput || Self.waitsForPermission($0) }
            return RemotePayload.mateEntry(RemoteMateInput(id: mate.id, name: mate.name,
                isWorking: companion.isMateBusyForHeartbeat(mate.id), isWaiting: waiting,
                lastLine: work.first { $0.result?.isEmpty == false }?.result), excludedNames: names)
        }
        return RemoteStatePayload(csrf: RemoteToken.csrf(for: token), device: device.name, mates: mates,
            inbox: inboxInputs(companion).map { RemotePayload.inboxEntry($0, excludedNames: names) })
    }

    /// What the phone was shown for this id, so nothing hidden is actionable.
    private func shownEntry(_ id: UUID, companion: CompanionManager) -> RemoteInboxEntry? {
        guard let input = inboxInputs(companion).first(where: { $0.id == id }) else { return nil }
        return RemotePayload.inboxEntry(input, excludedNames: excludedNames(companion))
    }

    // MARK: Actions

    private func proposal(_ id: UUID, approve: Bool, companion: CompanionManager, device: RemoteDevice) -> RemoteHTTPResponse {
        guard let entry = shownEntry(id, companion: companion), entry.kind == "proposal",
              entry.actions.contains(approve ? "approve" : "skip"),
              companion.actOnMateProposal(id: id, action: approve ? .approve : .skip) else { return .error(409) }
        record(device: device.name, "\(approve ? "Approved" : "Skipped") \(entry.mate)'s proposal: \(entry.title)")
        return .json(["ok": true])
    }

    private func answer(_ id: UUID, text: String, companion: CompanionManager, device: RemoteDevice) -> RemoteHTTPResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= RemoteAccessPolicy.maxAnswerCharacters else { return .error(400) }
        guard let entry = shownEntry(id, companion: companion), entry.kind == "question", entry.actions.contains("answer"),
              companion.answerMateInboxItem(id: id, answer: trimmed) else { return .error(409) }
        record(device: device.name, "Answered \(entry.mate)'s question: \(entry.title)")
        return .json(["ok": true])
    }

    private func message(_ mateID: UUID, text: String, companion: CompanionManager, device: RemoteDevice, now: Date) -> RemoteHTTPResponse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= RemoteAccessPolicy.maxMessageCharacters else { return .error(400) }
        guard let mate = companion.mates.first(where: { $0.id == mateID && !$0.archived }) else { return .error(409) }
        let chatID = companion.mateChatForInboxAction(mateID: mateID)
        let known = Set(companion.mateInbox.work.filter { $0.chatID == chatID }.map(\.id))
        guard companion.resumeMateChatInBackground(mateID: mateID, chatID: chatID, userMessage: trimmed, modelPrompt: trimmed) else {
            return .error(409)
        }
        pendingMessages = pendingMessages.filter { now.timeIntervalSince($0.value.sentAt) < 3600 }
        if pendingMessages.count >= 30, let oldest = pendingMessages.min(by: { $0.value.sentAt < $1.value.sentAt })?.key {
            pendingMessages.removeValue(forKey: oldest)
        }
        let id = UUID()
        pendingMessages[id] = PendingMessage(deviceID: device.id, mateID: mateID, chatID: chatID, knownWork: known, sentAt: now)
        record(device: device.name, "Sent a message to \(RemotePayload.mateName(mate.name))")
        return .json(["id": id.uuidString])
    }

    private func reply(_ id: UUID, companion: CompanionManager, device: RemoteDevice, now: Date) -> RemoteHTTPResponse {
        guard let pending = pendingMessages[id], pending.deviceID == device.id else { return .error(404) }
        let status: RemoteReplyStatus
        if let work = companion.mateInbox.work.first(where: { $0.chatID == pending.chatID && !pending.knownWork.contains($0.id) }) {
            switch work.state {
            case .running, .resumed: status = Self.waitsForPermission(work) ? .waitingAtMac : .working
            case .needsInput: status = .needsAnswer
            case .resultReady: status = work.displayState == .failed ? .failed(work.result) : .finished(work.result)
            case .failed, .stopped: status = .failed(work.result)
            }
        } else if companion.mateInboxChatIsBusy(pending.chatID) {
            status = .queued
        } else {
            status = now.timeIntervalSince(pending.sentAt) > 120 ? .failed(nil) : .queued
        }
        return .json(RemotePayload.reply(status, excludedNames: excludedNames(companion)))
    }

    // MARK: Store

    private func touch(_ id: UUID, now: Date) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastSeenAt = now
        if now.timeIntervalSince(lastSeenSaved[id] ?? .distantPast) > 60 {
            lastSeenSaved[id] = now
            save()
        }
    }

    private func record(device: String, _ action: String) {
        log = RemoteAuditEntry.appending(RemoteAuditEntry(id: UUID(), date: Date(), device: device,
            action: String(action.prefix(200))), to: log)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Stored(devices: devices, log: log)) else { return }
        try? DetachedAgentSecureFiles.atomicDurableWrite(data, to: fileURL)
    }

    // MARK: Network facts

    private static func allowedHosts() -> Set<String> {
        let name = SCDynamicStoreCopyLocalHostName(nil) as String?
        return RemoteHostPolicy.allowedHosts(addresses: localAddresses().map(\.address), localHostName: name,
                                             port: RemoteAccessPolicy.port)
    }

    /// Private, non-loopback addresses on interfaces that are up.
    static func localAddresses() -> [(interface: String, address: String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if RemoteAddressPolicy.isAllowedPeer(literal: text) {
                result.append((String(cString: entry.pointee.ifa_name), text))
            }
        }
        return result
    }
}
