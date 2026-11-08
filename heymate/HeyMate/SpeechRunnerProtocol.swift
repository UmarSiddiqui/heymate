import Foundation
import Darwin

/// Only these fixed categories may leave the speech transport. Server errors
/// can echo the input, paths or environment; never log their raw bodies/stderr.
nonisolated enum SpeechFailureCategory: String, Codable, Sendable {
    case modelMissing = "model_missing"
    case modelInvalid = "model_invalid"
    case voiceInvalid = "voice_invalid"
    case inputInvalid = "input_invalid"
    case memory = "memory"
    case runner = "runner"
    case noAudio = "no_audio"
    case unknown = "unknown"

    static func classify(_ text: String) -> Self {
        let text = text.lowercased()
        if text.contains("voice"), text.contains("not found") { return .voiceInvalid }
        if text.contains("input must" ) || text.contains("input is required") { return .inputInvalid }
        if text.contains("out of memory") || text.contains("insufficient memory") { return .memory }
        if text.contains("no audio") { return .noAudio }
        if text.contains("model"), text.contains("not found") { return .modelMissing }
        if text.contains("no such file") || text.contains("checksum") || text.contains("load tokenizer")
            || text.contains("load config") || text.contains("missing flow_lm") { return .modelInvalid }
        if text.contains("runner") || text.contains("metal") || text.contains("mlx") { return .runner }
        return .unknown
    }
}

/// Private newline-delimited protocol. Audio stays in memory, never on disk.
nonisolated struct SpeechRunnerRequest: Codable, Sendable {
    let operation: String
    var text = ""
    var voice = "af_heart"
    var speed: Float = 1
    var modelDirectory: String?
}

nonisolated struct SpeechRunnerReply: Codable, Sendable {
    var samples: Data?
    var sampleRate: Int?
    var error: String?
    var port: Int?
    var service: SpeechOwnedProcess?
}

/// PID plus kernel start time prevents cleanup from signalling a reused PID.
nonisolated struct SpeechOwnedProcess: Codable, Sendable, Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    static func snapshot(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    func terminate(executable: URL) {
        guard Self.snapshot(pid) == self, getpgid(pid) == pid else { return }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path) == executable.resolvingSymlinksInPath().path else { return }
        kill(-pid, SIGTERM)
    }
}
