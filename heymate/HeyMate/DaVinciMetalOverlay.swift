import AppKit
import MetalKit

/// Native stages sit above the web drawing surface. Hit testing remains with the drawing VM,
/// so its card dragging, orbit controls and ray picking keep their existing behavior.
@MainActor
final class DaVinciMetalOverlay: NSView {
    private let context: DaVinciMetalContext
    private var stages: [String: DaVinciMetalStageView] = [:]
    var onPresented: ((String, String?) -> Void)?
    var diagnostics: [String: Any] {
        ["stages": stages.count, "meshes": stages.values.reduce(0) { $0 + $1.meshCount },
         "presentedFrames": stages.values.reduce(0) { $0 + $1.presentedFrames }]
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(frame: NSRect, source: String) throws {
        context = try DaVinciMetalContext(source: source)
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }

    func receive(_ payload: [String: Any]) {
        guard let id = payload["id"] as? String, id.count <= 128 else { return }
        if payload["op"] as? String == "remove" {
            stages.removeValue(forKey: id)?.removeFromSuperview()
            return
        }
        if payload["op"] as? String == "hide" { stages[id]?.isHidden = true; return }
        do {
            let rect = try DaVinciMetalRenderer.floats(payload["rect"], count: 4)
            guard rect[2] > 0, rect[3] > 0, rect[2] <= 8192, rect[3] <= 8192 else {
                throw NativeMetalError.invalid("Invalid stage bounds")
            }
            let stage: DaVinciMetalStageView
            if let existing = stages[id] { stage = existing }
            else {
                guard stages.count < 32 else { throw NativeMetalError.invalid("Too many native stages") }
                stage = DaVinciMetalStageView(context: context)
                stages[id] = stage; addSubview(stage)
            }
            stage.isHidden = false
            stage.frame = CGRect(x: CGFloat(rect[0]), y: CGFloat(rect[1]), width: CGFloat(rect[2]), height: CGFloat(rect[3]))
            try stage.present(payload) { [weak self] error in self?.onPresented?(id, error) }
        } catch {
            NSLog("[Metal3D] %@", error.localizedDescription)
            onPresented?(id, error.localizedDescription)
        }
    }
}

@MainActor
private final class DaVinciMetalStageView: NSView, MTKViewDelegate {
    private(set) var presentedFrames = 0
    private(set) var meshCount = 0
    private var pendingFrame: ([String: Any], @MainActor (String?) -> Void)?
    let metal: MTKView
    let labels = DaVinciMetalLabels()
    let renderer: DaVinciMetalRenderer
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(context: DaVinciMetalContext) {
        renderer = DaVinciMetalRenderer(context: context)
        metal = MTKView(frame: .zero, device: context.device)
        super.init(frame: .zero)
        wantsLayer = true
        labels.wantsLayer = true
        metal.delegate = self
        metal.colorPixelFormat = .bgra8Unorm
        metal.framebufferOnly = false
        metal.isPaused = true; metal.enableSetNeedsDisplay = false
        metal.autoResizeDrawable = true
        metal.clearColor = MTLClearColorMake(0, 0, 0, 0)
        metal.wantsLayer = true; metal.layer?.isOpaque = false
        // Shader output is already encoded sRGB. Avoid a second transfer function.
        (metal.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        addSubview(metal); addSubview(labels)
        metal.autoresizingMask = [.width, .height]; labels.autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        metal.frame = bounds; labels.frame = bounds
    }

    func present(_ payload: [String: Any], completed: @escaping @MainActor (String?) -> Void) throws {
        layoutSubtreeIfNeeded()
        let scale = window?.backingScaleFactor ?? 2
        // Cap drawable area independently of window size to avoid excessive private MSAA allocations.
        let factor = min(scale, 4096 / max(bounds.width, bounds.height), sqrt(4_194_304 / max(1, bounds.width * bounds.height)))
        metal.drawableSize = CGSize(width: max(1, (bounds.width * factor).rounded()), height: max(1, (bounds.height * factor).rounded()))
        pendingFrame = (payload, completed)
        // Let MTKView own drawable acquisition/release. Reading currentDrawable outside draw()
        // would retain a presented drawable and eventually exhaust the layer's drawable pool.
        metal.draw()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    nonisolated func draw(in view: MTKView) {
        // This view is paused; only present() above calls draw(), always on the main actor.
        MainActor.assumeIsolated { drawFrame() }
    }
    private func drawFrame() {
        guard let (payload, completed) = pendingFrame else { return }
        pendingFrame = nil
        guard let drawable = metal.currentDrawable, let command = renderer.context.queue.makeCommandBuffer() else {
            completed(nil); return
        }
        do {
            try renderer.encode(payload, into: drawable.texture, command: command,
                                scale: Float(metal.drawableSize.width / max(1, bounds.width)))
            meshCount = (payload["meshes"] as? [[String: Any]])?.count ?? 0
            labels.items = payload["labels"] as? [[String: Any]] ?? []
            labels.needsDisplay = true
            command.present(drawable)
            command.addCompletedHandler { [weak self] buffer in
                let error = buffer.error?.localizedDescription
                Task { @MainActor in
                    if error == nil { self?.presentedFrames += 1 }
                    completed(error)
                }
            }
            command.commit()
        } catch {
            NSLog("[Metal3D] %@", error.localizedDescription)
            completed(error.localizedDescription)
        }
    }
}

@MainActor
private final class DaVinciMetalLabels: NSView {
    var items: [[String: Any]] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        for item in items {
            guard let text = item["text"] as? String,
                  let x = item["x"] as? Double, let y = item["y"] as? Double,
                  let ax = item["ax"] as? Double, let ay = item["ay"] as? Double,
                  [x, y, ax, ay].allSatisfy(\.isFinite) else { continue }
            let font = NSFont.systemFont(ofSize: min(40, max(8, item["size"] as? Double ?? 15)), weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.085, alpha: 1)]
            let size = (text as NSString).size(withAttributes: attributes)
            let left = item["side"] as? String == "left"
            let box = NSRect(x: left ? x - size.width - 20 : x, y: y - (size.height + 6) / 2, width: size.width + 20, height: size.height + 6)
            let line = NSBezierPath(); line.move(to: NSPoint(x: left ? box.maxX + 4 : box.minX - 4, y: y)); line.line(to: NSPoint(x: ax, y: ay))
            NSColor.white.withAlphaComponent(0.65).setStroke(); line.lineWidth = 1.6; line.stroke()
            NSColor.white.withAlphaComponent(0.94).setFill(); NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
            (text as NSString).draw(at: NSPoint(x: box.minX + 10, y: box.minY + 3), withAttributes: attributes)
        }
    }
}
