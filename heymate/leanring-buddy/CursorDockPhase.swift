//
//  CursorDockPhase.swift
//  leanring-buddy
//
//  Pure state for rocket-launcher deployment. CompanionManager owns phase;
//  overlay views only animate transitions and report completion.
//

import CoreGraphics
import Foundation

nonisolated enum CursorDockPhase: Equatable {
    case docked
    case launching
    case deployed
    case returning

    var isTransitioning: Bool {
        self == .launching || self == .returning
    }

    var acceptsDeploymentToggle: Bool {
        !isTransitioning
    }
}

nonisolated enum CursorDockStateMachine {
    static func initialPhase(isEnabled: Bool) -> CursorDockPhase {
        isEnabled ? .deployed : .docked
    }

    static func phaseWhenRequesting(
        enabled: Bool,
        overlayIsVisible: Bool
    ) -> CursorDockPhase {
        if enabled {
            return .launching
        }
        return overlayIsVisible ? .returning : .docked
    }

    static func completedPhase(after phase: CursorDockPhase) -> CursorDockPhase {
        switch phase {
        case .launching:
            return .deployed
        case .returning:
            return .docked
        case .docked, .deployed:
            return phase
        }
    }
}

nonisolated enum CursorDockGeometry {
    /// Converts footer dock center from global AppKit coordinates into one
    /// overlay window's top-left local coordinate space. Coordinates may sit
    /// outside this screen so one shared flight can cross display boundaries.
    static func launchBayPosition(
        screenFrame: CGRect,
        dockAnchorScreenPoint: CGPoint?
    ) -> CGPoint {
        guard let dockAnchorScreenPoint else {
            return CGPoint(x: screenFrame.width / 2, y: 12)
        }

        return CGPoint(
            x: dockAnchorScreenPoint.x - screenFrame.minX,
            y: screenFrame.maxY - dockAnchorScreenPoint.y
        )
    }
}
