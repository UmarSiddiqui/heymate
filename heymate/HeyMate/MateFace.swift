//
//  MateFace.swift
//  HeyMate
//
//  Three drawn packs (Signal, Margin, Instrument) sit beside the original
//  color faces and portraits. HeyMate keeps the lilac one. Every other mate
//  keeps the face that belongs to its id, hashed only against the original
//  twenty, so a new pack does not reshuffle anyone.
//

import AppKit
import Combine
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

    static let packs: [MateFacePack] = [
        MateFacePack(
            id: "signal",
            name: "Signal",
            summary: "Night shapes. A cursor, a comet, and an orbit.",
            faces: [
                MateFaceChoice(assetName: "MateFaceSignalPointer", label: "Pointer"),
                MateFaceChoice(assetName: "MateFaceSignalComet", label: "Comet"),
                MateFaceChoice(assetName: "MateFaceSignalOrbit", label: "Orbit")
            ]
        ),
        MateFacePack(
            id: "margin",
            name: "Margin",
            summary: "Paper, wax, and a folded boat.",
            faces: [
                MateFaceChoice(assetName: "MateFaceMarginQuill", label: "Quill"),
                MateFaceChoice(assetName: "MateFaceMarginSeal", label: "Seal"),
                MateFaceChoice(assetName: "MateFaceMarginBoat", label: "Boat")
            ]
        ),
        MateFacePack(
            id: "instrument",
            name: "Instrument",
            summary: "A lens, a bell, and a tuning fork.",
            faces: [
                MateFaceChoice(assetName: "MateFaceInstrumentLens", label: "Lens"),
                MateFaceChoice(assetName: "MateFaceInstrumentBell", label: "Bell"),
                MateFaceChoice(assetName: "MateFaceInstrumentFork", label: "Fork")
            ]
        ),
        MateFacePack(
            id: "original",
            name: "Original",
            summary: "Color circles and the earlier portraits.",
            faces: legacyAssetNames.map { name in
                let raw = name.replacingOccurrences(of: "MateFace", with: "")
                let label = raw.unicodeScalars.reduce(into: "") { result, scalar in
                    if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                        result.append(" ")
                    }
                    result.append(Character(scalar))
                }
                return MateFaceChoice(assetName: name, label: label)
            }
        )
    ]

    static let assetNames: [String] = packs.flatMap { $0.faces.map(\.assetName) }

    static func label(for assetName: String) -> String {
        packs.flatMap(\.faces).first { $0.assetName == assetName }?.label ?? assetName
    }

    /// The first six originals are flat circles. Portraits and the drawn
    /// packs should not be zoomed, or the edges get cut off.
    static func fillsFrame(_ assetName: String) -> Bool {
        guard let index = legacyAssetNames.firstIndex(of: assetName) else { return false }
        return index < 6
    }

    static func storedAssetName(_ raw: String?) -> String? {
        guard let raw, assetNames.contains(raw) else { return nil }
        return raw
    }

    /// A catalog asset, or a `custom:` picture that is still on disk.
    static func persistedName(
        _ raw: String?,
        customFileExists: (String) -> Bool = MateFaceStore.fileExists
    ) -> String? {
        if let asset = storedAssetName(raw) { return asset }
        guard let raw, !MateFaceStore.fileName(in: raw).isEmpty, customFileExists(raw) else { return nil }
        return raw
    }

    static func selectionToken(for mate: Mate) -> String {
        persistedName(mate.faceAssetName) ?? assetName(for: mate)
    }

    static func assetName(for mate: Mate) -> String {
        if let chosen = storedAssetName(mate.faceAssetName) { return chosen }
        if mate.name == Mate.defaultName { return legacyAssetNames[0] }
        return legacyAssetNames[index(for: mate.id)]
    }

    static func index(for id: UUID) -> Int {
        let total = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return abs(total) % legacyAssetNames.count
    }

    static let tintSwatches = ["7C5CFF", "E24B4B", "E8A317", "2F9E8F", "3D7EFF", "F4E4D4"]

    static func storedTint(_ raw: String?) -> String? {
        guard let raw, tintSwatches.contains(raw) else { return nil }
        return raw
    }

    static func storedHair(_ raw: String?) -> String? {
        guard let raw, MateFaceHair(rawValue: raw) != nil, raw != MateFaceHair.none.rawValue else { return nil }
        return raw
    }

    static func storedOutfit(_ raw: String?) -> String? {
        guard let raw, MateFaceOutfit(rawValue: raw) != nil, raw != MateFaceOutfit.none.rawValue else { return nil }
        return raw
    }

    static func color(hex: String?) -> Color? {
        guard let hex, hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func pack(containing assetName: String) -> MateFacePack? {
        packs.first { pack in pack.faces.contains { $0.assetName == assetName } }
    }
}

enum MateFaceHair: String, CaseIterable, Identifiable {
    case none
    case tuft
    case band
    case hood

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .tuft: return "Tuft"
        case .band: return "Band"
        case .hood: return "Hood"
        }
    }
}

enum MateFaceOutfit: String, CaseIterable, Identifiable {
    case none
    case collar
    case scarf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .collar: return "Collar"
        case .scarf: return "Scarf"
        }
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

    static func live(_ state: CompanionState) -> MateFaceExpression {
        switch state {
        case .idle, .error, .guiding:
            return .idle
        case .listening, .finalizingTranscript:
            return .listening
        case .capturingContext, .thinking, .agentRunning:
            return .thinking
        case .speaking, .waitingForApproval:
            return .speaking
        }
    }

    var watchesPointer: Bool {
        switch self {
        case .idle, .listening: return true
        case .still, .thinking, .speaking: return false
        }
    }
}

