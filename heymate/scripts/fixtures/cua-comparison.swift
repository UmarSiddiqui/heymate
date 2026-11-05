import AppKit

// Disposable, synthetic target for Cua comparisons. Never reads user documents.
final class Fixture: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    let stateURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let field = NSTextField(string: "")
    let slider = NSSlider(value: 20, minValue: 0, maxValue: 100, target: nil, action: nil)
    let scroll = NSScrollView()
    var window: NSWindow!
    var counter = 0
    var submissions = 0
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 460, height: 530),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HeyMate Cua comparison fixture"
        field.frame = NSRect(x: 24, y: 470, width: 400, height: 30)
        field.setAccessibilityLabel("Benchmark text")
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        let button = NSButton(title: "Increment counter", target: self, action: #selector(increment))
        button.frame = NSRect(x: 24, y: 410, width: 200, height: 32)
        window.contentView!.addSubview(field)
        window.contentView!.addSubview(button)
        scroll.frame = NSRect(x: 24, y: 130, width: 400, height: 250)
        scroll.hasVerticalScroller = true
        let document = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 1800))
        document.string = (1...80).map { "Synthetic scrolling line \($0)" }.joined(separator: "\n")
        document.isEditable = false
        scroll.documentView = document
        window.contentView!.addSubview(scroll)
        slider.frame = NSRect(x: 24, y: 55, width: 380, height: 30)
        slider.setAccessibilityLabel("Benchmark slider")
        window.contentView!.addSubview(slider)
        window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.record() }
        record()
    }

    @objc func increment() { counter += 1; record() }
    @objc func submit() { submissions += 1; record() }
    func controlTextDidChange(_ notification: Notification) { record() }

    func record() {
        let state: [String: Any] = ["text": field.stringValue, "counter": counter,
                                  "submissions": submissions, "slider": slider.doubleValue,
                                  "scroll_y": scroll.contentView.bounds.origin.y,
                                  "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let fixture = Fixture()
application.delegate = fixture
application.run()
