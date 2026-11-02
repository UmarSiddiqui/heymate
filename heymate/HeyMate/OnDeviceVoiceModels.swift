//
//  OnDeviceVoiceModels.swift
//  HeyMate
//
//  The default local voice: Parakeet (NVIDIA, via FluidAudio) listens
//  and Phonon speaks through a private bundled Ollama/MLX service.
//  Speech stays on the Mac; no account or key is needed.
//
//  Parakeet downloads on first launch. Phonon ships inside the signed app
//  and is copied to a writable private store before starting its service.
//

import Combine
import FluidAudio
import Foundation

enum OnDeviceVoiceModelState: Equatable {
    /// This Mac cannot run the model; the string says why.
    case unsupported(String)
    case notInstalled
    /// Fraction in 0...1, or nil while the size is unknown.
    case downloading(Double?)
    case installed
    case failed(String)

    var isInstalled: Bool { self == .installed }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isUnsupported: Bool {
        if case .unsupported = self { return true }
        return false
    }
}

/// Download state for both on-device models, shared by onboarding and
/// Settings so a download started in one shows progress in the other.
@MainActor
final class OnDeviceVoiceModelStore: ObservableObject {
    static let shared = OnDeviceVoiceModelStore()

    /// Rough one-time download, shown before the user commits to it.
    static let approximateDownloadSizeDescription = "about 500 MB for listening; speaking is included"

    @Published private(set) var listenState: OnDeviceVoiceModelState = .notInstalled
    @Published private(set) var speakState: OnDeviceVoiceModelState = .notInstalled

    /// Called when a download finishes so selected local models can warm up.
    var onModelInstalled: ((OnDeviceVoiceModelKind) -> Void)?

    private init() {
        refreshInstalledState()
    }

    var isDownloading: Bool {
        listenState.isDownloading || speakState.isDownloading
    }

    /// True when everything this Mac can run is on disk.
    var isEverythingInstalled: Bool {
        (listenState.isInstalled || listenState.isUnsupported)
            && (speakState.isInstalled || speakState.isUnsupported)
            && !(listenState.isUnsupported && speakState.isUnsupported)
    }

    var isSupportedOnThisMac: Bool {
        !listenState.isUnsupported || !speakState.isUnsupported
    }

    /// Overall progress across both models, for a single bar.
    var combinedProgress: Double? {
        let parts = [listenState, speakState].filter { !$0.isUnsupported }
        guard !parts.isEmpty else { return nil }
        var total = 0.0
        for part in parts {
            switch part {
            case .installed: total += 1
            case .downloading(let fraction):
                guard let fraction else { return nil }
                total += fraction
            default: break
            }
        }
        return total / Double(parts.count)
    }

    var lastFailureMessage: String? {
        for state in [listenState, speakState] {
            if case .failed(let message) = state { return message }
        }
        return nil
    }

    func refreshInstalledState() {
        if !listenState.isDownloading {
            if let reason = ParakeetEngine.unsupportedReason {
                listenState = .unsupported(reason)
            } else {
                listenState = ParakeetEngine.modelsAreInstalled() ? .installed : .notInstalled
            }
        }
        if !speakState.isDownloading {
            if let reason = PhononEngine.unsupportedReason {
                speakState = .unsupported(reason)
            } else {
                speakState = PhononEngine.modelsAreInstalled() ? .installed : .notInstalled
            }
        }
    }

    /// Downloads whatever is missing, listen model first because it is the
    /// one push-to-talk needs.
    func downloadAll() async {
        await downloadListenModel()
        await downloadSpeakModel()
    }

    func downloadListenModel() async {
        switch listenState {
        case .notInstalled, .failed: break
        default: return
        }
        listenState = .downloading(0)
        do {
            try await ParakeetEngine.shared.downloadAndLoad { fraction in
                Task { @MainActor in
                    let store = OnDeviceVoiceModelStore.shared
                    // FluidAudio reports 0→1 per file and phase, so only
                    // ever move the bar forward.
                    if case .downloading(let current) = store.listenState {
                        let clampedFraction = min(max(fraction, 0), 1)
                        store.listenState = .downloading(max(current ?? 0, clampedFraction))
                    }
                }
            }
            listenState = .installed
            onModelInstalled?(.listen)
        } catch {
            HeyMateLog.log("❌ On-device listen model download failed: \(error)")
            listenState = .failed("Couldn't download the listening model. Check your connection and try again.")
        }
    }

