import CryptoKit
import Foundation
import Security

enum PhonePilotError: LocalizedError {
    case invalidInvite, invalidResponse, secureStorage, notEnrolled, conflict, unavailable

    var errorDescription: String? {
        switch self {
        case .invalidInvite: "This pairing code is invalid, expired, or belongs to another account."
        case .invalidResponse: "HeyMate could not verify the reply."
        case .secureStorage: "HeyMate could not save the pairing in Keychain."
        case .notEnrolled: "This account doesn’t have access to the iPhone pilot."
        case .conflict: "The task has already changed. Refresh and try again."
        case .unavailable: "Could not reach the pilot. Check your connection and try again."
        }
    }
}

struct PhonePilotInvite: Codable {
    let uid: String
    let pairID: UUID
    let expiresAt: Date
    let secret: Data
    let publicKey: Data

    var code: String { (try? JSONEncoder().encode(self).base64EncodedString()) ?? "" }

    init(uid: String, secret: Data, publicKey: Data) {
        self.uid = uid
        self.pairID = UUID()
        self.expiresAt = .now.addingTimeInterval(300)
        self.secret = secret
        self.publicKey = publicKey
    }

    static func decode(_ code: String, uid: String, now: Date = .now) throws -> Self {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.utf8.count <= 1024, let data = Data(base64Encoded: cleaned),
              let invite = try? JSONDecoder().decode(Self.self, from: data),
              invite.uid == uid, invite.secret.count == 32, invite.publicKey.count == 32,
              invite.expiresAt > now, invite.expiresAt.timeIntervalSince(now) <= 305 else {
            throw PhonePilotError.invalidInvite
        }
        return invite
    }

    func key(privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data) throws -> Data {
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret,
            sharedInfo: Data("HeyMate pilot v1 \(uid) \(pairID.uuidString)".utf8), outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }
}

struct PhonePilotRequest: Codable {
    enum Kind: String, Codable {
        case pair, unreadMail, mates, message, workspace, chats, transcript, newChat, stopReply
        case saveProfile, createMate, routines, saveRoutine, routineAction, answer, continueOnMac
    }
    let kind: Kind
    var phonePublicKey: Data? = nil
    var mateID: UUID? = nil
    var message: String? = nil
    var chatID: UUID? = nil
    var itemID: UUID? = nil
    var before: UUID? = nil
    var profile: PhoneMateProfile? = nil
    var schedule: String? = nil
    var action: PhoneRoutineAction? = nil
    var startsNewChat: Bool? = nil
    var followsTranscript: Bool? = nil
    var brain: PhoneBrainChoice? = nil
    var attachments: [PhoneAttachment]? = nil
    var activityPush: PhoneLiveActivityTarget? = nil

    static let messageLimit = 1_600
}

struct PhonePilotMate: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let job: String
    let canCheckMail: Bool
    let acceptsMessages: Bool
    var isMain: Bool? = nil
    var face: String? = nil
}

struct PhonePilotReply: Codable {
    let text: String
    var mateName: String? = nil
    var mates: [PhonePilotMate]? = nil
    var nextMateID: UUID? = nil
    var workspace: PhoneWorkspace? = nil
    var chats: [PhoneChat]? = nil
    var thread: PhoneThread? = nil
    var routines: [PhoneRoutine]? = nil
    var profile: PhoneMateProfile? = nil
}

struct PhoneWorkspace: Codable, Equatable {
    let sharing: Bool
    let mainMateID: UUID?
    let questions: [PhoneQuestion]
    let theme: String?
    var brains: [PhoneBrainOption]? = nil
    var supportsAttachments: Bool? = nil
    var supportsActivityPush: Bool? = nil
    var supportsStopReply: Bool? = nil
}

struct PhoneQuestion: Codable, Equatable, Identifiable {
    let id: UUID
    let mateName: String
    let chatID: UUID
    let text: String
    let choices: [String]
}

struct PhoneChat: Codable, Hashable, Identifiable {
    let id: UUID
    let mateID: UUID
    let title: String
    let updatedAt: Date
    let busy: Bool
    var turnID: UUID? = nil
}

struct PhoneChatMessage: Codable, Equatable, Identifiable {
    let id: UUID
    let user: Bool
    let text: String
    let time: Date
    var attachmentNames: [String]? = nil
}

