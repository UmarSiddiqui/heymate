//
//  ResearchBriefPDFDocument.swift
//  HeyMate
//
//  A small, printable PDF representation of a saved research conversation.
//

import AppKit
import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ResearchBriefPDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    var text: String
    private var existingPDFData: Data?

    init(text: String) {
        self.text = text
        existingPDFData = nil
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = ""
        existingPDFData = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try existingPDFData ?? Self.makePDF(from: text))
    }

    private static func makePDF(from text: String) throws -> Data {
        let pdfData = NSMutableData()
        var pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(
                consumer: consumer,
                mediaBox: &pageBounds,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let content = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.black
            ]
        )
        let frameSetter = CTFramesetterCreateWithAttributedString(content)
        let pageTextBounds = CGRect(x: 54, y: 54, width: 504, height: 684)
        var location = 0

        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: pageTextBounds, transform: nil)
            let frame = CTFramesetterCreateFrame(
                frameSetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            guard visibleRange.length > 0 else {
                context.endPDFPage()
                break
            }
            location += visibleRange.length
            context.endPDFPage()
        } while location < content.length

        context.closePDF()
        return pdfData as Data
    }
}
