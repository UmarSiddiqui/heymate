import AppKit
import Metal

// Draws frame payloads (from models.mjs) with the app's Metal renderer, offscreen, and writes one PNG each over a
// plain backdrop: what a figure floating on a light window would look like.
// Usage: render <heymate-root> <out-dir> <payload.json>...
@main
struct MetalRender {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let source = try String(contentsOf: root.appendingPathComponent("HeyMate/DaVinciShaders.txt"), encoding: .utf8)
        let context = try DaVinciMetalContext(source: source)
        for path in CommandLine.arguments.dropFirst(3) {
            let url = URL(fileURLWithPath: path)
            let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let rect = (payload["rect"] as? [NSNumber])?.map(\.doubleValue) ?? [0, 0, 620, 520]
            let scale = 2.0, width = Int(rect[2] * scale), height = Int(rect[3] * scale)
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
            let output = context.device.makeTexture(descriptor: d)!
            let renderer = DaVinciMetalRenderer(context: context)
            let command = context.queue.makeCommandBuffer()!
            try renderer.encode(payload, into: output, command: command, scale: Float(scale))
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            canvas.setFillColor(CGColor(srgbRed: 0.93, green: 0.935, blue: 0.95, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let name = url.deletingPathExtension().lastPathComponent + ".png"
            try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
            print("rendered", name)
        }
    }
}
