//
//  ChatImageAttachment.swift
//  leanring-buddy
//
//  Ephemeral image input for one chat turn. Model receives bounded JPEG
//  data; chat history keeps only filename, never image bytes.
//

import AppKit
import Foundation
import ImageIO

struct ChatImageAttachment: Identifiable, Equatable, Sendable {
    static let maximumCount = 6
    static let maximumPixelDimension = 2_048

    let id: UUID
    let data: Data
    let fileName: String
    let pixelWidth: Int
    let pixelHeight: Int

    var modelLabel: String {
        "user-attached image \"\(fileName)\" (image dimensions: \(pixelWidth)x\(pixelHeight) pixels; this is an attachment, not a live screen)"
    }

    var thumbnail: NSImage? { NSImage(data: data) }

    static func load(from fileURL: URL) throws -> ChatImageAttachment {
        let didStartAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { fileURL.stopAccessingSecurityScopedResource() }
        }
        return try make(from: Data(contentsOf: fileURL), fileName: fileURL.lastPathComponent)
    }

    static func make(from sourceData: Data, fileName: String) throws -> ChatImageAttachment {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ChatImageAttachmentError.unreadableImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ChatImageAttachmentError.unreadableImage
        }
        guard let jpegData = NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.84]
        ) else {
            throw ChatImageAttachmentError.encodingFailed
        }

        let scale = min(1, CGFloat(maximumPixelDimension) / CGFloat(max(sourceWidth, sourceHeight)))
        return ChatImageAttachment(
            id: UUID(),
            data: jpegData,
            fileName: fileName.isEmpty ? "Pasted image" : fileName,
            pixelWidth: max(1, Int((CGFloat(sourceWidth) * scale).rounded())),
            pixelHeight: max(1, Int((CGFloat(sourceHeight) * scale).rounded()))
        )
    }
}

enum ChatImageAttachmentError: LocalizedError {
    case unreadableImage
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "HeyMate could not read that image."
        case .encodingFailed: return "HeyMate could not prepare that image."
        }
    }
}
