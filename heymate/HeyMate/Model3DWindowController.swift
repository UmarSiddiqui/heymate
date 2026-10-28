//
//  Model3DWindowController.swift
//  HeyMate
//
//  The window a {"model3d"} reply builds into. Parts pop in one after
//  another, the model turns slowly until it is touched, a drag turns it,
//  scrolling zooms, hovering names a part, and a click on a part asks
//  HeyMate about it. One model at a time; Escape or × closes it.
//

import AppKit
import SceneKit
import SwiftUI
import simd

@MainActor
final class Model3DWindowController {
    static let windowSize = CGSize(width: 440, height: 480)

    private var panel: NSPanel?
    /// Called with the model title and the clicked part's name.
    var onAskAboutPart: ((String, String) -> Void)?

    var isShowingModel: Bool { panel != nil }
    private(set) var currentModel: Model3DSpec?
    /// Global frame of the model window while it is up.
    var windowFrame: CGRect? { panel?.frame }

    func show(_ model: Model3DSpec, on screenFrame: CGRect) {
        currentModel = model
        close()
        let panel = Self.makePanel()
        let view = Model3DCardView(
            model: model,
            onClose: { [weak self] in self?.close() },
            onAskAboutPart: { [weak self] part in self?.onAskAboutPart?(model.title, part) }
        )
        let hosting = Model3DHostingView(rootView: view)
        panel.contentView = hosting
        let visible = NSScreen.screens.first(where: { $0.frame == screenFrame })?.visibleFrame ?? screenFrame
        // Left of where note cards stack, so the two sit side by side.
        let origin = CGPoint(
            x: max(visible.minX + 24, visible.maxX - DrawCardWindowController.cardWidth - 48 - Self.windowSize.width),
            y: visible.midY - Self.windowSize.height / 2
        )
        panel.setFrame(CGRect(origin: origin, size: Self.windowSize), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Animation.normal
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        currentModel = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Animation.fast
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                panel.contentView = nil
            }
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = Model3DPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }
}

private final class Model3DPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class Model3DHostingView: NSHostingView<Model3DCardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct Model3DCardView: View {
    let model: Model3DSpec
    let onClose: () -> Void
    let onAskAboutPart: (String) -> Void

    @State private var hovered: Model3DSpec.Part?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.sm)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close model")
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            // The header drags the window; the stage below turns the model.
            .background(WindowDragArea())

            Model3DStage(model: model, hovered: $hovered, onClickPart: onAskAboutPart)

            Group {
                if let hovered {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hovered.name).font(DS.Fonts.headline).foregroundColor(DS.Colors.textPrimary)
                        if let about = hovered.about {
                            Text(about).font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary).lineLimit(2)
                        }
                    }
                } else {
                    Text("Drag to turn · scroll to zoom · click a part to ask")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
        .frame(width: Model3DWindowController.windowSize.width, height: Model3DWindowController.windowSize.height)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
    }
}

/// A strip that moves its window when dragged.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct Model3DStage: NSViewRepresentable {
    let model: Model3DSpec
    @Binding var hovered: Model3DSpec.Part?
    let onClickPart: (String) -> Void

    func makeNSView(context: Context) -> Model3DSceneView {
        let view = Model3DSceneView(frame: .zero, options: nil)
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.scene = Model3DSceneBuilder.scene(for: model)
        view.pointOfView = view.scene?.rootNode.childNode(withName: Model3DSceneBuilder.cameraName, recursively: false)
        view.onHover = { name in
            hovered = name.flatMap { name in model.parts.first(where: { $0.name == name }) }
        }
        view.onClickPart = onClickPart
        Model3DSceneBuilder.playBuild(in: view.scene)
        return view
    }

    func updateNSView(_ nsView: Model3DSceneView, context: Context) {}
}

/// SceneKit view that tells a click on a part from a drag that turns it.
final class Model3DSceneView: SCNView {
    var onHover: ((String?) -> Void)?
    var onClickPart: ((String) -> Void)?

