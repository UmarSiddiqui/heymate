import AppKit
import Metal

@main
struct MetalCheck {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = try String(contentsOf: root.appendingPathComponent("HeyMate/DaVinciShaders.txt"), encoding: .utf8)
        let context = try DaVinciMetalContext(source: source)
        let renderer = DaVinciMetalRenderer(context: context)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
        d.storageMode = .shared; d.usage = [.renderTarget, .shaderRead]
        var output = context.device.makeTexture(descriptor: d)!
        let identity: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let mesh: [String: Any] = ["geometry": "triangle", "model": identity, "normal": [1,0,0,0,1,0,0,0,1], "color": [0.1,0.4,0.8], "emissive": [0,0,0], "cut": [0,0,0,0], "bands": [], "roughness": 0.3, "metalness": 0.0, "opacity": 1.0]
        var payload: [String: Any] = ["viewProjection": identity, "eye": [0,0,3], "illustrated": true, "ink": [0.02,0.02,0.02], "meshes": [mesh], "geometries": [["id": "triangle", "positions": [-0.7,-0.7,0,0.7,-0.7,0,0,0.7,0], "normals": [0,0,1,0,0,1,0,0,1], "uvs": [], "colors": [], "indices": []]]]
        func render(_ name: String) throws -> [UInt8] {
            let command = context.queue.makeCommandBuffer()!
            try renderer.encode(payload, into: output, command: command, scale: 1)
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let width = output.width, height = output.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let url = root.appendingPathComponent("../output/metal/\(name).png").standardizedFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(bytes)
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
            return bytes
        }
        let illustrated = try render("illustrated")
        let center = (128 * 256 + 128) * 4
        precondition(illustrated[center + 3] == 255, "Mesh center missing; winding/depth/ABI failure")
        precondition(illustrated[3] == 0, "Background not transparent")
        precondition(illustrated[center] > illustrated[center + 2], "Expected blue surface")
        let inkPixels = stride(from: 0, to: illustrated.count, by: 4).filter {
            illustrated[$0 + 3] > 100 && illustrated[$0] < 60 && illustrated[$0 + 1] < 60 && illustrated[$0 + 2] < 60
        }.count
        precondition(inkPixels > 100, "ID outline pass missing")
        payload["geometries"] = []
        payload["illustrated"] = false
        let physical = try render("physical")
        precondition(physical != illustrated, "Physical and illustrated shader paths identical")
        var transparent = mesh; transparent["opacity"] = 0.4
        payload["meshes"] = [transparent]
        let clear = try render("transparent")
        precondition(clear[center + 3] > 90 && clear[center + 3] < 115, "Transparency blending wrong")
        var cut = mesh; cut["cut"] = [1,0,0,0]
        payload["meshes"] = [cut]
        let clipped = try render("cut")
        precondition(clipped[(128 * 256 + 155) * 4 + 3] == 0, "Color pass ignores cut plane")
        precondition(clipped[(128 * 256 + 100) * 4 + 3] == 255, "Retained cut surface missing")
        // A seam between two parts must shade their shared edge without changing the outside silhouette.
        let positions: [Float] = [-0.7,-0.7,0, 0.7,-0.7,0, 0.7,0.7,0, -0.7,-0.7,0, 0.7,0.7,0, -0.7,0.7,0]
        let normals: [Float] = Array(repeating: [Float(0),0,1], count: 6).flatMap { $0 }
        var joined = mesh; joined["geometry"] = "square"
        payload["meshes"] = [joined]; payload["illustrated"] = true
        payload["geometries"] = [["id":"square", "positions":positions, "normals":normals, "uvs":[], "colors":[], "indices":[]]]
        let seamless = try render("joined")
        var a = mesh, b = mesh; a["geometry"] = "half-a"; b["geometry"] = "half-b"
        payload["meshes"] = [a,b]
        payload["geometries"] = [["id":"half-a", "positions":Array(positions.prefix(9)), "normals":Array(normals.prefix(9)), "uvs":[], "colors":[], "indices":[]],
                                  ["id":"half-b", "positions":Array(positions.suffix(9)), "normals":Array(normals.suffix(9)), "uvs":[], "colors":[], "indices":[]]]
        let seamed = try render("seamed")
        precondition(seamed[center] < seamless[center], "Part-ID seam shading missing")
        precondition(seamed[center + 3] == seamless[center + 3], "Seam changes surface coverage")
        // Reject bad data before submitting GPU commands.
        do {
            try renderer.ingest([["id":"bad", "positions":[0,0,0], "normals":[0,0,1], "uvs":[], "colors":[], "indices":[3,4,5]]])
            preconditionFailure("Out-of-bounds indices accepted")
        } catch NativeMetalError.invalid { }
        if CommandLine.arguments.count > 2 {
            payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
            let gallery = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 768, height: 512, mipmapped: false)
            gallery.storageMode = .shared; gallery.usage = [.renderTarget, .shaderRead]
            output = context.device.makeTexture(descriptor: gallery)!
            _ = try render("gallery-illustrated")
            payload["illustrated"] = false; payload["geometries"] = []
            _ = try render("gallery-physical")
        }
        print("PASS: native Metal pipelines, vertex ABI, projection, illustrated/physical lighting, transparent background, alpha blending, cut coverage, ID outlines/seams and invalid index rejection on \(context.device.name)")
    }
}
