import Foundation

/// Host adaptation: scans have hard byte/file/time budgets. When exhausted,
/// reject the whole reading rather than present a partial total as complete.
nonisolated final class CNReadBudget: @unchecked Sendable {
    @TaskLocal static var current: CNReadBudget?
    private var bytes = 0
    private var nodes = 0
    private var exceeded = false
    private let deadline = Date().addingTimeInterval(2)
    var stopped: Bool {
        if Task.isCancelled || Date() > deadline { exceeded = true }
        return exceeded
    }
    static func scan<T>(_ body: () throws -> T) throws -> T {
        let budget = CNReadBudget()
        return try $current.withValue(budget) {
            do {
                let value = try body()
                try Task.checkCancellation()
                guard !budget.stopped else { throw NotchUsageFailure.scanLimit }
                return value
            } catch {
                try Task.checkCancellation()
                if budget.stopped { throw NotchUsageFailure.scanLimit }
                throw error
            }
        }
    }
    static func directory(_ url: URL) throws -> [URL] {
        let manager = FileManager.default
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        // Shallow enumerator streams entries without materializing an unbounded
        // directory listing. Skip package descendants and every symbolic link.
        guard let enumerator = manager.enumerator(at: url,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants]) else { throw CocoaError(.fileReadUnknown) }
        var found: [URL] = []
        while let entry = enumerator.nextObject() as? URL {
            current?.nodes += 1
            if found.count >= 512 || (current?.nodes ?? 0) > 4096 || current?.stopped == true {
                current?.exceeded = true
                throw NotchUsageFailure.scanLimit
            }
            guard (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { continue }
            found.append(entry)
        }
        return found.sorted { $0.path < $1.path }
    }
    static func data(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw NotchUsageFailure.unavailable }
        let size = values.fileSize ?? 0
        guard size <= 8 * 1024 * 1024, (current?.bytes ?? 0) + size <= 32 * 1024 * 1024,
              current?.stopped != true else {
            current?.exceeded = true
            throw NotchUsageFailure.scanLimit
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        current?.bytes += data.count
        guard data.count <= 8 * 1024 * 1024 else {
            current?.exceeded = true
            throw NotchUsageFailure.scanLimit
        }
        return data
    }
    static func text(_ url: URL) throws -> String { String(decoding: try data(url), as: UTF8.self) }
    static func sqlExceeded() { current?.exceeded = true }
}

/// Bounded read-only discovery commands only. Never called with credential
/// arguments and never return raw process output to logging or preferences.
nonisolated enum CNDiscoveryCommand {
    static func run(_ path: String, _ arguments: [String]) -> String {
        guard ["/bin/ps", "/usr/sbin/lsof"].contains(path) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        defer { timeout.cancel() }
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 16 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= 1024 * 1024 else {
                if process.isRunning { process.terminate() }
                return ""
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
