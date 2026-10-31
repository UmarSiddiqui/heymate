import Foundation

/// A real, cancellable dwell interval rather than an indefinite loading state.
nonisolated struct NotchOpenCue: Equatable {
    enum Kind: Equatable { case hover, click }
    let id = UUID()
    let kind: Kind
    let startedAt: Date
    let duration: TimeInterval

    init(kind: Kind, startedAt: Date = Date(), duration: TimeInterval) {
        self.kind = kind
        self.startedAt = startedAt
        self.duration = max(duration, 0)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(date.timeIntervalSince(startedAt) / duration, 0), 1)
    }

    func remaining(at date: Date) -> TimeInterval {
        max(duration - max(date.timeIntervalSince(startedAt), 0), 0)
    }
}
