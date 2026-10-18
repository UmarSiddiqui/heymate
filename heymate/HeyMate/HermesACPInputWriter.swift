import Darwin
import Dispatch
import Foundation

/// Bounded serial stdin writes off the main actor. The descriptor is never
/// closed from another queue while a write may still use it.
nonisolated final class HermesACPInputWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "heymate.hermes-acp.stdin", qos: .userInitiated)
    private let lock = NSLock()
    private let onFailure: @Sendable () -> Void
    private var stopped = false
    private var pendingBytes = 0
    private static let maximumPendingBytes = 8 * 1_024 * 1_024 + 1

    init(descriptor: Int32, onFailure: @escaping @Sendable () -> Void) throws {
        self.descriptor = descriptor
        self.onFailure = onFailure
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit { Darwin.close(descriptor) }

    func enqueue(_ data: Data) -> Bool {
        var framed = data
        framed.append(0x0A)
        lock.lock()
        guard !stopped, framed.count <= Self.maximumPendingBytes - pendingBytes else {
            lock.unlock(); return false
        }
        pendingBytes += framed.count
        lock.unlock()
        queue.async { [self, framed] in
            let success = write(framed)
            lock.lock()
            pendingBytes -= framed.count
            let shouldReport = !success && !stopped
            if !success { stopped = true }
            lock.unlock()
            if shouldReport { onFailure() }
        }
        return true
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func write(_ data: Data) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                lock.lock(); let cancelled = stopped; lock.unlock()
                guard !cancelled, ContinuousClock.now < deadline else { return false }
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written == -1, errno == EINTR { continue }
                guard written == -1, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let status = poll(&ready, 1, 50)
                if status < 0, errno != EINTR { return false }
                if ready.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
            }
            return true
        }
    }
}
