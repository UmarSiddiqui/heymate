//
//  AppleSpeechTranscriptionProvider.swift
//  HeyMate
//
//  Apple's Speech framework: always installed, works offline when the Mac
//  has an on-device model for the language, and needs the Speech
//  Recognition permission. The last-resort engine when others can't start.
//

import AVFoundation
import Foundation
import Speech

struct AppleSpeechTranscriptionProvider: SpeechToTextProvider {
    let displayName = "Apple Speech"
    let needsSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func openSession(
        keyterms: [String],
        handlers: TranscriptionHandlers
    ) async throws -> any LiveTranscriptionSession {
        let recognizer = SFSpeechRecognizer(locale: .autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
        guard let recognizer else {
            throw SpeechToTextError(message: "dictation is not available on this mac.")
        }
        return AppleSpeechSession(recognizer: recognizer, keyterms: keyterms, handlers: handlers)
    }
}

private nonisolated final class AppleSpeechSession: LiveTranscriptionSession, @unchecked Sendable {
    let finalTranscriptTimeout: TimeInterval = 1.8

    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let handlers: TranscriptionHandlers
    private var task: SFSpeechRecognitionTask?

    /// Guards the three fields below; the audio thread and Speech's callback
    /// queue both touch them.
    private let lock = NSLock()
    private var latestText = ""
    private var isFinishing = false
    private var hasDeliveredFinal = false

    init(recognizer: SFSpeechRecognizer, keyterms: [String], handlers: TranscriptionHandlers) {
        self.handlers = handlers
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Names the user is likely to say (mates, apps, products) are much
        // more often heard right when Speech is told about them up front.
        request.contextualStrings = keyterms
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    deinit { task?.cancel() }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !lock.withLock({ isFinishing }) else { return }
        request.append(buffer)
    }

    func finish() {
        let shouldEnd = lock.withLock { () -> Bool in
            defer { isFinishing = true }
            return !isFinishing
        }
        if shouldEnd { request.endAudio() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            lock.withLock { latestText = text }
            handlers.onPartial(text)
            if result.isFinal {
                deliverFinal(text)
                return
            }
        }
        guard let error else { return }

        // Speech often reports an error after endAudio() even though it
        // already heard everything; what it heard is still the answer.
        let (finishing, text) = lock.withLock { (isFinishing, latestText) }
        if finishing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deliverFinal(text)
        } else {
            handlers.onError(error)
        }
    }

    private func deliverFinal(_ text: String) {
        let isFirst = lock.withLock { () -> Bool in
            defer { hasDeliveredFinal = true }
            return !hasDeliveredFinal
        }
        if isFirst { handlers.onFinal(text) }
    }
}
