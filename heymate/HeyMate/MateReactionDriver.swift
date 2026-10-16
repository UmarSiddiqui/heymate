import Combine
import SwiftUI

/// Plays reactions on one face: events from outside (a finished job) wait in
/// the inbox while the face is hidden, clicks play straight away.
@MainActor
final class MateReactionDriver: ObservableObject {
    @Published private(set) var active: MateFaceReaction?
    @Published private(set) var startedAt = Date()
    private var inbox = MateReactionInbox()
    private var endTask: Task<Void, Never>?

    func offer(_ event: MateReactionEvent?, isVisible: Bool, allowed: Bool) {
        guard let event else { return }
        guard inbox.offer(event, at: Date()) else { return }
        deliver(isVisible: isVisible, allowed: allowed)
    }

    /// Call when visibility or the motion policy changes.
    func deliver(isVisible: Bool, allowed: Bool) {
        guard allowed else { inbox.clear(); return }
        if let reaction = inbox.take(isVisible: isVisible, at: Date()) { play(reaction) }
    }

    func play(_ reaction: MateFaceReaction) {
        endTask?.cancel()
        active = reaction
        startedAt = Date()
        endTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(reaction.duration))
            guard !Task.isCancelled else { return }
            self?.active = nil
        }
    }

    func stop() {
        endTask?.cancel()
        endTask = nil
        active = nil
        inbox.clear()
    }

    func pose(at date: Date) -> MateReactionPose {
        MateReactionPose.sample(active, elapsed: date.timeIntervalSince(startedAt))
    }
}

extension View {
    /// Applies a reaction's whole-face motion: squash, hop, shake and tilt.
    func mateReactionTransform(_ pose: MateReactionPose, size: CGFloat) -> some View {
        scaleEffect(x: pose.squashX, y: pose.squashY, anchor: .bottom)
            .rotationEffect(.degrees(pose.tilt))
            .offset(x: pose.shake * size, y: pose.lift * size)
    }

    /// Click to say hello. Taps pass through to any enclosing button.
    func mateReactionTaps(enabled: Bool, size: CGFloat, driver: MateReactionDriver, greeting: MateFaceReaction = .wink) -> some View {
        simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { _ in
                guard enabled else { return }
                driver.play(.giggle)
            }
            .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                guard enabled else { return }
                let reaction = MateFaceReaction.forTap(count: 1, normalizedY: value.location.y / max(size, 1))
                driver.play(reaction == .wink ? greeting : reaction)
            })
        )
    }
}
