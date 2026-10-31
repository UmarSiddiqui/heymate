import AppKit
import MetalKit
import simd

/// Native GPU host for HeyMate's 3D shaders (DaVinciShaders.txt, the same file as scripts/native-shaders/davinci.metal).
/// Scene math remains in the drawing VM.
@MainActor
final class DaVinciMetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let solid: MTLRenderPipelineState
    let clear: MTLRenderPipelineState
    let ids: MTLRenderPipelineState
    let ink: MTLRenderPipelineState
    let writeDepth: MTLDepthStencilState
    let readDepth: MTLDepthStencilState
    let neighbours: MTLBuffer
    let neighbourCount: UInt32
    let samples: Int

    init(source: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NativeMetalError.invalid("Metal device unavailable")
        }
        self.device = device; self.queue = queue
        samples = device.supportsTextureSampleCount(4) ? 4 : 1
        // Color and ID passes must clip the same surfaces: the colour pass adds cut-away coverage and a hatched interior.
        let adapter = """
        fragment float4 heymate_surface(VertexOut in [[stage_in]], bool front [[front_facing]],
             constant FrameUniforms &frame [[buffer(1)]], constant ObjectUniforms &object [[buffer(2)]]) {
            bool cut = dot(object.cut.xyz, object.cut.xyz) > 0.25;
            if (cut && dot(in.worldPosition, object.cut.xyz) > object.cut.w) discard_fragment();
            float4 color = mate_shade(in, front, frame, object);
            if (cut && !front && object.flags.z < 0.5) {
                float hatch = smoothstep(0.35, 0.65, fract((in.position.x + in.position.y) / 7.0));
                color.rgb *= mix(0.52, 0.78, hatch);
            }
            return color;
        }
        """
        let library = try device.makeLibrary(source: source + adapter, options: nil)
        func pipeline(_ fragment: String, format: MTLPixelFormat, samples: Int, blend: Bool = false, dual: Bool = false) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = library.makeFunction(name: fragment.contains("ink") ? "mate_ink_vertex" : "mate_vertex")
            p.fragmentFunction = library.makeFunction(name: fragment)
            p.rasterSampleCount = samples
            p.colorAttachments[0].pixelFormat = format
            if !dual { p.depthAttachmentPixelFormat = .depth32Float }
            if blend || dual {
                let a = p.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = dual ? .one : .sourceAlpha
                a.destinationRGBBlendFactor = dual ? .source1Color : .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: p)
        }
        solid = try pipeline("heymate_surface", format: .bgra8Unorm, samples: samples)
        clear = try pipeline("heymate_surface", format: .bgra8Unorm, samples: samples, blend: true)
        ids = try pipeline("mate_part_id_fragment", format: .r32Uint, samples: 1)
        ink = try pipeline("mate_ink_and_seam_fragment", format: .bgra8Unorm, samples: 1, dual: true)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual; depth.isDepthWriteEnabled = true
        guard let write = device.makeDepthStencilState(descriptor: depth) else { throw NativeMetalError.invalid("Depth state unavailable") }
        writeDepth = write
        depth.isDepthWriteEnabled = false
        guard let read = device.makeDepthStencilState(descriptor: depth) else { throw NativeMetalError.invalid("Depth state unavailable") }
        readDepth = read
        var offsets = [SIMD4<Float>]()
        for y in -5...5 { for x in -5...5 where x != 0 || y != 0 {
            offsets.append(SIMD4(Float(x), Float(y), max(0, hypot(Float(x), Float(y)) - 0.5), 0))
        } }
        offsets.sort { $0.z < $1.z }
        neighbourCount = UInt32(offsets.count)
        guard let buffer = device.makeBuffer(bytes: offsets, length: offsets.count * MemoryLayout<SIMD4<Float>>.stride) else {
            throw NativeMetalError.invalid("Edge buffer unavailable")
        }
        neighbours = buffer
    }
}

