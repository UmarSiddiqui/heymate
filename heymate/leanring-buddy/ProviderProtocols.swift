//
//  ProviderProtocols.swift
//  leanring-buddy
//
//  Provider-neutral seams for the AI services so backends can be swapped
//  without touching CompanionManager. These mirror the surfaces of the
//  shipping implementations (ClaudeAPI, ElevenLabsTTSClient). The STT seam
//  already exists as BuddyTranscriptionProvider + BuddyStreamingTranscriptionSession
//  with three interchangeable conformers, so it stays as the canonical
//  StreamingSTTClient boundary.
//
//  Structured action deltas (AssistantRequest/AssistantDelta with separated
//  spoken text and tool calls) are intentionally deferred until structured
//  visual actions land; these protocols cover today's proven call shapes.
//

import Foundation

/// Streaming vision/model conversation client.
///
/// Conformed to by ClaudeAPI (via the Cloudflare Worker proxy). Any future
/// provider (OpenAI, Gemini, local models) implements this protocol and can
/// be injected into CompanionManager without other changes.
protocol VisionConversationClient: AnyObject {
    /// The model identifier used for requests (e.g. "claude-sonnet-4-6").
    var model: String { get set }

    /// Sends a vision request with streaming. Calls `onTextChunk` on the main
    /// actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when done.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

/// Text-to-speech client.
///
/// Conformed to by ElevenLabsTTSClient. Implementations must be cancellable
/// immediately from any state (Talk re-press interrupts playback).
@MainActor
protocol TTSClient: AnyObject {
    /// Speaks `text` aloud. Throws on network or decoding errors.
    /// Cancellation-safe. Returns once playback has started.
    func speakText(_ text: String) async throws

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool { get }

    /// Stops any in-progress playback immediately.
    func stopPlayback()
}

/// One tool the model may call mid-turn, in the shape Anthropic's Messages
/// API expects: a name, a description, and a JSON Schema object describing
/// its arguments. Kept provider-neutral so `TalkToolCatalog` does not need
/// to know which conversation client ends up using it.
struct AssistantToolDefinition: Sendable {
    let name: String
    let description: String
    /// Raw JSON Schema object, e.g. `{"type":"object","properties":{...},"required":[...]}`.
    let inputSchemaJSON: String
}

/// One call the model asked for while streaming a response. `inputArgumentsJSON`
/// is the raw JSON object text the model produced for the tool's arguments.
struct AssistantToolCall: Sendable {
    let toolUseIdentifier: String
    let toolName: String
    let inputArgumentsJSON: String
}

/// Conformed to by conversation clients that can run a full tool-use turn:
/// stream text, pause when the model asks for a tool, hand the call to
/// `onToolCallRequested`, feed the result back, and continue until the model
/// produces a final answer with no further tool calls.
///
/// Only `ClaudeAPI` conforms today. The subscription CLI and OpenCode
/// backends already run their own tool loops server-side (or have none at
/// all for a scratch Talk session), so they stay on the plain
/// `VisionConversationClient` path and never advertise tools to the model.
protocol ToolCallingConversationClient: VisionConversationClient {
    /// Same shape as `analyzeImageStreaming`, plus the tools the model may
    /// call and a handler that executes one and returns its result text.
    /// `onToolCallRequested` never throws — a failed or denied call becomes
    /// a `(text, isError: true)` result the model sees like any other tool
    /// outcome, so it can explain the failure in its next spoken sentence
    /// instead of the whole turn silently erroring out.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        availableTools: [AssistantToolDefinition],
        onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolCallRequested: @MainActor @Sendable (AssistantToolCall) async -> (text: String, isError: Bool)
    ) async throws -> (text: String, duration: TimeInterval)
}
