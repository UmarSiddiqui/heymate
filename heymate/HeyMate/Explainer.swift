//
//  Explainer.swift
//  HeyMate
//
//  A drawn explanation: the reply carries one ```js program of step(n),
//  say("…") and drawing calls (paper, sticky, write, arrow, …). The drawing
//  engine (mate-draw-engine.js with mate-draw-pieces.js prepended) runs
//  it in a transparent web view over the screen, and each say() line's
//  strokes are drawn while HeyMate speaks that line.
//

import AppKit
import WebKit

nonisolated enum ExplainerParser {
    // The closing fence is optional: models sometimes end the block with a broken fence (two backticks and noise) or none.
    private static let blockPattern = #"```(?:js|javascript)[ \t]*\n([\s\S]*?)(?:```|\n`{1,2}[^\n]*\s*$|$)"#
    private static let sayPattern = #"say\(\s*(["'`])((?:\\.|(?!\1)[\s\S])*)\1\s*\)"#

    /// The reply without its program, the program, and its say() lines in order.
    static func extract(from text: String) -> (text: String, program: String?, lines: [String]) {
        guard let regex = try? NSRegularExpression(pattern: blockPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let blockRange = Range(match.range, in: text),
              let codeRange = Range(match.range(at: 1), in: text) else {
            return (text, nil, [])
        }
        let program = String(text[codeRange])
        let lines = sayLines(in: program)
        // A code block that never speaks is code they asked for, not a drawing.
        guard !lines.isEmpty else { return (text, nil, []) }
        var rest = text
        rest.removeSubrange(blockRange)
        return (rest, program, lines)
    }

    /// The program so far in a reply still streaming in, and whether its block has closed.
    static func streamingProgram(in text: String) -> (code: String, closed: Bool)? {
        guard let open = text.range(of: "```js\n") ?? text.range(of: "```javascript\n") else { return nil }
        let rest = text[open.upperBound...]
        if let close = rest.range(of: "```") { return (String(rest[..<close.lowerBound]), true) }
        // A last line that is only a broken fence is not code.
        if let fence = rest.range(of: #"\n`{1,2}[^\n]*$"#, options: .regularExpression) { return (String(rest[..<fence.lowerBound]), false) }
        return (String(rest), false)
    }

    /// Where a program block still arriving starts, so it is never shown.
    static func openBlockStart(in text: String) -> String.Index? {
        guard let start = text.range(of: "```js") ?? text.range(of: "```javascript") else { return nil }
        return text[start.upperBound...].contains("```") ? nil : start.lowerBound
    }

    static func sayLines(in program: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: sayPattern) else { return [] }
        return regex.matches(in: program, range: NSRange(program.startIndex..., in: program)).compactMap { match in
            guard let range = Range(match.range(at: 2), in: program) else { return nil }
            let line = String(program[range])
                .replacingOccurrences(of: #"\\(["'`\\])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "\\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
    }

    /// A program that only points (step, say, target, hover, point): the reply showed where things are, drew nothing.
    static func onlyPoints(_ program: String) -> Bool {
        let withoutSaid = program.replacingOccurrences(of: sayPattern, with: "", options: .regularExpression)
        guard let calls = try? NSRegularExpression(pattern: #"\b([A-Za-z_$][\w$]*)\s*\("#) else { return false }
        let names = calls.matches(in: withoutSaid, range: NSRange(withoutSaid.startIndex..., in: withoutSaid)).compactMap {
            Range($0.range(at: 1), in: withoutSaid).map { String(withoutSaid[$0]) }
        }
        let pointers: Set<String> = ["target", "hover", "point"]
        return names.contains(where: pointers.contains) && names.allSatisfy { pointers.contains($0) || $0 == "step" }
    }
}

/// The overlay the program draws on. Click-through except over its cards and
/// 3D figures, which can be dragged, closed, made full screen, turned and
/// clicked; it stays until the next explanation, a clear, or a while after the
/// last line is spoken and nobody has touched it.
@MainActor
final class ExplainerWindowController: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private var panel: NSPanel?
    private var webView: WKWebView?
    private var metalOverlay: DaVinciMetalOverlay?
    private var clearButton: NSButton?
    private var controlsPanel: NSPanel?
    /// Where the cards and figures are, in the overlay's top-left points: the mouse reaches the page only there.
    private var hitRects: [CGRect] = []
    private var mouseTimer: Timer?
    private var keepFor: TimeInterval?
    /// A clicked part of a 3D figure, by name.
    var onAskAboutPart: ((String) -> Void)?
    /// A line points at something on the screen: where (AppKit global points), its name, and the screen.
    var onPoint: ((CGPoint, String?, CGRect) -> Void)?
    var onDropPointing: (() -> Void)?
    /// A drawn button was pressed: its kind (open, copy, ask, handoff) and value.
    var onButton: ((String, Any?) -> Void)?
    /// A line's action is heard: its role (type, copy, open, handoff), text, and where on screen (AppKit global
    /// points, as HeyMate's computer use takes them).
    var onAction: ((String, String, CGPoint?) -> Void)?
    private var canvasSize: CGSize = .zero
    private let sounds = DrawingSoundPlayer()
    private var isLoaded = false
    private var pendingScripts: [String] = []
    private var closeTask: Task<Void, Never>?
    private var screenChangeObservers: [NSObjectProtocol] = []
    private var screenInputMonitor: Any?
    private var screenChangeTask: Task<Void, Never>?

    private func watchScreenChanges() {
        screenChangeObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let identifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            guard identifier != Bundle.main.bundleIdentifier else { return }
            Task { @MainActor [weak self] in self?.screenChanged() }
        })
        screenChangeObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("HeyMateBrowserPageChanged"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.screenChanged() } })
        screenInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screenChanged() }
        }
    }

    private func screenChanged() {
        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.onDropPointing?()
            self?.run("HeyMateCanvas.screenChanged()")
        }
    }

    var isShowing: Bool { panel != nil }

    // A drawing that arrives while the reply streams in (ReferenceRenderer feeds its canvas the same way): the response it
    // belongs to, the program fed so far, its say() lines so far, whether it is complete, and the voice telling it.
    private(set) var streamOwner: ObjectIdentifier?
    private(set) var dismissedStreamOwner: ObjectIdentifier?
    func resetStreamDismissal() { dismissedStreamOwner = nil }
    private var fedProgram = ""
    var streamLines: [String] = []
    var streamDone = false
    var streamSpeaker: Task<Void, Never>?

    /// Starts a drawing for a reply still streaming in; feed() adds to it. A drawing already showing is
    /// continued instead (ReferenceRenderer's continueStream): it stays, and the new turn draws on.
    func beginStream(owner: ObjectIdentifier, on screenFrame: CGRect, canvas: CGSize? = nil, screenshot: Data? = nil) {
        if isShowing, panel?.frame == screenFrame,
           Self.canReuseCanvas(current: canvasSize, requested: canvas, frame: screenFrame) {
            continueDrawing(screenshot: screenshot)
        } else {
            show(program: nil, on: screenFrame, canvas: canvas, screenshot: screenshot)
        }
        streamOwner = owner
    }

    /// Shows a whole program at once: on the drawing already there when there is one.
    func showOrContinue(program: String, on screenFrame: CGRect, canvas: CGSize? = nil, screenshot: Data? = nil) {
        if isShowing, panel?.frame == screenFrame,
           Self.canReuseCanvas(current: canvasSize, requested: canvas, frame: screenFrame) {
            continueDrawing(screenshot: screenshot)
            feed(program, done: true)
        } else {
            show(program: program, on: screenFrame, canvas: canvas, screenshot: screenshot)
        }
    }

    /// Replaying marks made against another image size shifts their targets.
    /// Restart the canvas rather than interpreting fresh pixels in stale units.
    static func canReuseCanvas(current: CGSize, requested: CGSize?, frame: CGRect) -> Bool {
        let next = requested.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? frame.size
        return current == next
    }

    private func continueDrawing(screenshot: Data?) {
        streamSpeaker?.cancel()
        streamSpeaker = nil
        closeTask?.cancel()
        closeTask = nil
        keepFor = nil
        fedProgram = ""
        streamLines = []
        streamDone = false
        lineStarts = [:]
        run(Self.screenshotScript(screenshot, canvas: canvasSize))
        run("HeyMateCanvas.continue()")
    }

    /// What the drawing on screen holds now, in the canvas's words for the model, or nil when nothing is drawn.
    func drawingState() async -> String? {
        guard let webView, isLoaded else { return nil }
        let state = try? await webView.evaluateJavaScript("HeyMateCanvas.state()") as? String
        return state?.isEmpty == false ? state : nil
    }

    func rendererState() async -> [String: Any] {
        let drawing = await drawingState()
        return ["showing": isShowing, "streamDone": streamDone, "lines": streamLines.count,
                "drawing": drawing ?? "", "native": metalOverlay?.diagnostics ?? [:]]
    }

    /// The whole program so far; the canvas runs its complete statements and waits for the rest.
    func feed(_ program: String, done: Bool) {
        guard program != fedProgram || done else { return }
        fedProgram = program
        run("HeyMateCanvas.feed(\(Self.jsString(program)), \(done))")
    }

    /// `canvas` is the screenshot the model saw, in pixels: its coordinates are the drawing's.
    func show(program: String?, on screenFrame: CGRect, canvas: CGSize? = nil, screenshot: Data? = nil) {
        close()
        // ReferenceRenderer's native canvas runs as it does in its app (mate-draw-native.js over the engine and pieces,
        // handed over as text); mate-host.js paints 2D. Three.js supplies scene math and
        // the recovered 3D kernel supplies meshes; native Metal paints the 3D stages.
        let scripts = ["three-r159.min", "mate-three", "mate-three-parts", "mate-metal-bridge", "mate-stage3d", "mate-host"].map(Self.resource)
        guard let native = Self.resource("mate-draw-native"), let engine = Self.resource("mate-draw-engine"),
              let pieces = Self.resource("mate-draw-pieces"), !scripts.contains(nil) else { return }

        let overlay: DaVinciMetalOverlay
        do {
            guard let url = Bundle.main.url(forResource: "DaVinciShaders", withExtension: "txt") else {
                throw NativeMetalError.invalid("Missing DaVinci shader resource")
            }
            overlay = try DaVinciMetalOverlay(frame: CGRect(origin: .zero, size: screenFrame.size),
                                              source: String(contentsOf: url, encoding: .utf8))
        } catch {
            NSLog("[Explainer] native Metal initialization failed: %@", error.localizedDescription)
            return
        }
        overlay.onPresented = { [weak self] id, error in
            self?.run("MateMetal.presented(\(Self.jsString(id)), \(error.map(Self.jsString) ?? "null"))")
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: "globalThis.__heymateNativeMetal = true; globalThis.__heymateMetalSession = \(Self.jsString(UUID().uuidString));",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(WeakMessageHandler(self), name: "heymate")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__mateSources = {native: \(Self.jsString(native)), engine: \(Self.jsString(engine)), pieces: \(Self.jsString(pieces))};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for case let script? in scripts {
            configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = ExplainerWebView(frame: CGRect(origin: .zero, size: screenFrame.size), configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self

        let panel = NSPanel(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        content.wantsLayer = true
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        content.addSubview(overlay)
        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearDrawing))
        clearButton.wantsLayer = true
        clearButton.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
        clearButton.imagePosition = .imageLeading
        clearButton.bezelStyle = .rounded
        clearButton.font = .systemFont(ofSize: 13, weight: .medium)
        clearButton.toolTip = "Clear drawings"
        clearButton.setAccessibilityLabel("Clear drawings")
        clearButton.setAccessibilityIdentifier("drawing-clear")
        clearButton.frame = CGRect(x: 0, y: 0, width: 88, height: 32)
        let controls = NSPanel(contentRect: CGRect(x: screenFrame.maxX - 112, y: screenFrame.maxY - 78, width: 88, height: 32),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        controls.isOpaque = false
        controls.backgroundColor = .clear
        controls.hasShadow = true
        controls.level = .floating
        controls.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        controls.contentView = clearButton
        self.controlsPanel = controls
        self.clearButton = clearButton
        panel.contentView = content
        self.metalOverlay = overlay
        panel.setFrame(screenFrame, display: false)
        panel.orderFrontRegardless()
        panel.addChildWindow(controls, ordered: .above)
        controls.orderFrontRegardless()

        self.panel = panel
        self.webView = webView
        watchScreenChanges()
        hitRects = []
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }
        isLoaded = false
        lineStarts = [:]
        let canvasSize = canvas.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? screenFrame.size
        self.canvasSize = canvasSize
        pendingScripts = [Self.screenshotScript(screenshot, canvas: canvasSize),
                          Self.startScript(canvas: canvasSize, widthInPoints: screenFrame.width)]
        if let program { feed(program, done: true) }
        webView.loadHTMLString(Self.page, baseURL: nil)
    }

    private var lineStarts: [Int: Date] = [:]

    /// HeyMate starts speaking say() line k (0-based): its strokes draw now (mateCanvas.line).
    func lineStart(_ k: Int) {
        lineStarts[k] = Date()
        run("HeyMateCanvas.line(\(k))")
    }
    /// Line k has been heard: how long it took (mateCanvas.lineLength).
    func lineEnd(_ k: Int) {
        guard let start = lineStarts[k] else { return }
        run("HeyMateCanvas.lineLength(\(k), \(max(0.2, Date().timeIntervalSince(start))))")
    }

    /// Every line has been spoken: the canvas lets the rest go, then the drawing stays up a while.
    func finish(keepingFor seconds: TimeInterval = 60) {
        run("HeyMateCanvas.finish()")
        keepFor = seconds
        closeLater(after: seconds)
    }

    private func closeLater(after seconds: TimeInterval) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        screenChangeTask?.cancel(); screenChangeTask = nil
        for observer in screenChangeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        screenChangeObservers = []
        if let screenInputMonitor { NSEvent.removeMonitor(screenInputMonitor) }
        screenInputMonitor = nil
        closeTask?.cancel()
        closeTask = nil
        sounds.stopAll()
        mouseTimer?.invalidate()
        mouseTimer = nil
        hitRects = []
        keepFor = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "heymate")
        streamSpeaker?.cancel()
        streamSpeaker = nil
        streamOwner = nil
        fedProgram = ""
        streamLines = []
        streamDone = false
        metalOverlay?.removeFromSuperview()
        metalOverlay = nil
        controlsPanel?.orderOut(nil)
        if let controlsPanel { panel?.removeChildWindow(controlsPanel) }
        controlsPanel = nil
        clearButton = nil
        webView?.navigationDelegate = nil
        webView = nil
        panel?.orderOut(nil)
        panel = nil
        pendingScripts = []
        isLoaded = false
    }

    /// The overlay receives clicks over cards, figures and Clear (and for an active drag).
    private func followMouse() {
        guard let panel else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let mouse = NSEvent.mouseLocation, frame = panel.frame
        let point = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let over = hitRects.contains { $0.insetBy(dx: -4, dy: -4).contains(point) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    func dismiss() {
        dismissedStreamOwner = streamOwner
        onDropPointing?()
        close()
    }

    @objc private func clearDrawing() { dismiss() }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let payload = body["body"]
        Task { @MainActor [weak self] in
            guard let self, message.webView === self.webView else { return }
            self.received(type, payload)
        }
    }

    private func received(_ type: String, _ payload: Any?) {
        switch type {
        case "metal3d":
            if let fields = payload as? [String: Any] { metalOverlay?.receive(fields) }
        case "hitRects":
            hitRects = (payload as? [[Double]] ?? []).compactMap { r in r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : nil }
        case "pointAt":
            guard let fields = payload as? [String: Any], let frame = panel?.frame,
                  let x = fields["x"] as? Double, let y = fields["y"] as? Double, canvasSize.width > 0 else { break }
            let point = CGPoint(x: frame.minX + x * frame.width / canvasSize.width,
                                y: frame.maxY - y * frame.height / canvasSize.height)
            onPoint?(point, fields["label"] as? String, frame)
        case "button":
            guard let fields = payload as? [String: Any], let kind = fields["kind"] as? String else { break }
            onButton?(kind, fields["value"])
        case "action":
            guard let fields = payload as? [String: Any], let role = fields["role"] as? String else { break }
            var point: CGPoint?
            if let x = fields["x"] as? Double, let y = fields["y"] as? Double, let frame = panel?.frame, canvasSize.width > 0 {
                point = CGPoint(x: frame.minX + x * frame.width / canvasSize.width,
                                y: frame.maxY - y * frame.height / canvasSize.height)
            }
            onAction?(role, fields["text"] as? String ?? "", point)
        case "sound":
            if let description = payload as? [String: Any] { sounds.play(description) }
        case "findPhoto":
            guard let query = payload as? String else { break }
            Task { [weak self] in
                let url = await ExplainerPhotoFinder.find(query)
                self?.run("HeyMateCanvas.photoFound(\(Self.jsString(query)), \(url.map { Self.jsString($0.absoluteString) } ?? "null"))")
            }
        case "askPart":
            if let part = payload as? String { onAskAboutPart?(part) }
        case "touched":
            // Someone is using it: it stays as long again as it would have after its last line.
            if let keepFor { closeLater(after: keepFor) }
        case "empty":
            close()
        default:
            break
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self, webView === self.webView else { return }
            self.isLoaded = true
            let scripts = self.pendingScripts
            self.pendingScripts = []
            scripts.forEach(self.run)
        }
    }

    private func run(_ script: String) {
        guard let webView else { return }
        guard isLoaded else { pendingScripts.append(script); return }
        webView.evaluateJavaScript(script) { _, error in
            if let error { NSLog("[Explainer] script failed: \(error)") }
        }
    }

    private static func resource(_ name: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            NSLog("[Explainer] missing \(name).js in the app bundle")
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func jsString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Transport adapter only. Pixel statistics/selection run in the directly
    /// ported native algorithms in mate-host.js. Use the same captured image
    /// the model saw; never take an extra capture or reuse an earlier turn's.
    static func screenshotScript(_ data: Data?, canvas: CGSize) -> String {
        guard let data, let image = NSBitmapImageRep(data: data)?.cgImage,
              image.width == Int(canvas.width), image.height == Int(canvas.height),
              image.width > 0, image.height > 0, image.width * image.height <= 16_777_216 else {
            return "HeyMateCanvas.screenSampling.clear()"
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return "HeyMateCanvas.screenSampling.clear()" }
        return "HeyMateCanvas.screenSampling.set({width: \(width), height: \(height), rgba: \(jsString(Data(rgba).base64EncodedString()))})"
    }

    /// mateCanvas.beginStream; the program follows through feed().
    private static func startScript(canvas: CGSize, widthInPoints: CGFloat) -> String {
        "try { HeyMateCanvas.begin({w: \(Int(canvas.width)), h: \(Int(canvas.height)), width: \(Int(widthInPoints)), ink: '#3380FF'}); } catch (e) { console.error('explainer', e); }"
    }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <link href="https://fonts.googleapis.com/css2?family=Patrick+Hand&family=Barlow:wght@400;600&display=swap" rel="stylesheet">
    <style>html,body{margin:0;background:transparent;overflow:hidden;height:100%}</style>
    </head><body></body></html>
    """
}

/// Takes the first click, so a card or figure answers without the overlay being made key first.
private final class ExplainerWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// WKUserContentController keeps its handlers strongly; this keeps the overlay from being held by its own page.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Finds the picture for a drawing's photo(), as ReferenceRenderer's app does for its query, from free sources with no key:
/// a news page's own preview picture ("page: url :: name"), else Wikipedia's picture for the thing (skipped for
/// "web:", something new), else Openverse's openly licensed images.
nonisolated enum ExplainerPhotoFinder {
    static func find(_ query: String) async -> URL? {
        var rest = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.lowercased().hasPrefix("nopeople:") { rest = String(rest.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
        if rest.lowercased().hasPrefix("page:") {
            let parts = rest.dropFirst(5).components(separatedBy: " :: ")
            let page = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = parts.dropFirst().joined(separator: " :: ")
            if let url = await pagePicture(page) { return url }
            return await find(name)
        }
        let web = rest.lowercased().hasPrefix("web:")
        let name = web ? String(rest.dropFirst(4)).trimmingCharacters(in: .whitespaces) : rest
        guard !name.isEmpty else { return nil }
        if !web, let url = await wikipediaPicture(name) { return url }
        return await openversePicture(name)
    }

    private static func json(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("HeyMate/1.0 (macOS; drawing photos)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func wikipediaPicture(_ name: String) async -> URL? {
        var parts = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        parts.queryItems = [.init(name: "action", value: "query"), .init(name: "generator", value: "search"),
                            .init(name: "gsrsearch", value: name), .init(name: "gsrlimit", value: "1"),
                            .init(name: "prop", value: "pageimages"), .init(name: "piprop", value: "thumbnail"),
                            .init(name: "pithumbsize", value: "800"), .init(name: "format", value: "json")]
        guard let url = parts.url, let body = await json(url), let query = body["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any] else { return nil }
        for case let page as [String: Any] in pages.values {
            if let thumbnail = page["thumbnail"] as? [String: Any], let source = thumbnail["source"] as? String { return URL(string: source) }
        }
        return nil
    }

    private static func openversePicture(_ name: String) async -> URL? {
        var parts = URLComponents(string: "https://api.openverse.org/v1/images/")!
        parts.queryItems = [.init(name: "q", value: name), .init(name: "page_size", value: "1")]
        guard let url = parts.url, let body = await json(url), let results = body["results"] as? [[String: Any]],
              let first = results.first else { return nil }
        return ((first["thumbnail"] as? String) ?? (first["url"] as? String)).flatMap(URL.init(string:))
    }

    /// A web page's own preview picture (its og:image).
    private static func pagePicture(_ address: String) async -> URL? {
        guard let page = URL(string: address), let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var request = URLRequest(url: page, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (Macintosh) HeyMate/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data.prefix(400_000), encoding: .utf8) ?? String(data: data.prefix(400_000), encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: #"<meta[^>]+(?:property|name)=["']og:image["'][^>]*content=["']([^"']+)["']|<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']og:image["']"#, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) else { return nil }
        for group in 1...2 {
            if let range = Range(match.range(at: group), in: html) { return URL(string: String(html[range]), relativeTo: page)?.absoluteURL }
        }
        return nil
    }
}
