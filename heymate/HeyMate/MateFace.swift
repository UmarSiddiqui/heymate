//
//  MateFace.swift
//  HeyMate
//
//  Milo, Nova, and Blobatar are the visible built-in character packs. Retired tokens
//  migrate to Milo without changing mate identity or custom photographs.
//

import AppKit
import SwiftUI

struct MateFaceChoice: Equatable, Identifiable {
    var id: String { assetName }
    let assetName: String
    let label: String
}

struct MateFacePack: Equatable, Identifiable {
    let id: String
    let name: String
    let summary: String
    let faces: [MateFaceChoice]
}

enum MateFace {
    /// Faces that existed before the drawn packs. Id assignment stays inside
    /// this list so adding art does not change a mate who never picked one.
    static let legacyAssetNames = [
        "MateFaceLilac",
        "MateFacePeach",
        "MateFaceSky",
        "MateFaceButter",
        "MateFaceMint",
        "MateFaceBlush",
        "MateFaceIndigo",
        "MateFaceStar",
        "MateFaceCrescent",
        "MateFaceCoral",
        "MateFaceCloud",
        "MateFaceAmber",
        "MateFaceCuteGuy",
        "MateFaceCuteGirl",
        "MateFaceAnimeGuy",
        "MateFaceAnimeGirl",
        "MateFaceStyledGuy",
        "MateFaceStyledGirl",
        "MateFaceRobot",
        "MateFaceOrb"
    ]

    /// Compatibility inventory for saved profiles and older internal callers.
    /// These assets are not selectable in the character catalog.
    static let retiredAssetNames = Set(legacyAssetNames + [
        "MateFaceSignalPointer", "MateFaceSignalComet", "MateFaceSignalOrbit",
        "MateFaceMarginQuill", "MateFaceMarginSeal", "MateFaceMarginBoat",
        "MateFaceInstrumentLens", "MateFaceInstrumentBell", "MateFaceInstrumentFork"
    ])

    static let packs: [MateFacePack] = [
        MateFacePack(
            id: "milo",
            name: "Milo",
            summary: "An original companion. Choose hair, skin, eyes, and outfit.",
            faces: MiloLook.allLooks.filter { $0.characterPack == .milo }
                .map { MateFaceChoice(assetName: $0.assetName, label: $0.label) }
        ),
        MateFacePack(
            id: "nova",
            name: "Nova",
            summary: "An original feminine companion. Choose hair, skin, eyes, and outfit.",
            faces: MiloLook.allLooks.filter { $0.characterPack == .nova }
                .map { MateFaceChoice(assetName: $0.assetName, label: $0.label) }
        ),
        BlobatarCharacter.pack
    ]

    /// Only a known retired built-in changes. Custom tokens and every other
    /// saved field remain untouched, including photographs temporarily offline.
    static func migratedBuiltInName(_ raw: String?) -> String? {
        guard let raw, retiredAssetNames.contains(raw) else { return raw }
        return MiloLook.defaultLook.assetName
    }

    static let assetNames: [String] = packs.flatMap { $0.faces.map(\.assetName) }

    static func label(for assetName: String) -> String {
        if BlobatarCharacter.contains(assetName) {
            return BlobatarCharacter.faces.first { $0.assetName == assetName }?.label ?? "Your Blobatar"
        }
        if let look = MiloLook(assetName: assetName) { return look.label }
        return packs.flatMap(\.faces).first { $0.assetName == assetName }?.label ?? assetName
    }

    /// The first six originals are flat circles. Portraits and the drawn
    /// packs should not be zoomed, or the edges get cut off.
    static func fillsFrame(_ assetName: String) -> Bool {
        guard let index = legacyAssetNames.firstIndex(of: assetName) else { return false }
        return index < 6
    }

    static func storedAssetName(_ raw: String?) -> String? {
        guard let migrated = migratedBuiltInName(raw),
              MiloLook(assetName: migrated) != nil || BlobatarCharacter.contains(migrated) else { return nil }
        return migrated
    }

    /// A catalog asset or valid custom photo token. Missing photo files use a
    /// display fallback without erasing the user's saved selection.
    static func persistedName(
        _ raw: String?,
        customFileExists _: (String) -> Bool = MateFaceStore.fileExists
    ) -> String? {
        if let asset = storedAssetName(raw) { return asset }
        guard let raw, !MateFaceStore.fileName(in: raw).isEmpty else { return nil }
        return raw
    }

    static func selectionToken(for mate: Mate) -> String {
        persistedName(mate.faceAssetName) ?? assetName(for: mate)
    }

    static func assetName(for mate: Mate) -> String {
        if let chosen = storedAssetName(mate.faceAssetName) { return chosen }
        return MiloLook.defaultLook.assetName
    }

    static func index(for id: UUID) -> Int {
        let total = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return abs(total) % legacyAssetNames.count
    }

    static func pack(containing assetName: String) -> MateFacePack? {
        if BlobatarCharacter.contains(assetName) { return BlobatarCharacter.pack }
        if let look = MiloLook(assetName: assetName) {
            return packs.first { $0.id == look.characterPack.rawValue.lowercased() }
        }
        return packs.first { pack in pack.faces.contains { $0.assetName == assetName } }
    }
}

/// How a live face behaves. `.still` is the rail and any face that is not
/// the one you are talking to.
enum MateFaceExpression: Equatable {
    case still
    case idle
    case listening
    case thinking
    case speaking
    case attention
    case success
    case failure
    case guiding
    /// Agent work, from the job's latest progress line.
    case reading
    case writing
    case tooling
    case browsing