    func downloadSpeakModel() async {
        switch speakState {
        case .notInstalled, .failed: break
        default: return
        }
        // Prepare the bundled speaking model in its private writable store.
        speakState = .downloading(nil)
        do {
            try await PhononEngine.shared.prepare()
            speakState = .installed
            onModelInstalled?(.speak)
        } catch {
            HeyMateLog.log("❌ On-device speak model download failed: \(error)")
            speakState = .failed("Couldn't prepare the speaking model. Try again.")
        }
    }

    /// Deletes both models from disk. Callers switch Listen and Speak away
    /// from on-device first.
    func removeAll() async {
        guard !isDownloading else { return }
        await ParakeetEngine.shared.removeFromDisk()
        await PhononEngine.shared.removeFromDisk()
        refreshInstalledState()
    }
}

enum OnDeviceVoiceModelKind {
    case listen
    case speak
}

// MARK: - Parakeet

/// Loads Parakeet TDT 0.6B v3 once and transcribes whole utterances with it.
/// v3 covers 25 European languages at roughly 120× real time on Apple
/// Silicon, so re-running it on the growing utterance is cheap enough to
/// drive live partials.
actor ParakeetEngine {
    static let shared = ParakeetEngine()

    private static let modelVersion: AsrModelVersion = .v3

    private var asrManager: AsrManager?

    nonisolated static var unsupportedReason: String? {
        #if arch(arm64)
        return nil
        #else
        return "On-device voice needs an Apple Silicon Mac."
        #endif
    }

    nonisolated static func modelsAreInstalled() -> Bool {
        guard unsupportedReason == nil else { return false }
        return AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: modelVersion),
            version: modelVersion
        )
    }

    var isLoaded: Bool { asrManager != nil }

    func downloadAndLoad(progress: @escaping @Sendable (Double) -> Void) async throws {
        let models = try await AsrModels.downloadAndLoad(
            version: Self.modelVersion,
            progressHandler: { downloadProgress in
                progress(downloadProgress.fractionCompleted)
            }
        )
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
    }

    /// Loads from disk only. Never downloads behind the user's back — a
    /// missing model is an error the caller turns into a fallback.
    func loadIfNeeded() async throws -> AsrManager {
        if let asrManager { return asrManager }
        guard Self.modelsAreInstalled() else {
            throw OnDeviceVoiceError.modelNotDownloaded
        }
        let models = try await AsrModels.downloadAndLoad(version: Self.modelVersion)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
        return manager
    }

    /// 16 kHz mono samples in, text out.
    func transcribe(_ samples: [Float]) async throws -> String {
        let manager = try await loadIfNeeded()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeFromDisk() async {
        await asrManager?.cleanup()
        asrManager = nil
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: Self.modelVersion))
    }
}

// MARK: - Kokoro