    private var pressLocation: CGPoint?
    private var hoveredName: String?
    private static let clickSlop: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        // Once touched, the model holds still where the user puts it.
        scene?.rootNode.childNode(withName: Model3DSceneBuilder.modelName, recursively: false)?
            .removeAction(forKey: Model3DSceneBuilder.turntableKey)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let location = convert(event.locationInWindow, from: nil)
        defer { pressLocation = nil }
        guard let pressLocation, hypot(location.x - pressLocation.x, location.y - pressLocation.y) < Self.clickSlop,
              let node = partNode(at: location), let name = Model3DSceneBuilder.partName(of: node) else { return }
        Model3DSceneBuilder.flash(node)
        onClickPart?(name)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let name = partNode(at: convert(event.locationInWindow, from: nil)).flatMap { Model3DSceneBuilder.partName(of: $0) }
        guard name != hoveredName else { return }
        hoveredName = name
        if name != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        onHover?(name)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredName = nil
        NSCursor.arrow.set()
        onHover?(nil)
    }

    private func partNode(at point: CGPoint) -> SCNNode? {
        hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first.flatMap { hit in
            var node: SCNNode? = hit.node
            while let current = node, Model3DSceneBuilder.partName(of: current) == nil { node = current.parent }
            return node
        }
    }
}

/// Turns a validated spec into a lit SceneKit scene.
enum Model3DSceneBuilder {
    static let cameraName = "heymate.camera"
    static let modelName = "heymate.model"
    static let turntableKey = "heymate.turntable"
    private static let partPrefix = "part:"
    static let buildStagger: TimeInterval = 0.12

    static func partName(of node: SCNNode) -> String? {
        guard let name = node.name, name.hasPrefix(partPrefix) else { return nil }
        return String(name.dropFirst(partPrefix.count))
    }

    static func scene(for model: Model3DSpec) -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()
        root.name = modelName
        let visible = model.parts.filter { part in
            guard let role = part.role else { return true }
            return !model.hiddenRoles.contains(role)
        }
        let centroid = centroid(of: visible)
        for part in visible {
            root.addChildNode(node(for: part.exploded(from: centroid, distance: model.explode)))
        }

