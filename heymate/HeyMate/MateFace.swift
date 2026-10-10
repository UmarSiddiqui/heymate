//
//  MateFace.swift
//  HeyMate
//
//  Simple color faces, plus a smaller illustrated set. HeyMate keeps the
//  lilac one. Every other mate keeps the face that belongs to its id, so a
//  rename does not swap it.
//

import AppKit
import SwiftUI

enum MateFace {
    static let assetNames = [
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

    /// The first six are flat circles. The rest are portraits and should not
    /// be zoomed, or the hair and clips get cut off.
    static func fillsFrame(_ assetName: String) -> Bool {
        guard let index = assetNames.firstIndex(of: assetName) else { return false }
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
        if mate.name == Mate.defaultName { return assetNames[0] }
        return assetNames[index(for: mate.id)]
    }

    static func index(for id: UUID) -> Int {
        let total = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return abs(total) % assetNames.count
    }
}

struct MateFaceView: View {
    let mate: Mate
    var size: CGFloat = 28

    var body: some View {
        faceImage
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size * cropScale, height: size * cropScale)
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                Circle().stroke(DS.Colors.borderSubtle, lineWidth: 0.6)
            }
            .accessibilityHidden(true)
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
