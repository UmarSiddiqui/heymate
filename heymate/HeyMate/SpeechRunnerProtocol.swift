import Foundation
import Darwin

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
