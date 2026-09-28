import AppKit
import ImageIO
import Testing
@testable import HeyMate

struct ChatImageAttachmentTests {
    @Test func imageIsConvertedToBoundedJPEGWithUsefulLabel() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 3_000,
            pixelsHigh: 1_500,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let sourceData = try #require(bitmap.representation(using: .png, properties: [:]))

        let attachment = try ChatImageAttachment.make(from: sourceData, fileName: "wide.png")

        #expect(attachment.pixelWidth == 2_048)
        #expect(attachment.pixelHeight == 1_024)
        #expect(attachment.data.starts(with: [0xFF, 0xD8]))
        #expect(attachment.modelLabel.contains("wide.png"))
        #expect(attachment.modelLabel.contains("not a live screen"))
    }

    @Test func nonImageDataIsRejected() {
        #expect(throws: ChatImageAttachmentError.self) {
            _ = try ChatImageAttachment.make(from: Data("not an image".utf8), fileName: "bad.txt")
        }
    }
}
