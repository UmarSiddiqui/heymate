//
//  ChatImagePasteTests.swift
//  HeyMateTests
//

import AppKit
import Testing
@testable import HeyMate

struct ChatImagePasteTests {

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("heymate-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func aScreenshotOnTheClipboardIsAttached() throws {
        let pasteboard = makePasteboard()
        let data = pngData()
        pasteboard.setData(data, forType: .png)
        #expect(ChatImagePaste.content(of: pasteboard) == .imageData(data))
        let attachment = try ChatImageAttachment.make(from: data, fileName: "Pasted image")
        #expect(attachment.pixelWidth == 4)
    }

    @Test func plainTextIsLeftToTheTextField() {
        let pasteboard = makePasteboard()
        pasteboard.setString("hello", forType: .string)
        #expect(ChatImagePaste.content(of: pasteboard) == nil)
    }

    @Test func textThatAlsoCarriesAnImageStaysText() {
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("a paragraph from Pages", forType: .string)
        pasteboard.setData(pngData(), forType: .png)
        #expect(ChatImagePaste.content(of: pasteboard) == nil)
    }

    @Test func copiedImageFilesAreAttachedEvenThoughFinderAddsTheirNames() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("shot.png")
        try pngData().write(to: imageURL)
        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: textURL)

        let pasteboard = makePasteboard()
        pasteboard.writeObjects([imageURL as NSURL, textURL as NSURL])
        #expect(ChatImagePaste.content(of: pasteboard) == .files([imageURL]))
    }
}