final class MateFaceGaze: ObservableObject {
    @Published var offset: CGSize = .zero
    var monitor: Any?

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        offset = .zero
    }
}

struct MateFaceView: View {
    let mate: Mate
    var size: CGFloat = 28
    var expression: MateFaceExpression = .still

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var gazeModel = MateFaceGaze()
    @State private var blinkClosed = false
    @State private var pulse = false

    private var animates: Bool { expression != .still && !reduceMotion }
    private var tint: Color? { MateFace.color(hex: mate.faceTint) }
    private var hair: MateFaceHair { MateFaceHair(rawValue: mate.faceHair ?? "") ?? .none }
    private var outfit: MateFaceOutfit { MateFaceOutfit(rawValue: mate.faceOutfit ?? "") ?? .none }

    var body: some View {
        faceImage
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size * cropScale, height: size * cropScale)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay { tintWash }
            .overlay { lid }
            .overlay { hairShape }
            .overlay { outfitShape }
            .scaleEffect(x: 1, y: blinkClosed && animates ? 0.92 : pulseScale)
            .offset(animates && expression.watchesPointer ? gazeModel.offset : .zero)
            .overlay {
                Circle().stroke(ringColor, lineWidth: expression == .still ? 0.6 : 1.4)
            }
            .accessibilityHidden(true)
            .onAppear { startGaze(); startPulse() }
            .onDisappear { stopGaze() }
            .onChange(of: expression) { _, _ in
                startGaze()
                startPulse()
            }
            .task(id: blinkKey) { await blinkLoop() }
    }

    private var blinkKey: String { "\(expression)-\(reduceMotion)" }

    private var pulseScale: CGFloat {
        guard animates, pulse else { return 1 }
        switch expression {
        case .thinking: return 1.05
        case .speaking: return 1.07
        case .listening: return 1.03
        case .idle, .still: return 1
        }
    }

    private var ringColor: Color {
        switch expression {
        case .still, .idle: return DS.Colors.borderSubtle
        case .listening, .speaking: return DS.Colors.accent
        case .thinking: return DS.Colors.warning
        }
    }

    @ViewBuilder private var tintWash: some View {
        if let tint {
            Circle().fill(tint).blendMode(.softLight).opacity(0.9)
        }
    }

    @ViewBuilder private var lid: some View {
        if blinkClosed && animates {
            Capsule()
                .fill(Color.black.opacity(0.55))
                .frame(width: size * 0.62, height: size * 0.08)
                .offset(y: -size * 0.06)
        }
    }

    @ViewBuilder private var hairShape: some View {
        let color = tint ?? Color.white.opacity(0.85)
        switch hair {
        case .none:
            EmptyView()
        case .tuft:
            HStack(spacing: size * 0.04) {
                Capsule().frame(width: size * 0.12, height: size * 0.22)
                Capsule().frame(width: size * 0.12, height: size * 0.28)
            }
            .foregroundStyle(color)
            .offset(y: -size * 0.34)
        case .band:
            Capsule()
                .fill(color)
                .frame(width: size * 0.7, height: size * 0.12)
                .offset(y: -size * 0.22)
        case .hood:
            Circle()
                .trim(from: 0.5, to: 1)
                .stroke(color, lineWidth: size * 0.08)
                .frame(width: size * 0.78, height: size * 0.78)
                .offset(y: -size * 0.08)
        }
    }

    @ViewBuilder private var outfitShape: some View {
        let color = (tint ?? Color.white).opacity(0.9)
        switch outfit {
        case .none:
            EmptyView()
        case .collar:
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: size * 0.46, height: size * 0.16)
                .offset(y: size * 0.38)
        case .scarf:
            Capsule()
                .fill(color)
                .frame(width: size * 0.72, height: size * 0.1)
                .offset(y: size * 0.3)
        }
    }

    private func startPulse() {
        pulse = false
        guard animates, expression == .thinking || expression == .speaking || expression == .listening else { return }
        let duration = expression == .speaking ? 0.28 : 0.7
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    private func blinkLoop() async {
        blinkClosed = false
        guard animates, expression == .idle || expression == .listening else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(expression == .listening ? 2.4 : 3.6))
            if Task.isCancelled { return }
            blinkClosed = true
            try? await Task.sleep(for: .milliseconds(110))
            blinkClosed = false
        }
    }

    private func startGaze() {
        stopGaze()
        guard animates, expression.watchesPointer else { return }
        let travel = min(size * 0.08, 4)
        gazeModel.monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            if let window = event.window ?? NSApp.keyWindow {
                let point = window.mouseLocationOutsideOfEventStream
                let width = max(window.frame.width, 1)
                let height = max(window.frame.height, 1)
                let nx = (point.x / width) - 0.5
                let ny = (point.y / height) - 0.5
                gazeModel.offset = CGSize(width: nx * travel * 2, height: -ny * travel * 2)
            }
            return event
        }
    }

    private func stopGaze() {
        gazeModel.stop()
    }

    private var faceImage: Image {
        if let token = mate.faceAssetName,
           let url = MateFaceStore.fileURL(for: token),
           let picture = NSImage(contentsOf: url) {
            return Image(nsImage: picture)
        }
        return Image(MateFace.assetName(for: mate))
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