        // Centre the model on the origin so it turns about its middle.
        let (center, radius) = root.boundingSphere
        root.childNodes.forEach { $0.position = SCNVector3($0.position.x - center.x, $0.position.y - center.y, $0.position.z - center.z) }
        if model.spins {
            root.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 18)), forKey: turntableKey)
        }
        scene.rootNode.addChildNode(root)

        let camera = SCNCamera()
        camera.fieldOfView = 35
        camera.zNear = 0.01
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.name = cameraName
        cameraNode.camera = camera
        // Far enough back to frame the whole model, a little from above.
        let distance = Double(max(radius, 0.2)) / sin(35 / 2 * .pi / 180) * 1.15
        let tilt = 15 * Double.pi / 180
        cameraNode.position = SCNVector3(0, distance * sin(tilt), distance * cos(tilt))
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.8, 0.6, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 380
        scene.rootNode.addChildNode(fill)
        return scene
    }

    /// Parts grow in one after another, as if HeyMate were assembling them.
    static func playBuild(in scene: SCNScene?) {
        guard let root = scene?.rootNode.childNode(withName: modelName, recursively: false) else { return }
        for (index, node) in root.childNodes.enumerated() {
            let finalScale = node.scale
            node.scale = SCNVector3(0.001, 0.001, 0.001)
            let grow = SCNAction.scale(to: CGFloat(finalScale.x), duration: 0.35)
            grow.timingMode = .easeOut
            node.runAction(.sequence([.wait(duration: Double(index) * buildStagger), grow]))
        }
        UISoundPlayer.shared.play(.hatching, volume: 0.35)
    }

    /// A short glow on the part that was clicked.
    static func flash(_ node: SCNNode) {
        guard let material = node.geometry?.firstMaterial else { return }
        let original = material.emission.contents
        material.emission.contents = NSColor(white: 0.45, alpha: 1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            material.emission.contents = original
        }
    }

    private static func centroid(of parts: [Model3DSpec.Part]) -> simd_double3 {
        guard !parts.isEmpty else { return .zero }
        var sum = simd_double3.zero
        for part in parts {
            if part.shape == .tube, let from = part.from, let to = part.to {
                sum += (simd_double3(from[0], from[1], from[2]) + simd_double3(to[0], to[1], to[2])) / 2
            } else {
                let position = part.position
                sum += simd_double3(position[0], position[1], position[2])
            }
        }
        return sum / Double(parts.count)
    }

    private static func node(for part: Model3DSpec.Part) -> SCNNode {
        let size = part.size.map { CGFloat($0) }
        let geometry: SCNGeometry
        switch part.shape {
        case .box:
            geometry = SCNBox(width: size[0], height: size[1], length: size[2], chamferRadius: min(size[0], size[1], size[2]) * 0.06)
        case .sphere:
            geometry = SCNSphere(radius: size[0])
        case .cylinder:
            geometry = SCNCylinder(radius: size[0], height: size[1])
        case .cone:
            geometry = SCNCone(topRadius: 0, bottomRadius: size[0], height: size[1])
        case .capsule:
            geometry = SCNCapsule(capRadius: size[0], height: max(size[1], size[0] * 2))
        case .torus:
            geometry = SCNTorus(ringRadius: size[0], pipeRadius: size[1])
        case .tube:
            let start = simd_double3(part.from ?? [0, 0, 0])
            let end = simd_double3(part.to ?? [0, 1, 0])
            geometry = SCNCylinder(radius: size[0], height: CGFloat(simd_distance(start, end)))
        }
        geometry.firstMaterial = material(for: part)

        let node = SCNNode(geometry: geometry)
        node.name = partPrefix + part.name
        if part.shape == .tube, let from = part.from, let to = part.to {
            let start = simd_float3(simd_double3(from))
            let end = simd_float3(simd_double3(to))
            node.simdPosition = (start + end) / 2
            node.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: simd_normalize(end - start))
        } else {
            node.position = SCNVector3(part.position[0], part.position[1], part.position[2])
            node.eulerAngles = SCNVector3(part.rotation.map { $0 * .pi / 180 }[0],
                                          part.rotation.map { $0 * .pi / 180 }[1],
                                          part.rotation.map { $0 * .pi / 180 }[2])
        }
        if let motion = part.motion { node.runAction(action(for: motion), forKey: "motion") }
        return node
    }

    private static func action(for motion: Model3DSpec.Motion) -> SCNAction {
        switch motion {
        case .spin:
            return .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 3))
        case .bob:
            let up = SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 0.8)
            up.timingMode = .easeInEaseOut
            return .repeatForever(.sequence([up, up.reversed()]))
        case .pulse:
            let grow = SCNAction.scale(by: 1.08, duration: 0.6)
            grow.timingMode = .easeInEaseOut
            return .repeatForever(.sequence([grow, grow.reversed()]))
        }
    }

    private static func material(for part: Model3DSpec.Part) -> SCNMaterial {
        let material = SCNMaterial()
        let color = NSColor(model3DHex: part.colorHex)
        material.lightingModel = .blinn
        material.diffuse.contents = color
        switch part.material {
        case .matte:
            material.specular.contents = NSColor(white: 0.1, alpha: 1)
        case .wood:
            material.specular.contents = NSColor(white: 0.15, alpha: 1)
            material.shininess = 0.2
        case .paint:
            material.specular.contents = NSColor(white: 0.6, alpha: 1)
            material.shininess = 0.6
        case .steel:
            material.specular.contents = NSColor.white
            material.shininess = 0.9
            material.reflective.contents = NSColor(white: 0.25, alpha: 1)
        case .glass:
            material.specular.contents = NSColor.white
            material.shininess = 1
            material.transparency = 0.35
            material.isDoubleSided = true
        case .glow:
            material.emission.contents = color
        }
        return material
    }
}

private extension NSColor {
    convenience init(model3DHex hexString: String) {
        let hex = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        let value = UInt64(hex, radix: 16) ?? 0xB8BCC4
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