nonisolated enum NativeMetalError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// Arrays are deliberately packed as floats to match MSL's packed vertex layout and float4 uniform ABI.
@MainActor
final class DaVinciMetalRenderer {
    struct Geometry {
        let vertices: MTLBuffer
        let indices: MTLBuffer?
        let count: Int
    }
    struct Draw {
        let geometry: Geometry
        var uniform: [Float]
        let identifier: UInt32
        let transparent: Bool
        let doubleSided: Bool
        let distance: Float
    }
    let context: DaVinciMetalContext
    private var geometries: [String: Geometry] = [:]
    private var targets: [MTLTexture] = []
    private var targetSize = SIMD2<Int>(0, 0)

    init(context: DaVinciMetalContext) { self.context = context }

    private func texture(_ format: MTLPixelFormat, width: Int, height: Int, samples: Int = 1) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        d.sampleCount = samples; d.textureType = samples > 1 ? .type2DMultisample : .type2D
        guard let t = context.device.makeTexture(descriptor: d) else { throw NativeMetalError.invalid("Render target allocation failed") }
        return t
    }

    func ingest(_ items: [[String: Any]]) throws {
        guard items.count <= 1024 else { throw NativeMetalError.invalid("Too many geometry uploads") }
        for item in items {
            guard let id = item["id"] as? String, geometries[id] == nil else { continue }
            let positions = try Self.floats(item["positions"])
            let normals = try Self.floats(item["normals"])
            let uvs = try Self.floats(item["uvs"]), colors = try Self.floats(item["colors"])
            guard !positions.isEmpty, positions.count % 3 == 0, positions.count <= 6_000_000,
                  normals.count == positions.count else { throw NativeMetalError.invalid("Invalid mesh vertex layout") }
            let count = positions.count / 3
            guard uvs.isEmpty || uvs.count == count * 2, colors.isEmpty || colors.count == count * 3 else {
                throw NativeMetalError.invalid("Invalid mesh attributes")
            }
            var packed = [Float](); packed.reserveCapacity(count * 12)
            for i in 0..<count {
                packed.append(contentsOf: positions[(i * 3)..<(i * 3 + 3)])
                packed.append(contentsOf: normals[(i * 3)..<(i * 3 + 3)])
                packed.append(contentsOf: uvs.isEmpty ? [0, 0] : Array(uvs[(i * 2)..<(i * 2 + 2)]))
                packed.append(contentsOf: colors.isEmpty ? [1, 1, 1, 1] : Array(colors[(i * 3)..<(i * 3 + 3)]) + [1])
            }
            guard let vb = context.device.makeBuffer(bytes: packed, length: packed.count * 4) else { throw NativeMetalError.invalid("Vertex allocation failed") }
            let rawIndices = (item["indices"] as? [NSNumber]) ?? []
            guard rawIndices.count <= 12_000_000, rawIndices.allSatisfy({ $0.doubleValue >= 0 && $0.doubleValue < Double(count) && $0.doubleValue.rounded() == $0.doubleValue }) else {
                throw NativeMetalError.invalid("Invalid mesh indices")
            }
            let indices = rawIndices.map(\.uint32Value)
            let ib = indices.isEmpty ? nil : context.device.makeBuffer(bytes: indices, length: indices.count * 4)
            guard indices.isEmpty || ib != nil, (indices.isEmpty ? count : indices.count) % 3 == 0 else { throw NativeMetalError.invalid("Invalid triangle buffer") }
            geometries[id] = Geometry(vertices: vb, indices: ib, count: indices.isEmpty ? count : indices.count)
        }
    }

    static func floats(_ value: Any?, count: Int? = nil) throws -> [Float] {
        guard let values = value as? [NSNumber], count == nil || values.count == count,
              values.allSatisfy({ $0.doubleValue.isFinite && abs($0.doubleValue) <= Double(Float.greatestFiniteMagnitude) }) else {
            throw NativeMetalError.invalid("Invalid numeric drawing payload")
        }
        return values.map(\.floatValue)
    }

    func draws(_ payload: [String: Any]) throws -> ([Float], [Draw]) {
        var vp = try Self.floats(payload["viewProjection"], count: 16)
        // Three.js NDC depth is [-1,1]; Metal is [0,1]. Apply conversion to clip z only.
        for col in 0..<4 { vp[col * 4 + 2] = (vp[col * 4 + 2] + vp[col * 4 + 3]) * 0.5 }
        let eye = try Self.floats(payload["eye"], count: 3)
        let illustrated = payload["illustrated"] as? Bool == true
        let frame = vp + eye + [1, illustrated ? 1 : 0, 3, 5, 4]
        guard let meshes = payload["meshes"] as? [[String: Any]], meshes.count <= 4096 else { throw NativeMetalError.invalid("Invalid draw list") }
        var result = [Draw]()
        for (index, mesh) in meshes.enumerated() {
            guard let id = mesh["geometry"] as? String, let geometry = geometries[id] else { throw NativeMetalError.invalid("Missing geometry") }
            let model = try Self.floats(mesh["model"], count: 16), normal = try Self.floats(mesh["normal"], count: 9)
            let color = try Self.floats(mesh["color"], count: 3), emissive = try Self.floats(mesh["emissive"], count: 3)
            let cut = try Self.floats(mesh["cut"], count: 4)
            let bands = try ((mesh["bands"] as? [[NSNumber]]) ?? []).prefix(16).map { try Self.floats($0, count: 3) }
            let roughness = (mesh["roughness"] as? NSNumber)?.floatValue ?? 0.35
            let metalness = (mesh["metalness"] as? NSNumber)?.floatValue ?? 0
            let opacity = (mesh["opacity"] as? NSNumber)?.floatValue ?? 1
            guard roughness.isFinite, metalness.isFinite, opacity.isFinite else { throw NativeMetalError.invalid("Invalid material") }
            let double = mesh["double"] as? Bool == true
            var u = model
            for c in 0..<3 { u += Array(normal[(c * 3)..<(c * 3 + 3)]) + [0] }
            u += color + [1] + emissive + [0]
            u += [min(1, max(0, roughness)), min(1, max(0, metalness)), min(1, max(0, opacity)), Float(bands.count)]
            u += [mesh["vertexColors"] as? Bool == true ? 1 : 0, mesh["flat"] as? Bool == true ? 1 : 0, double ? 1 : 0, 0] + cut
            for b in 0..<16 { u += (b < bands.count ? bands[b] : [1, 1, 1]) + [1] }
            let distance = (0..<3).reduce(Float(0)) { $0 + pow(model[12 + $1] - eye[$1], 2) }
            result.append(Draw(geometry: geometry, uniform: u, identifier: UInt32(index + 1), transparent: opacity < 0.999,
                               doubleSided: double || cut.prefix(3).contains(where: { abs($0) > 0.25 }), distance: distance))
        }
        // Opaque first; transparent surfaces back-to-front, depth-tested against opaque geometry.
        result.sort { if $0.transparent != $1.transparent { return !$0.transparent }; return $0.transparent && $0.distance > $1.distance }
        return (frame, result)
    }

    /// Shared by live MTKView presentation and the offscreen GPU regression fixture.
    func encode(_ payload: [String: Any], into output: MTLTexture, command: MTLCommandBuffer, scale: Float) throws {
        try ingest(payload["geometries"] as? [[String: Any]] ?? [])
        let (frame, draws) = try draws(payload)
        let size = SIMD2(output.width, output.height)
        if targetSize != size {
            targets = try [texture(.bgra8Unorm, width: size.x, height: size.y, samples: context.samples),
                           texture(.depth32Float, width: size.x, height: size.y, samples: context.samples),
                           texture(.r32Uint, width: size.x, height: size.y), texture(.r32Uint, width: size.x, height: size.y),
                           texture(.depth32Float, width: size.x, height: size.y), texture(.depth32Float, width: size.x, height: size.y)]
            targetSize = size
        }
        func emit(_ encoder: MTLRenderCommandEncoder, _ d: Draw) {
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(d.doubleSided ? .none : .back)
            encoder.setVertexBuffer(d.geometry.vertices, offset: 0, index: 0)
            encoder.setVertexBytes(frame, length: frame.count * 4, index: 1)
            encoder.setFragmentBytes(frame, length: frame.count * 4, index: 1)
            encoder.setVertexBytes(d.uniform, length: d.uniform.count * 4, index: 2)
            encoder.setFragmentBytes(d.uniform, length: d.uniform.count * 4, index: 2)
            var id = d.identifier; encoder.setFragmentBytes(&id, length: 4, index: 3)
            if let indices = d.geometry.indices { encoder.drawIndexedPrimitives(type: .triangle, indexCount: d.geometry.count, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0) }
            else { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: d.geometry.count) }
        }
        // First ID grid holds opaque parts. Second holds visible clear surfaces, with opaque depth loaded.
        for clearPass in [false, true] {
            if clearPass {
                guard let blit = command.makeBlitCommandEncoder() else { throw NativeMetalError.invalid("Depth copy failed") }
                blit.copy(from: targets[4], sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: size.x, height: size.y, depth: 1), to: targets[5], destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
                blit.endEncoding()
            }
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = targets[clearPass ? 3 : 2]
            p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .store
            p.depthAttachment.texture = targets[clearPass ? 5 : 4]
            p.depthAttachment.loadAction = clearPass ? .load : .clear; p.depthAttachment.storeAction = .store; p.depthAttachment.clearDepth = 1
            guard let encoder = command.makeRenderCommandEncoder(descriptor: p) else { throw NativeMetalError.invalid("ID encoder failed") }
            encoder.setRenderPipelineState(context.ids); encoder.setDepthStencilState(context.writeDepth)
            for d in draws where d.transparent == clearPass { emit(encoder, d) }
            encoder.endEncoding()
        }
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = context.samples > 1 ? targets[0] : output
        p.colorAttachments[0].resolveTexture = context.samples > 1 ? output : nil
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        p.colorAttachments[0].storeAction = context.samples > 1 ? .multisampleResolve : .store
        p.depthAttachment.texture = targets[1]; p.depthAttachment.loadAction = .clear; p.depthAttachment.storeAction = .dontCare; p.depthAttachment.clearDepth = 1
        guard let encoder = command.makeRenderCommandEncoder(descriptor: p) else { throw NativeMetalError.invalid("Surface encoder failed") }
        for d in draws {
            encoder.setRenderPipelineState(d.transparent ? context.clear : context.solid)
            encoder.setDepthStencilState(d.transparent ? context.readDepth : context.writeDepth)
            emit(encoder, d)
        }
        encoder.endEncoding()
        let edges = MTLRenderPassDescriptor()
        edges.colorAttachments[0].texture = output; edges.colorAttachments[0].loadAction = .load; edges.colorAttachments[0].storeAction = .store
        guard let pen = command.makeRenderCommandEncoder(descriptor: edges) else { throw NativeMetalError.invalid("Outline encoder failed") }
        pen.setRenderPipelineState(context.ink)
        // The pen: ink colour, outline and seam half-widths in backing pixels, seam strength and shade.
        let rgb = try Self.floats(payload["ink"], count: 3)
        let illustrated = payload["illustrated"] as? Bool == true
        var outline = rgb.map { Self.srgb($0) } + [1, min(4, (illustrated ? 1 : 0.55) * scale), min(4, 0.45 * scale), 0.55, 0.65]
        pen.setFragmentBytes(&outline, length: 32, index: 0)
        pen.setFragmentBuffer(context.neighbours, offset: 0, index: 1)
        var count = context.neighbourCount, readsClear: UInt32 = draws.contains(where: \.transparent) ? 1 : 0
        pen.setFragmentBytes(&count, length: 4, index: 2); pen.setFragmentBytes(&readsClear, length: 4, index: 3)
        pen.setFragmentTexture(targets[2], index: 0); pen.setFragmentTexture(targets[3], index: 1)
        pen.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); pen.endEncoding()
        // Retain cached geometry until stage disposal; hidden parts can become visible again without re-upload.
    }

    private static func srgb(_ x: Float) -> Float { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(max(0, x), 1 / 2.4) - 0.055 }
}