struct PhoneThread: Codable, Equatable {
    let chat: PhoneChat
    var messages: [PhoneChatMessage]
    var older: Bool
    var appendsOlder = false
}

struct PhoneMateProfile: Codable, Equatable {
    var name: String
    var job: String
    var personality: String
    var face: String?
    var brain: String?
    var memory: String? = nil
    var editsMemory = false

    static let faces: [(name: String, id: String)] = [
        ("Milo", "MiloFutureIdle"), ("Lilac", "Nova-sweep-lilac-umber-amber"),
        ("Copper", "Nova-crop-copper-caramel-amber-future"), ("Tide", "Nova-crop-tide-sand-sea")
    ]
}

enum PhoneRoutineAction: String, Codable { case pause, resume, run }

struct PhoneRoutine: Codable, Equatable, Identifiable {
    let id: UUID
    let mateID: UUID
    let task: String
    let schedule: String
    let scheduleLabel: String
    let next: Date
    let enabled: Bool
    let lastResult: String?
}

struct PhoneBrainChoice: Codable, Equatable {
    let provider: String
    var model: String?
    var effort: String?
}

struct PhoneBrainOption: Codable, Equatable, Identifiable {
    struct Model: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let efforts: [String]
    }

    let id: String
    let name: String
    let models: [Model]
}

struct PhoneLiveActivityTarget: Codable {
    enum Environment: String, Codable { case sandbox, production }

    let token: Data
    let environment: Environment
    var supportsStoppedStage: Bool? = nil

    var hasValidToken: Bool { (16...256).contains(token.count) }
}

struct PhoneAttachment: Codable {
    static let chunkSize = 512 * 1024
    static let maximumBytes = 25 * 1024 * 1024
    static let maximumCount = 6
    static let uploadBatchSize = 8

    let name: String
    let size: Int
    let chunks: [UUID]

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 180 && name != "." && name != ".."
            && name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)) == nil
    }

    static func validate(_ list: [Self]) -> Bool {
        guard list.count <= maximumCount else { return false }
        var total = 0
        var ids = Set<UUID>()
        for file in list {
            guard validName(file.name), file.size > 0, file.size <= maximumBytes,
                  file.chunks.count == (file.size + chunkSize - 1) / chunkSize,
                  file.chunks.allSatisfy({ ids.insert($0).inserted }) else { return false }
            total += file.size
        }
        return total <= maximumBytes
    }
}

struct PhonePilotChannel: Codable, Equatable {
    let uid: String
    let pairID: UUID
    let key: Data

    enum Direction: String { case pairingRequest, request, result, attachment }

    private func context(_ id: UUID, _ direction: Direction) -> Data {
        Data("HeyMate pilot v1 \(uid) \(pairID.uuidString) \(id.uuidString) \(direction.rawValue)".utf8)
    }

    func seal<T: Encodable>(_ value: T, taskID: UUID, direction: Direction) throws -> Data {
        let encoder = JSONEncoder()
        if direction == .attachment { encoder.outputFormatting = .withoutEscapingSlashes }
        let sealed = try ChaChaPoly.seal(encoder.encode(value),
            using: SymmetricKey(data: key), authenticating: context(taskID, direction))
        return sealed.combined
    }

    func open<T: Decodable>(_ type: T.Type, data: Data, taskID: UUID, direction: Direction) throws -> T {
        let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data),
            using: SymmetricKey(data: key), authenticating: context(taskID, direction))
        return try JSONDecoder().decode(type, from: plaintext)
    }
}

struct PhonePilotKeychain<Value: Codable> {
    let account: String

    private var query: [String: Any] {
        var attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.heymate.phone-pilot.v1", kSecAttrAccount as String: account]
        #if os(macOS)
        attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        #endif
        return attributes
    }

    func load() throws -> Value? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PhonePilotError.secureStorage }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let valueData = try JSONEncoder().encode(value)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: valueData] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PhonePilotError.secureStorage }
        var attributes = query
        #if os(macOS)
        attributes.removeValue(forKey: kSecUseAuthenticationUI as String)
        #else
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        attributes[kSecValueData as String] = valueData
        attributes[kSecAttrSynchronizable as String] = false
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw PhonePilotError.secureStorage
        }
    }

    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PhonePilotError.secureStorage }
    }
}
