//
//  OpenCodeTrainingPolicy.swift
//  HeyMate
//
//  OpenCode Zen's free launch models are the ones that may keep prompts
//  to improve the model. Paid and zero-retention models are left alone.
//  The warning is per model, and it stays until the user sends anyway.
//

import Foundation

enum OpenCodeDataUse: Equatable {
    case mayTrain(detail: String)
    case notFlagged
}

enum OpenCodeTrainingPolicy {
    static func dataUse(providerID: String, modelID: String, modelName: String) -> OpenCodeDataUse {
        let blob = "\(providerID) \(modelID) \(modelName)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if isKnownPrivateFree(blob) { return .notFlagged }
        if let detail = knownTrainingDetail(blob) {
            return .mayTrain(detail: detail)
        }
        if containsFreeToken(blob) {
            return .mayTrain(detail: """
            \(label(modelName: modelName, modelID: modelID)) is marked free. OpenCode's free models are often used to improve the model while they are free. Don't send private or work files unless you mean to.
            """)
        }
        return .notFlagged
    }

    static func modelKey(providerID: String, modelID: String) -> String {
        "\(providerID)/\(modelID)"
    }

    private static func label(modelName: String, modelID: String) -> String {
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? modelID : name
    }

    private static func isKnownPrivateFree(_ blob: String) -> Bool {
        blob.contains("space bunny") || blob.contains("space-bunny") || blob.contains("spacebunny")
    }

    private static func knownTrainingDetail(_ blob: String) -> String? {
        if blob.contains("big pickle") || blob.contains("big-pickle") || blob.contains("bigpickle") {
            return "Big Pickle is free right now, and OpenCode says prompts from this period may be used to improve the model."
        }
        if blob.contains("mimo") && containsFreeToken(blob) {
            return "This MiMo model is in a free period. OpenCode says collected prompts may be used to improve the model."
        }
        if blob.contains("ling") && containsFreeToken(blob) {
            return "This Ling model is in a free period. OpenCode says collected prompts may be used to improve the model."
        }
        if blob.contains("nemotron") && containsFreeToken(blob) {
            return "This Nemotron free endpoint logs the session to improve the product. Don't send personal or confidential data."
        }
        if (blob.contains("muse spark") || blob.contains("muse-spark") || blob.contains("musespark"))
            && (blob.contains("contributor") || containsFreeToken(blob)) {
            return "Muse Spark Contributor Free uses prompts and replies to train future models. That is the deal for the lower price."
        }
        return nil
    }

    private static func containsFreeToken(_ blob: String) -> Bool {
        blob.range(of: #"\bfree\b"#, options: .regularExpression) != nil
    }
}

enum OpenCodeTrainingConsent {
    private static let defaultsKey = "openCodeTrainingAcknowledgedModelKeys"

    static func isAcknowledged(_ modelKey: String, defaults: UserDefaults = .standard) -> Bool {
        acknowledgedKeys(defaults: defaults).contains(modelKey)
    }

    static func acknowledge(_ modelKey: String, defaults: UserDefaults = .standard) {
        var keys = acknowledgedKeys(defaults: defaults)
        keys.insert(modelKey)
        defaults.set(Array(keys).sorted(), forKey: defaultsKey)
    }

    private static func acknowledgedKeys(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }
}

struct OpenCodeTrainingNotice: Equatable {
    var modelKey: String
    var modelLabel: String
    var detail: String
}

struct PendingOpenCodeSend: Equatable {
    var modelKey: String
    var text: String
    var imageAttachmentCount: Int
    var handoff: MateHandoff?
}
