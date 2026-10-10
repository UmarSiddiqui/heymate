//
//  VoiceDictation.swift
//  HeyMate
//
//  Turns a held key or a held composer button into text. Owns the
//  microphone (AVAudioEngine), streams it to the selected speech-to-text
//  engine, falls back to an offline engine when that one can't start, and
//  hands the transcript to whoever started the utterance.
//
//  The microphone opens before the engine is ready: connecting to a cloud
//  engine takes a network round trip, and the first words would otherwise be
//  lost. Audio captured in that gap is queued and replayed into the session.
//

import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreAudio
import Speech

@MainActor
final class VoiceDictation: ObservableObject {
    enum Trigger {
        case holdToTalkButton
        case keyboardShortcut
    }

    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var transcriptionProviderDisplayName: String
    @Published var lastErrorMessage: String?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromButton || isRecordingFromKeyboardShortcut || isFinalizingTranscript
    }

    /// Recognition hints sent with every utterance: names people say to
    /// HeyMate that generic models tend to mishear.
    private static let keyterms = [
        "HeyMate", "Codex", "Claude", "Anthropic", "OpenAI",
        "SwiftUI", "Xcode", "Vercel", "Next.js", "localhost"
    ]
    private static let defaultFinalTranscriptTimeout: TimeInterval = 2.4

    private var provider: any SpeechToTextProvider
    private let audioEngine = AVAudioEngine()
    private var isRecordingFromButton = false
    private var active: Utterance?
    /// Bumped by every start, stop and cancel, so a start still waiting on
    /// permissions can tell it has been overtaken.
    private var startGeneration = 0
    private var finalTranscriptDeadline: Task<Void, Never>?
    private var permissionRequest: Task<Bool, Never>?
    private var lastPermissionRequestEnded: Date?

    init() {
        provider = SpeechToTextProviders.preferred()
        transcriptionProviderDisplayName = provider.displayName
    }

    func useProvider(_ provider: any SpeechToTextProvider) {
        guard !isDictationInProgress else { return }
        self.provider = provider
        transcriptionProviderDisplayName = provider.displayName
        HeyMateLog.log("🎙️ Transcription: switched to \(provider.displayName)")
    }

    // MARK: - Starting and stopping

    /// Hold-to-talk from the chat composer: releasing always submits.
    func beginHoldToTalk(
        existingDraft: String,
        onDraftChange: @escaping (String) -> Void,
        onSubmit: @escaping (String) -> Void
    ) async {
        await begin(.holdToTalkButton, existingDraft: existingDraft, submitsWhenDone: true,
                    onDraftChange: onDraftChange, onSubmit: onSubmit)
    }

    /// A held global shortcut. Submits on release unless the user already
    /// had a draft going, in which case the words are added to the draft.
    func beginShortcutDictation(
        existingDraft: String,
        onDraftChange: @escaping (String) -> Void,
        onSubmit: @escaping (String) -> Void
    ) async {
        let submitsWhenDone = existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        await begin(.keyboardShortcut, existingDraft: existingDraft, submitsWhenDone: submitsWhenDone,
                    onDraftChange: onDraftChange, onSubmit: onSubmit)
    }

    func finishHoldToTalk() { finish(.holdToTalkButton) }
    func finishShortcutDictation() { finish(.keyboardShortcut) }

    /// Stops listening without submitting. With `keepingDraft`, whatever was
    /// heard so far is still written into the draft.
    func cancel(keepingDraft: Bool = true) {
        startGeneration += 1
        guard isDictationInProgress else { return }
        if keepingDraft, let active {
            active.onDraftChange(active.draft)
        }
        endUtterance()
    }

    private func begin(
        _ trigger: Trigger,
        existingDraft: String,
        submitsWhenDone: Bool,
        onDraftChange: @escaping (String) -> Void,
        onSubmit: @escaping (String) -> Void
    ) async {
        guard !isDictationInProgress else { return }
        HeyMateLog.log("🎙️ VoiceDictation: start requested (\(trigger))")

        if needsPermissionPrompt {
            // The system sheet only appears over an active app.
            NSApplication.shared.activate(ignoringOtherApps: true)
            try? await Task.sleep(for: .milliseconds(200))
        }

        startGeneration += 1
        let generation = startGeneration
        lastErrorMessage = nil
        isPreparingToRecord = true

        guard await ensurePermissions() else {
            HeyMateLog.log("🎙️ VoiceDictation: permissions missing or denied")
            isPreparingToRecord = false
            return
        }
        guard !Task.isCancelled, generation == startGeneration else {
            HeyMateLog.log("🎙️ VoiceDictation: start abandoned before recording began")
            isPreparingToRecord = false
            return
        }

        let utterance = Utterance(
            trigger: trigger,
            draftBefore: existingDraft,
            submitsWhenDone: submitsWhenDone,
            onDraftChange: onDraftChange,
            onSubmit: onSubmit
        )
        active = utterance
        isRecordingFromButton = trigger == .holdToTalkButton
        isRecordingFromKeyboardShortcut = trigger == .keyboardShortcut
        currentAudioPowerLevel = 0

        do {
            try await startCapture(for: utterance)
            if active === utterance { isPreparingToRecord = false }
        } catch {
            HeyMateLog.log("❌ VoiceDictation: couldn't start (\(provider.displayName)): \(error)")
            guard active === utterance else { return }
            lastErrorMessage = Self.userFacingMessage(for: error, fallback: "couldn't start voice input. try again.")
            endUtterance()
        }
    }

    private func finish(_ trigger: Trigger) {
        startGeneration += 1
        guard let active, active.trigger == trigger else {
            isPreparingToRecord = false
            return
        }
        guard !isFinalizingTranscript else { return }
        HeyMateLog.log("🎙️ VoiceDictation: stop requested (\(trigger))")

        // Finalizing goes up before recording comes down, so observers never
        // see a moment where neither is true. That gap read as an empty press
        // and dropped the companion to idle while the transcript was coming.
        isFinalizingTranscript = true
        isRecordingFromButton = false
        isRecordingFromKeyboardShortcut = false
        isPreparingToRecord = false
        active.isFinishing = true

        stopMicrophone()
        // A session still connecting is told to finish as soon as it attaches.
        active.session?.finish()

        let timeout = active.session?.finalTranscriptTimeout ?? Self.defaultFinalTranscriptTimeout
        finalTranscriptDeadline?.cancel()
        finalTranscriptDeadline = Task { [weak self, weak active] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, let active, self.active === active else { return }
            self.complete(active)
        }
    }

    // MARK: - Capture

    private func startCapture(for utterance: Utterance) async throws {
        let router = AudioBufferRouter()
        try startMicrophone(feeding: router)

        let session: any LiveTranscriptionSession
        do {
            // Run detached from the caller's task: releasing the key cancels
            // that task, but audio already captured should still be heard.
            session = try await Task { try await self.openSession(for: utterance) }.value
        } catch {
            stopMicrophone()
            throw error
        }

        guard active === utterance else {
            // Cancelled while the engine was connecting.
            session.cancel()
            return
        }
        utterance.session = session
        router.attach(session)
        if utterance.isFinishing { session.finish() }
        HeyMateLog.log("🎙️ VoiceDictation: \(transcriptionProviderDisplayName) ready, queued audio handed over")
    }

    /// Opens the selected engine, or for this one press an offline fallback
    /// when it can't start (offline, bad key, quota). The selection itself
    /// stays put, so the next press tries the chosen engine again.
    private func openSession(for utterance: Utterance) async throws -> any LiveTranscriptionSession {
        do {
            return try await open(provider, for: utterance)
        } catch {
            guard let fallback = SpeechToTextProviders.fallback(after: provider) else { throw error }
            HeyMateLog.log("⚠️ VoiceDictation: \(provider.displayName) failed to start (\(error.localizedDescription)), using \(fallback.displayName)")
            if fallback.needsSpeechRecognitionPermission {
                guard await requestSpeechRecognitionAccess() else { throw error }
            }
            return try await open(fallback, for: utterance)
        }
    }

    private func open(
        _ provider: any SpeechToTextProvider,
        for utterance: Utterance
    ) async throws -> any LiveTranscriptionSession {
        HeyMateLog.log("🎙️ VoiceDictation: opening \(provider.displayName)")
        // Callbacks are tied to this utterance, so a late message from a
        // session that has been replaced or cancelled is ignored.
        let handlers = TranscriptionHandlers(
            onPartial: { [weak self, weak utterance] text in
                Task { @MainActor in
                    guard let self, let utterance, self.active === utterance else { return }
                    utterance.heard = text
                }
            },
            onFinal: { [weak self, weak utterance] text in
                Task { @MainActor in
                    guard let self, let utterance, self.active === utterance else { return }
                    utterance.heard = text
                    if utterance.isFinishing { self.complete(utterance) }
                }
            },
            onError: { [weak self, weak utterance] error in
                Task { @MainActor in
                    guard let self, let utterance, self.active === utterance else { return }
                    self.handleSessionError(error, in: utterance)
                }
            }
        )
        return try await provider.openSession(keyterms: Self.keyterms, handlers: handlers)
    }

    private func startMicrophone(feeding router: AudioBufferRouter) throws {
        let input = audioEngine.inputNode
        // The device has to be chosen before reading the format: switching
        // microphones changes sample rate and channel count, and a tap
        // installed with the old format makes the engine throw.
        selectPreferredInputDevice(on: input)
        let format = input.outputFormat(forBus: 0)
        let meter = AudioLevelMeter { [weak self] level in
            self?.publishAudioLevel(level)
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            router.append(buffer)
            meter.measure(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopMicrophone() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Points capture at the microphone chosen in Settings. Nil means the
    /// system default, which the engine already uses. A failure is logged
    /// and ignored: the default microphone beats no capture at all when the
    /// preferred one has been unplugged.
    private func selectPreferredInputDevice(on input: AVAudioInputNode) {
        guard var deviceID = AudioInputDeviceCatalog.resolvedAudioDeviceID(),
              let audioUnit = input.audioUnit else { return }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            HeyMateLog.log("⚠️ VoiceDictation: couldn't select input device \(deviceID) (status \(status)), using the system default")
        }
    }

    private func publishAudioLevel(_ level: CGFloat) {
        // Rises instantly, falls off smoothly, so the waveform reads as speech.
        let smoothed = max(level, currentAudioPowerLevel * 0.72)
        guard abs(smoothed - currentAudioPowerLevel) > 0.002 else { return }
        currentAudioPowerLevel = smoothed
    }

    // MARK: - Ending

    private func handleSessionError(_ error: Error, in utterance: Utterance) {
        if utterance.isFinishing && !utterance.heardTrimmed.isEmpty {
            complete(utterance)
            return
        }
        HeyMateLog.log("❌ VoiceDictation error (\(transcriptionProviderDisplayName)): \(error)")
        lastErrorMessage = Self.userFacingMessage(for: error, fallback: "couldn't transcribe that. try again.")
        cancel(keepingDraft: false)
    }

    /// Delivers the utterance: submits it when it should, otherwise writes
    /// it into the draft.
    private func complete(_ utterance: Utterance) {
        guard active === utterance else { return }
        let draft = utterance.draft
        let heardSomething = !utterance.heardTrimmed.isEmpty
        endUtterance()

        if utterance.submitsWhenDone {
            if heardSomething { utterance.onSubmit(draft) }
        } else if !draft.isEmpty {
            utterance.onDraftChange(draft)
        }
    }

    private func endUtterance() {
        finalTranscriptDeadline?.cancel()
        finalTranscriptDeadline = nil
        stopMicrophone()
        active?.session?.cancel()
        active = nil
        startGeneration += 1
        isPreparingToRecord = false
        isRecordingFromButton = false
        isRecordingFromKeyboardShortcut = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
    }

    // MARK: - Permissions

    private var needsPermissionPrompt: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            || (provider.needsSpeechRecognitionPermission
                && SFSpeechRecognizer.authorizationStatus() == .notDetermined)
    }

    /// One request at a time: overlapping requests can make macOS show the
    /// sheet twice, so rapid presses all wait on the same one. Right after a
    /// request, macOS can still briefly report "not determined" even though
    /// the user chose, so for a second the cached answer is trusted instead.
    private func ensurePermissions() async -> Bool {
        if let permissionRequest {
            return await permissionRequest.value
        }
        if let lastPermissionRequestEnded, Date().timeIntervalSince(lastPermissionRequestEnded) < 1 {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            return status != .denied && status != .restricted
        }

        let request = Task { await self.requestPermissions() }
        permissionRequest = request
        let granted = await request.value
        permissionRequest = nil
        lastPermissionRequestEnded = Date()
        return granted
    }

    private func requestPermissions() async -> Bool {
        guard await requestMicrophoneAccess() else {
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }
        guard provider.needsSpeechRecognitionPermission else { return true }
        guard await requestSpeechRecognitionAccess() else {
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }
        return true
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func requestSpeechRecognitionAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }

    private static func userFacingMessage(for error: Error, fallback: String) -> String {
        let described = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isGeneric = described.isEmpty || described == "The operation couldn’t be completed."
        return isGeneric ? fallback : described
    }
}