    static func live(_ state: CompanionState) -> MateFaceExpression {
        switch state {
        case .idle: return .idle
        case .error: return .failure
        case .guiding: return .guiding
        case .listening, .finalizingTranscript:
            return .listening
        case .capturingContext, .thinking, .agentRunning:
            return .thinking
        case .speaking: return .speaking
        case .waitingForApproval: return .attention
        }
    }

    static func agent(_ status: AgentRunStatus) -> Self {
        switch status {
        case .queued: return .idle
        case .planning, .running: return .thinking
        case .awaitingPlanApproval, .waitingForApproval: return .attention
        case .succeeded: return .success
        case .failed: return .failure
        case .cancelled: return .still
        }
    }

    /// Like `agent(_:)`, but a running job shows what it is doing.
    static func agent(_ run: AgentRun) -> Self {
        guard run.status == .running else { return agent(run.status) }
        return MateWorkActivity.expression(for: run.latestAction)
    }

    /// Any of the agent-work looks, which animate like thinking.
    var isWorking: Bool {
        switch self {
        case .thinking, .reading, .writing, .tooling, .browsing: return true
        default: return false
        }
    }
}

/// Live catalog faces retain their original art; thumbnails and custom photos stay still.
struct MateFaceView: View {
    let mate: Mate
    var size: CGFloat = 28
    var expression: MateFaceExpression = .still
    /// A reaction to play once, such as a finished job.
    var reactionEvent: MateReactionEvent? = nil
    /// Clicking the face makes it react.
    var interactive = false

    var body: some View {
        Group {
            if BlobatarCharacter.contains(MateFace.selectionToken(for: mate)) {
                BlobatarLiveView(mate: mate, token: MateFace.selectionToken(for: mate), size: size,
                                 expression: expression, reactionEvent: reactionEvent, interactive: interactive)
            } else if let look = MiloLook(assetName: MateFace.selectionToken(for: mate)) {
                // Editor assets are transparent head portraits, not full-body renders.
                MiloPortraitGazeView(look: look)
                    .frame(width: size, height: size)
                    .background(DS.Colors.accent.opacity(0.08), in: Circle())
                    .clipShape(Circle())
            } else if expression != .still, size >= 28,
               mate.faceAssetName.flatMap(MateFaceStore.fileURL) == nil {
                if MateFace.fillsFrame(MateFace.assetName(for: mate)) {
                    MateLiveFace(assetName: MateFace.assetName(for: mate), size: size, expression: expression,
                                 reactionEvent: reactionEvent, interactive: interactive)
                } else {
                    MateArtworkMotionView(image: faceImage, assetName: MateFace.assetName(for: mate),
                                          size: size, expression: expression,
                                          reactionEvent: reactionEvent, interactive: interactive)
                }
            } else {
                faceImage
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size * cropScale, height: size * cropScale)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
            .overlay {
                if !BlobatarCharacter.contains(MateFace.selectionToken(for: mate)) {
                    Circle().stroke(ringColor, lineWidth: expression == .still ? 0.6 : 1.4)
                }
            }
            .accessibilityHidden(true)
    }

    private var ringColor: Color {
        switch expression {
        case .still, .idle: return DS.Colors.borderSubtle
        case .listening, .speaking: return DS.Colors.accent
        case .thinking, .attention, .reading, .writing, .tooling, .browsing: return DS.Colors.warning
        case .success: return DS.Colors.success
        case .failure: return DS.Colors.destructiveText
        case .guiding: return DS.Colors.info
        }
    }

    private var faceImage: Image {
        if let token = mate.faceAssetName,
           let url = MateFaceStore.fileURL(for: token),
           let picture = NSImage(contentsOf: url) {
            return Image(nsImage: picture)
        }
        let token = MateFace.assetName(for: mate)
        return Image(MiloLook(assetName: token)?.headAssetName ?? BlobatarCharacter.artwork(for: token, expression: expression))
    }

    private var cropScale: CGFloat {
        guard mate.faceAssetName.flatMap(MateFaceStore.fileURL) == nil else { return 1 }
        return MateFace.fillsFrame(MateFace.assetName(for: mate)) ? 1.16 : 1
    }
}

enum MateFaceStore {
    static let customPrefix = "custom:"

    static func fileName(in token: String) -> String {
        guard token.hasPrefix(customPrefix) else { return "" }
        let name = String(token.dropFirst(customPrefix.count))
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains("\\"),
              name != ".",
              name != "..",
              !name.hasPrefix("."),
              name.lowercased().hasSuffix(".png") else { return "" }
        return name
    }

    static func facesDirectory() -> URL {
        let applicationSupport = HeyMateDataDirectory.applicationSupportURL
        let directory = applicationSupport
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("faces", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fileURL(for token: String) -> URL? {
        let name = fileName(in: token)
        guard !name.isEmpty else { return nil }
        return facesDirectory().appendingPathComponent(name)
    }

    static func fileExists(_ token: String) -> Bool {
        guard let url = fileURL(for: token) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func importImage(from url: URL) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url),
              let png = squarePNG(from: image, side: 512) else { return nil }
        let name = "\(UUID().uuidString).png"
        let destination = facesDirectory().appendingPathComponent(name)
        do {
            try png.write(to: destination, options: .atomic)
            return customPrefix + name
        } catch {
            return nil
        }
    }

    static func deleteIfCustom(_ token: String?) {
        guard let token, let url = fileURL(for: token) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func squarePNG(from image: NSImage, side: CGFloat) -> Data? {
        let pixels = Int(side)
        guard pixels > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let source = image.size
        let scale = max(side / max(source.width, 1), side / max(source.height, 1))
        let drawSize = NSSize(width: source.width * scale, height: source.height * scale)
        let origin = NSPoint(x: (side - drawSize.width) / 2, y: (side - drawSize.height) / 2)
        image.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