/// Loads Kokoro 82M once and synthesizes speech with it.
actor KokoroEngine {
    static let shared = KokoroEngine()

    /// American English, warm and clear. Kokoro's own default.
    static let defaultVoice = "af_heart"

    nonisolated static let installedMarkerKey = "onDeviceKokoroModelsInstalled"

    private let speechProcess = KokoroSpeechProcess()
    private var isPrepared = false
    private var retryAfter: Date?
    private var isSynthesizing = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated static var unsupportedReason: String? {
        #if arch(arm64)
        Self.unsupportedReason(for: ProcessInfo.processInfo.operatingSystemVersion)
        #else
        return "On-device voice needs an Apple Silicon Mac."
        #endif
    }

    /// Keep the known macOS 26.4–26.5 exclusion. On other systems, inference
    /// runs in a helper: even FluidAudio 0.18.0 traps on real replies on
    /// macOS 27.0.1. A helper failure falls back to system speech in the GUI.
    nonisolated static func unsupportedReason(for version: OperatingSystemVersion) -> String? {
        if version.majorVersion == 26, (4...5).contains(version.minorVersion) {
            return "On-device speaking needs macOS 26.6 or later."
        }
        return nil
    }

    /// FluidAudio's TTS cache on macOS. Kokoro has no public "is it on disk"
    /// check, so a marker written after a successful load stands in, and the
    /// folder must still exist.
    nonisolated static var cacheRootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
    }

    nonisolated static func modelsAreInstalled() -> Bool {
        guard unsupportedReason == nil,
              UserDefaults.standard.bool(forKey: installedMarkerKey) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: cacheRootURL.path)) ?? []
        return contents.contains { $0.hasPrefix("kokoro") }
    }

    /// Downloads on first call, then loads from disk.
    func prepare() async throws {
        await waitForTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        if let reason = Self.unsupportedReason { throw OnDeviceVoiceError.unsupported(reason) }
        guard !isPrepared else { return }
        try checkRetryWindow()
        do {
            _ = try await speechProcess.request(SpeechRunnerRequest(operation: "prepare"), timeout: .seconds(600))
            isPrepared = true
            UserDefaults.standard.set(true, forKey: Self.installedMarkerKey)
        } catch {
            await recordFailure(error)
            throw error
        }
    }

    /// Text in, 24 kHz mono float samples out.
    /// One synthesis at a time. An actor lets a second call in while the
    /// first awaits Core ML. Warm-up, interrupted replies and voice previews
    /// must not run the same model concurrently. Loading and deletion share
    /// this gate too, so cleanup cannot race a load or synthesis.
    func synthesize(_ text: String) async throws -> (samples: [Float], sampleRate: Int) {
        await waitForTurn()
        defer { endTurn() }
        try Task.checkCancellation()
        if let reason = Self.unsupportedReason { throw OnDeviceVoiceError.unsupported(reason) }
        guard Self.modelsAreInstalled() else { throw OnDeviceVoiceError.modelNotDownloaded }
        try checkRetryWindow()
        do {
            let result = try await speechProcess.request(SpeechRunnerRequest(
                // Legacy benchmark path retains its own voice namespace.
                operation: "synthesize", text: text, voice: Self.defaultVoice,
                speed: Float(SpeechStylePreferences.speed)))
            guard let data = result.samples, !data.isEmpty,
                  data.count % MemoryLayout<Float>.size == 0, result.sampleRate == 24_000 else {
                throw KokoroSpeechProcess.Failure.invalidReply
            }
            let samples = data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: MemoryLayout<Float>.size).map {
                    bytes.loadUnaligned(fromByteOffset: $0, as: Float.self)
                }
            }
            guard samples.allSatisfy({ $0.isFinite }) else { throw KokoroSpeechProcess.Failure.invalidReply }
            isPrepared = true
            return (samples, 24_000)
        } catch {
            await recordFailure(error)
            throw error
        }
    }

    private func checkRetryWindow() throws {
        if let retryAfter, retryAfter > Date() { throw KokoroSpeechProcess.Failure.unavailable }
    }

    private func recordFailure(_ error: Error) async {
        isPrepared = false
        await speechProcess.stop()
        // Avoid a fresh native crash for every sentence in the same reply.
        if !(error is CancellationError) { retryAfter = Date().addingTimeInterval(60) }
    }

    private func waitForTurn() async {
        guard isSynthesizing else {
            isSynthesizing = true
            return
        }
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    private func endTurn() {
        if turnWaiters.isEmpty {
            isSynthesizing = false
        } else {
            turnWaiters.removeFirst().resume()
        }
    }

    func removeFromDisk() async {
        await waitForTurn()
        defer { endTurn() }
        await speechProcess.stop()
        isPrepared = false
        retryAfter = nil
        UserDefaults.standard.set(false, forKey: Self.installedMarkerKey)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: Self.cacheRootURL.path)) ?? []
        for entry in contents where entry.hasPrefix("kokoro") {
            try? FileManager.default.removeItem(at: Self.cacheRootURL.appendingPathComponent(entry))
        }
    }
}

enum OnDeviceVoiceError: LocalizedError {
    case modelNotDownloaded
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The on-device voice isn't downloaded yet."
        case .unsupported(let reason):
            return reason
        }
    }
}
