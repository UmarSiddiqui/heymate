//
//  AgentProcessIdentity.swift
//  leanring-buddy
//
//  PID reuse protection for detached agent runners. A PID is trusted only
//  when its start time, executable, uid, and boot identity still match.
//

import Darwin
import Foundation

nonisolated struct AgentProcessIdentity: Codable, Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
    let uid: UInt32
    let bootSessionID: String
}

nonisolated enum AgentProcessIdentityInspector {
    static func identity(for pid: Int32) -> AgentProcessIdentity? {
        guard pid > 0 else { return nil }

        var processInfo = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let returnedSize = withUnsafeMutablePointer(to: &processInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard returnedSize == expectedSize else { return nil }

        // `PROC_PIDPATHINFO_MAXSIZE` is a C expression Swift cannot import.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = pathBuffer.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathLength > 0 else { return nil }

        return AgentProcessIdentity(
            pid: pid,
            startSeconds: processInfo.pbi_start_tvsec,
            startMicroseconds: processInfo.pbi_start_tvusec,
            executablePath: String(cString: pathBuffer),
            uid: UInt32(processInfo.pbi_uid),
            bootSessionID: bootSessionID()
        )
    }

    static func matchesLiveProcess(_ expected: AgentProcessIdentity) -> Bool {
        guard kill(expected.pid, 0) == 0 || errno == EPERM,
              let current = identity(for: expected.pid) else { return false }
        return current == expected
    }

    private static func bootSessionID() -> String {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = withUnsafeMutablePointer(to: &bootTime) { pointer in
            sysctlbyname("kern.boottime", pointer, &size, nil, 0)
        }
        guard result == 0 else { return "unknown" }
        return "\(bootTime.tv_sec).\(bootTime.tv_usec)"
    }
}
