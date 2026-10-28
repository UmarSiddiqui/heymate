//
//  ExplainerParserTests.swift
//  HeyMateTests
//
//  A reply's drawing program: what it says, and whether it only points.
//

import AppKit
import Foundation
import Testing
@testable import HeyMate

struct ExplainerParserTests {
    @Test func pointingOnlyProgramIsRecognised() {
        let program = """
        step(1); say("open the color inspector (top right).")
        target(1084, 30, 32, 24, 'color inspector')
        step(2); say('then the wheels')
        hover(10, 10, 20, 20, 'wheels')
        """
        #expect(ExplainerParser.onlyPoints(program))
        #expect(ExplainerParser.sayLines(in: program) == ["open the color inspector (top right).", "then the wheels"])
    }

    @Test func drawingProgramIsNotPointingOnly() {
        #expect(!ExplainerParser.onlyPoints("step(1); say('look'); ring(1, 2, 3, 4, 'x'); target(1, 2, 3, 4, 'y')"))
        #expect(!ExplainerParser.onlyPoints("step(1); say('just words')"))
    }
}

struct ExplainerScreenshotTests {
    @MainActor @Test func pixelTransportPreservesTopLeftOrderAndChannels() throws {
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                               0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let script = ExplainerWindowController.screenshotScript(png, canvas: CGSize(width: 2, height: 2))
        #expect(script.contains("width: 2, height: 2"))
        #expect(script.replacingOccurrences(of: "\\/", with: "/").contains(Data(pixels).base64EncodedString()))
    }

    @MainActor @Test func unusableCaptureClearsEarlierPixels() throws {
        #expect(ExplainerWindowController.screenshotScript(nil, canvas: CGSize(width: 2, height: 2)) == "HeyMateCanvas.screenSampling.clear()")
        #expect(ExplainerWindowController.screenshotScript(Data("invalid".utf8), canvas: CGSize(width: 2, height: 2)) == "HeyMateCanvas.screenSampling.clear()")
    }
}

struct AnnotationAccuracyTests {
    @Test func textBoundsUseScreenshotPixelsWithTopLeftOrigin() {
        let box = ScreenCapture.annotationPixelRect(
            CGRect(x: 0.25, y: 0.6, width: 0.125, height: 0.1),
            imageSize: CGSize(width: 1280, height: 800))
        #expect(abs(box.minX - 320) <= 1)
        #expect(abs(box.minY - 240) <= 1)
        #expect(abs(box.maxX - 480) <= 1)
        #expect(abs(box.maxY - 320) <= 1)
    }

    @MainActor @Test func changedCaptureDimensionsRequireFreshCanvas() {
        let display = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let current = CGSize(width: 1280, height: 720)
        #expect(ExplainerWindowController.canReuseCanvas(current: current, requested: current, frame: display))
        #expect(!ExplainerWindowController.canReuseCanvas(
            current: current, requested: CGSize(width: 1280, height: 845), frame: display))
        #expect(!ExplainerWindowController.canReuseCanvas(current: current, requested: nil, frame: display))
    }

    @MainActor @Test func recognitionSuppliesMeasuredDraftBounds() async throws {
        let image = NSImage(size: CGSize(width: 640, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        ("if re writing" as NSString).draw(at: CGPoint(x: 40, y: 80), withAttributes: [
            .font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let data = try #require(image.tiffRepresentation)
        let snapshot = ScreenSnapshot(imageData: data, label: "test screen", isCursorScreen: true,
            displayWidthInPoints: 1280, displayHeightInPoints: 480,
            displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 480),
            screenshotWidthInPixels: 640, screenshotHeightInPixels: 240)
        let label = await ScreenCapture.annotationLabel(for: snapshot)
        #expect(label.contains("<screen-text-boxes>"))
        #expect(label.contains("if re writing"))
        let row = try #require(label.split(separator: "\n").first { $0.contains("if re writing") })
        let geometry = try #require(row.split(separator: "]").first)
        let values = geometry.dropFirst().split(separator: ",").compactMap { Int($0) }
        #expect(values.count == 4)
        if values.count == 4 {
            #expect((35...50).contains(values[0]))
            #expect((125...150).contains(values[1]))
            #expect(values[2] > 100 && values[2] < 200)
            #expect(values[3] > 15 && values[3] < 40)
        }
    }

    @Test func missingTextRecognitionRetainsImageDimensions() async {
        let snapshot = ScreenSnapshot(imageData: Data(), label: "test screen", isCursorScreen: true,
            displayWidthInPoints: 2560, displayHeightInPoints: 1600,
            displayFrame: CGRect(x: 0, y: 0, width: 2560, height: 1600),
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 800)
        #expect(await ScreenCapture.annotationLabel(for: snapshot) == "test screen (image dimensions: 1280x800 pixels)")
    }
}
