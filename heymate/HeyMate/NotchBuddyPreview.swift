#if DEBUG
import AppKit
import SwiftUI

/// Headless snapshots of the collapsed notch with its character, one PNG
/// per state plus a contact sheet. Starts no providers, jobs or windows:
/// `HeyMate --notch-buddy-render <directory>` renders and exits.
@MainActor
enum NotchBuddyPreview {
    /// 14-inch class housing.
    private static let notchWidth: CGFloat = 185
    private static let notchHeight: CGFloat = 32
    private static let mateID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private struct Fixture {
        let name: String
        let label: String
        let frames: Int
        let configure: (NotchPillModel, Clock) -> Date
        var reduceMotion = false
    }

    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static var fixtures: [Fixture] {
        [
            Fixture(name: "idle", label: "Idle", frames: 4) { _, clock in clock.now.addingTimeInterval(1) },
            Fixture(name: "doze", label: "Doze (2 min idle)", frames: 4) { _, clock in
                clock.now.addingTimeInterval(NotchBuddyDirector.dozeAfter + 0.3)
            },
            Fixture(name: "waking", label: "Waking", frames: 4) { model, clock in
                clock.now = clock.now.addingTimeInterval(NotchBuddyDirector.dozeAfter + 5)
                model.buddy.noteUserPresence()
                return clock.now
            },
            Fixture(name: "listening", label: "Listening", frames: 4) { model, clock in
                model.voiceState = .listening
                model.audioPowerLevel = 0.55
                model.buddy.setCompanionState(.listening(.talk))
                return clock.now.addingTimeInterval(0.2)
            },
            Fixture(name: "thinking", label: "Thinking", frames: 4) { model, clock in
                model.voiceState = .processing
                model.buddy.setCompanionState(.thinking)
                return clock.now.addingTimeInterval(0.2)
            },
            Fixture(name: "speaking", label: "Speaking", frames: 4) { model, clock in
                model.voiceState = .responding
                model.buddy.setCompanionState(.speaking)
                return clock.now.addingTimeInterval(0.2)
            },
            Fixture(name: "working-walk", label: "Job: walk", frames: 4) { model, clock in
                working(model, clock, action: "Working on it", entryEvery: nil)
            },
            Fixture(name: "working-run", label: "Job: run", frames: 4) { model, clock in
                working(model, clock, action: "Working on it", entryEvery: 1.5)
            },
            Fixture(name: "working-sprint", label: "Job: sprint", frames: 4) { model, clock in
                working(model, clock, action: "Working on it", entryEvery: 0.4)
            },
            Fixture(name: "working-reading", label: "Job: reading", frames: 4) { model, clock in
                working(model, clock, action: "Reading Package.swift", entryEvery: nil)
            },
            Fixture(name: "working-writing", label: "Job: writing", frames: 4) { model, clock in
                working(model, clock, action: "Editing README.md", entryEvery: 1.5)
            },
            Fixture(name: "working-tool", label: "Job: tool", frames: 4) { model, clock in
                working(model, clock, action: "Running the test suite", entryEvery: nil)
            },
            Fixture(name: "working-web", label: "Job: web", frames: 4) { model, clock in
                working(model, clock, action: "Searching the web for docs", entryEvery: nil)
            },
            Fixture(name: "needs-you", label: "Needs you", frames: 4) { model, clock in
                var run = job(action: "Plan ready")
                run.status = .awaitingPlanApproval
                model.buddy.setRuns([run])
                model.agentFilaments = AgentFilament.live(from: [run])
                return clock.now.addingTimeInterval(0.1)
            },
            Fixture(name: "done", label: "Done", frames: 4) { model, clock in
                finished(model, clock, status: .succeeded)
            },
            Fixture(name: "failed", label: "Failed", frames: 4) { model, clock in
                finished(model, clock, status: .failed)
            },
            Fixture(name: "reduce-motion-working", label: "Reduce Motion", frames: 1, configure: { model, clock in
                working(model, clock, action: "Reading Package.swift", entryEvery: nil)
            }, reduceMotion: true),
        ]
    }