/// One press: who started it, what was already in the draft, and what has
/// been heard so far.
@MainActor
private final class Utterance {
    let trigger: VoiceDictation.Trigger
    let draftBefore: String
    let submitsWhenDone: Bool
    let onDraftChange: (String) -> Void
    let onSubmit: (String) -> Void
    var session: (any LiveTranscriptionSession)?
    var heard = ""
    var isFinishing = false

    init(
        trigger: VoiceDictation.Trigger,
        draftBefore: String,
        submitsWhenDone: Bool,
        onDraftChange: @escaping (String) -> Void,
        onSubmit: @escaping (String) -> Void
    ) {
        self.trigger = trigger
        self.draftBefore = draftBefore
        self.submitsWhenDone = submitsWhenDone
        self.onDraftChange = onDraftChange
        self.onSubmit = onSubmit
    }

    var heardTrimmed: String { heard.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The earlier draft with what was heard appended, one space between.
    var draft: String {
        let heard = heardTrimmed
        guard !heard.isEmpty else { return draftBefore }
        guard !draftBefore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return heard }
        let separator = draftBefore.hasSuffix(" ") || draftBefore.hasSuffix("\n") ? "" : " "
        return draftBefore + separator + heard
    }
}

/// Carries microphone buffers from the audio tap to the transcription
/// session. Until a session is attached, buffers are queued (capped at about
/// ten seconds) so speech from the moment the key went down isn't lost.
private nonisolated final class AudioBufferRouter: @unchecked Sendable {
    private static let maximumQueuedBuffers = 500

    private let lock = NSLock()
    private var session: (any LiveTranscriptionSession)?
    private var queued: [AVAudioPCMBuffer] = []

    /// Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let session {
            lock.unlock()
            session.append(buffer)
            return
        }
        if queued.count < Self.maximumQueuedBuffers {
            queued.append(buffer)
        }
        lock.unlock()
    }

    /// Replays the queue in order, then routes live audio straight through.
    /// The lock isn't held while replaying, so the audio thread never waits
    /// on a conversion; buffers that arrive meanwhile are drained next pass.
    func attach(_ session: any LiveTranscriptionSession) {
        while true {
            lock.lock()
            if queued.isEmpty {
                self.session = session
                lock.unlock()
                return
            }
            let batch = queued
            queued.removeAll(keepingCapacity: true)
            lock.unlock()
            batch.forEach(session.append)
        }
    }
}

/// Microphone loudness for the waveform, measured on the audio thread with
/// vDSP and delivered to the main actor at most once per buffer.
private nonisolated final class AudioLevelMeter: @unchecked Sendable {
    private let deliver: @MainActor (CGFloat) -> Void

    init(deliver: @escaping @MainActor (CGFloat) -> Void) {
        self.deliver = deliver
    }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        let level = CGFloat(min(max(rms * 10.2, 0), 1))
        let deliver = self.deliver
        Task { @MainActor in deliver(level) }
    }
}
