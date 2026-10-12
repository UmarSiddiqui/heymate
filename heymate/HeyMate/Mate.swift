//
//  Mate.swift
//  HeyMate
//
//  A lasting teammate inside the one chat app. Creating a mate stores this
//  record only — it does not start an agent or spend a model call.
//

import Foundation

nonisolated struct Mate: Equatable, Identifiable {
    let id: UUID
    var name: String
    var job: String
    var pinned: Bool
    var archived: Bool
    var unreadCount: Int
    var createdAt: Date
    var updatedAt: Date
    /// Short durable note for this mate only.
    var memoryNote: String
    /// Set only after the user asks this mate to do file work.
    var folderPath: String?
    /// How this mate sounds and behaves. Empty means no extra personality.
    var soul: String = ""
    /// Chosen picture. Nil keeps the face that belongs to this mate.
    var faceAssetName: String? = nil
    /// Optional color laid over the picture. Nil leaves the art as drawn.
    var faceTint: String? = nil
    /// A small shape at the top of the face: tuft, band, or hood.
    var faceHair: String? = nil
    /// A small shape at the bottom of the face: collar or scarf.
    var faceOutfit: String? = nil
    /// The default mate. Sees the other mates and can hand them work.
    /// Specialists stay false even if they are renamed to the same words.
    var conductsOthers: Bool = false
    /// `AgentBrain` raw value for this mate. Nil keeps the app-wide brain.
    var brainRawValue: String? = nil
    /// Legacy per-agent integration choices. Integrations are global now;
    /// kept only so older files still decode.
    var connectorExclusionIDs: [String]? = nil

    static let defaultName = "HeyMate"
    static let defaultJob = "Talks with you and hands work to your agents"
    /// The stock name and role before the main agent was called HeyMate again.
    static let previousDefaultName = "First Mate"
    static let previousDefaultJob = "The one chat that runs the others"
    static let previousFirstMateSoul = "Calm, precise, and a little warm. You are the personal assistant and the notch companion. You see every other mate and you hand them work instead of pretending you did it yourself."
    static let legacyDefaultName = "HeyMate"
    static let legacyDefaultJob = "General chat"
    static let firstMateSoul = "Calm, precise, and a little warm. You are the personal assistant and the notch companion. You see every other agent and you hand them work instead of pretending you did it yourself."

    static func deletionWarning(replacesWithFreshHeyMate: Bool) -> String {
        var text = "Their chats and routines go away. Files in their folder stay."
        if replacesWithFreshHeyMate {
            text += " A fresh \(defaultName) takes their place."
        }
        return text
    }
}

extension Mate: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, job, pinned, archived, unreadCount, createdAt, updatedAt
        case memoryNote, folderPath, soul, faceAssetName, faceTint, faceHair, faceOutfit
        case conductsOthers, brainRawValue, connectorExclusionIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        job = try container.decode(String.self, forKey: .job)
        pinned = try container.decode(Bool.self, forKey: .pinned)
        archived = try container.decode(Bool.self, forKey: .archived)
        unreadCount = try container.decode(Int.self, forKey: .unreadCount)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        memoryNote = try container.decode(String.self, forKey: .memoryNote)
        folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        soul = try container.decodeIfPresent(String.self, forKey: .soul) ?? ""
        faceAssetName = try container.decodeIfPresent(String.self, forKey: .faceAssetName)
        faceTint = try container.decodeIfPresent(String.self, forKey: .faceTint)
        faceHair = try container.decodeIfPresent(String.self, forKey: .faceHair)
        faceOutfit = try container.decodeIfPresent(String.self, forKey: .faceOutfit)
        conductsOthers = try container.decodeIfPresent(Bool.self, forKey: .conductsOthers) ?? false
        brainRawValue = try container.decodeIfPresent(String.self, forKey: .brainRawValue)
        connectorExclusionIDs = try container.decodeIfPresent([String].self, forKey: .connectorExclusionIDs)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(job, forKey: .job)
        try container.encode(pinned, forKey: .pinned)
        try container.encode(archived, forKey: .archived)
        try container.encode(unreadCount, forKey: .unreadCount)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(memoryNote, forKey: .memoryNote)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encode(soul, forKey: .soul)
        try container.encodeIfPresent(faceAssetName, forKey: .faceAssetName)
        try container.encodeIfPresent(faceTint, forKey: .faceTint)
        try container.encodeIfPresent(faceHair, forKey: .faceHair)
        try container.encodeIfPresent(faceOutfit, forKey: .faceOutfit)
        try container.encode(conductsOthers, forKey: .conductsOthers)
        try container.encodeIfPresent(brainRawValue, forKey: .brainRawValue)
        try container.encodeIfPresent(connectorExclusionIDs, forKey: .connectorExclusionIDs)
    }
}