    private static func job(action: String) -> AgentRun {
        var run = AgentRun.queued(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                  title: "Preview job", prompt: "",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/notch-buddy-preview"),
                                  executor: .openCode, origin: .sandbox, createdAt: base)
        run.status = .running
        run.latestAction = action
        run.chatOwner = AgentChatOwner(mateID: mateID, chatID: mateID)
        return run
    }

    /// Feeds a run whose activity arrives every `entryEvery` seconds, so
    /// the pace tracker sees a real rate.
    private static func working(_ model: NotchPillModel, _ clock: Clock, action: String, entryEvery: TimeInterval?) -> Date {
        var run = job(action: action)
        model.buddy.setRuns([run])
        if let entryEvery {
            for _ in 0..<8 {
                clock.now = clock.now.addingTimeInterval(entryEvery)
                run.appendActivity(kind: .progress, text: "step \(run.activity.count)", createdAt: clock.now)
                model.buddy.setRuns([run])
            }
        }
        model.agentFilaments = AgentFilament.live(from: [run])
        return clock.now.addingTimeInterval(0.05)
    }

    private static func finished(_ model: NotchPillModel, _ clock: Clock, status: AgentRunStatus) -> Date {
        var run = job(action: "Working on it")
        model.buddy.setRuns([run])
        clock.now = clock.now.addingTimeInterval(3)
        run.status = status
        model.buddy.setRuns([run])
        return clock.now
    }

    private static func pill(_ fixture: Fixture, frame: Int) -> some View {
        let clock = Clock(base)
        let model = NotchPillModel(buddy: NotchBuddyModel(defaultMateID: mateID, now: { clock.now }))
        model.buddy.setMates([], activeMateID: mateID, defaultMateID: mateID)
        model.hardwareNotchWidth = notchWidth
        model.occludedTopInset = notchHeight
        model.themeColor = Color(hex: "#3B82F6")
        let start = fixture.configure(model, clock)
        let scene = NotchBuddyDirector.scene(model.buddy.context, at: start, still: fixture.reduceMotion)
        let step = 4 / scene.pose.playback.fps
        model.buddy.snapshotDate = start.addingTimeInterval(Double(frame) * step)
        return NotchPillView(model: model)
            .frame(width: notchWidth + NotchLayoutMath.activeWidthBonus + NotchLayoutMath.outlinePad * 2,
                   height: notchHeight + NotchLayoutMath.outlinePad)
            .environment(\.companionMotionSuppressed, fixture.reduceMotion)
    }

    private static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) throws {
        let renderer = ImageRenderer(content: view
            .environment(\.companionSnapshotRendering, true)
            .environment(\.colorScheme, .dark))
        renderer.scale = scale
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    static func render(to directory: String) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for fixture in fixtures {
            try write(pill(fixture, frame: 0).background(Color(white: 0.16)),
                      to: folder.appendingPathComponent("notch-\(fixture.name).png"), scale: 4)
        }
        let sheet = VStack(alignment: .leading, spacing: 10) {
            Text("HeyMate notch character").font(DS.Fonts.title).foregroundStyle(DS.Colors.textPrimary)
            Text("Collapsed notch, 185×32 pt housing, frames spaced 4 apart. Original art drawn in code.")
                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            ForEach(fixtures.indices, id: \.self) { index in
                let fixture = fixtures[index]
                HStack(spacing: 12) {
                    Text(fixture.label).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 110, alignment: .leading)
                    ForEach(0..<fixture.frames, id: \.self) { frame in
                        pill(fixture, frame: frame)
                    }
                }
            }
        }
        .padding(20)
        .background(Color(white: 0.16))
        try write(sheet, to: folder.appendingPathComponent("contact-sheet.png"), scale: 3)
    }
}
#endif
