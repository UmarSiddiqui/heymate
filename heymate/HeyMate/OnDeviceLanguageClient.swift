//
//  OnDeviceLanguageClient.swift
//  HeyMate
//
//  Apple Intelligence as a chat brain. It spends no ChatGPT or Claude
//  plan. Only the on-device model is used. The private-cloud model
//  fatal-errors inside FoundationModels when this app has no private-cloud
//  entitlement, which quits HeyMate instead of returning an error.
//  Screenshots stay with the subscription brains — this model is text.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(ImagePlayground)
import ImagePlayground
import SwiftUI
#endif

/// Keeps a Talk turn inside the on-device context window. The window is a
/// few thousand tokens, and the full behavior contract is larger than that.
/// The latest user words stay; older instructions are what get cut.
enum OnDevicePromptFit {
    static let characterBudget = 6_000

    static let instructions = """
    You are HeyMate, a concise companion that lives on this Mac. \
    Answer in plain spoken sentences. You cannot see images or control the computer. \
    If you cannot do something, say so in one sentence.
    """

    static func clip(
        systemPrompt: String,
        userPrompt: String,
        characterBudget: Int = characterBudget
    ) -> (instructions: String, prompt: String) {
        let budget = max(characterBudget, 200)
        let user = String(userPrompt.suffix(budget))
        let separator = "\n\n"
        let roomForContext = budget - user.count - separator.count
        guard roomForContext > 80 else {
            return (instructions, user)
        }
        let context = String(systemPrompt.suffix(roomForContext)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !context.isEmpty else {
            return (instructions, user)
        }
        return (instructions, context + separator + user)
    }
}

enum OnDeviceLanguageError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let explanation):
            return explanation
        }
    }
}

enum OnDeviceLanguageAvailability {
    static var statusLine: String {
        if let explanation = unavailableExplanation {
            return explanation
        }
        return "Apple Intelligence is on. Answers stay on this Mac and do not spend a ChatGPT or Claude plan. It cannot see your screen."
    }

    static var isAvailable: Bool {
        unavailableExplanation == nil
    }

    static var unavailableExplanation: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return explanation(for: SystemLanguageModel.default)
        }
        #endif
        return "Apple Intelligence needs macOS 26 or newer."
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func explanation(for model: SystemLanguageModel) -> String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use On this Mac."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready. Try again in a minute."
        }
    }
    #endif

    static var imagePlaygroundIsAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.1, *) {
            return ImagePlaygroundViewController.isAvailable
        }
        #endif
        return false
    }
}

final class OnDeviceLanguageClient: VisionConversationClient {
    var model: String = "apple-intelligence"

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let started = Date()
        let prompt = Self.composedPrompt(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        let text = try await Self.generate(systemPrompt: systemPrompt, userPrompt: prompt, allowShrink: true)
        await onTextChunk(text)
        return (text, Date().timeIntervalSince(started))
    }

    private static func composedPrompt(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        var parts: [String] = []
        if !images.isEmpty {
            parts.append("Images were attached. You cannot see images. Say that plainly, then answer from the words.")
        }
        if !conversationHistory.isEmpty {
            let history = conversationHistory.map { turn in
                "User: \(turn.userPlaceholder)\nAssistant: \(turn.assistantResponse)"
            }.joined(separator: "\n\n")
            parts.append(history)
        }
        parts.append("User: \(userPrompt)")
        return parts.joined(separator: "\n\n")
    }

    private static func generate(
        systemPrompt: String,
        userPrompt: String,
        allowShrink: Bool
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else {
                throw OnDeviceLanguageError.unavailable(
                    OnDeviceLanguageAvailability.unavailableExplanation
                        ?? "Apple Intelligence isn't available."
                )
            }
            let fitted = OnDevicePromptFit.clip(systemPrompt: systemPrompt, userPrompt: userPrompt)
            let session = LanguageModelSession(model: model, instructions: fitted.instructions)
            do {
                return try await session.respond(
                    to: fitted.prompt,
                    options: GenerationOptions(maximumResponseTokens: 400)
                ).content
            } catch {
                if allowShrink, fitted.prompt.count > 800, Self.isContextOverflow(error) {
                    let shorter = String(fitted.prompt.suffix(fitted.prompt.count / 2))
                    return try await generate(
                        systemPrompt: "",
                        userPrompt: shorter,
                        allowShrink: false
                    )
                }
                throw OnDeviceLanguageError.unavailable(Self.spokenFailure(for: error))
            }
        }
        #endif
        throw OnDeviceLanguageError.unavailable(
            OnDeviceLanguageAvailability.unavailableExplanation
                ?? "Apple Intelligence isn't available."
        )
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("context") && description.contains("exceed")
    }

    private static func spokenFailure(for error: Error) -> String {
        if isContextOverflow(error) {
            return "That was too long for the on-device model. Try a shorter message."
        }
        return "Apple Intelligence couldn't answer that."
    }
}

#if canImport(ImagePlayground)
struct ImagePlaygroundGate: ViewModifier {
    @Binding var concept: String?
    var onComplete: (URL) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.1, *), ImagePlaygroundViewController.isAvailable {
            content.imagePlaygroundSheet(
                isPresented: Binding(
                    get: { concept != nil },
                    set: { isPresented in
                        if !isPresented { concept = nil }
                    }
                ),
                concept: concept ?? ""
            ) { url in
                onComplete(url)
                concept = nil
            }
        } else {
            content
        }
    }
}
#endif
