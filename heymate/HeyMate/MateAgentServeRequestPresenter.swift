import AppKit
import Foundation

/// Native one-time permission and question sheets. Unknown requests, missing
/// foreground windows, withdrawn requests and cancellation never grant access.
@MainActor
final class MateAgentServeRequestPresenter {
    static let shared = MateAgentServeRequestPresenter()
    private var pending: [UUID: (NSAlert, CheckedContinuation<JSONValue?, Never>)] = [:]
    private var presentingRequest = false

    func respond(to request: MateAgentServeSession.ServerRequest) async -> JSONValue? {
        // Parallel tools can ask independently. Show sheets in order rather
        // than silently denying a second legitimate request behind the first.
        while presentingRequest, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        guard !Task.isCancelled, case .object(let params) = request.params else { return nil }
        presentingRequest = true
        defer { presentingRequest = false }
        let hostWindow = (NSApp.keyWindow.flatMap { $0.sheetParent == nil ? $0 : nil })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey && $0.sheetParent == nil })
        let alert = NSAlert()
        let answer: @MainActor () -> JSONValue?
        switch request.method {
        case "approval":
            alert.messageText = "HeyMate Agent requests permission"
            alert.informativeText = Self.approvalDetail(params)
            alert.addButton(withTitle: "Deny")
            alert.addButton(withTitle: "Allow once")
            answer = { .object(["choice": .string("once"), "all": .bool(false)]) }
        case "clarify":
            guard case .array(let questions) = params["questions"], !questions.isEmpty, questions.count <= 8 else { return nil }
            alert.messageText = "HeyMate Agent needs your answer"
            alert.informativeText = "Answer these questions to continue. Cancel stops this request."
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 420, height: 0)
            var fields: [(String, NSTextField)] = []
            for question in questions {
                guard case .object(let item) = question, case .string(let qid) = item["qid"],
                      case .string(let prompt) = item["question"], !qid.isEmpty,
                      !fields.contains(where: { $0.0 == qid }) else { return nil }
                let label = NSTextField(wrappingLabelWithString: String(prompt.prefix(1_000)))
                label.preferredMaxLayoutWidth = 420
                stack.addArrangedSubview(label)
                let labels: [String]
                if case .array(let choices) = item["choices"] {
                    labels = choices.prefix(6).compactMap { value -> String? in
                        if case .string(let text) = value { return String(text.prefix(120)) }
                        return nil
                    }
                } else { labels = [] }
                // Suggested answers are one click; the user can still type their own.
                let field: NSTextField
                if labels.isEmpty { field = NSTextField(string: "") }
                else {
                    let combo = NSComboBox(string: "")
                    combo.addItems(withObjectValues: labels)
                    combo.completes = true
                    field = combo
                }
                field.placeholderString = labels.isEmpty ? "Your answer" : "Pick a choice or type your own"
                field.setAccessibilityLabel(prompt)
                field.widthAnchor.constraint(equalToConstant: 420).isActive = true
                stack.addArrangedSubview(field)
                fields.append((qid, field))
            }
            stack.layoutSubtreeIfNeeded()
            stack.setFrameSize(NSSize(width: 420, height: max(60, stack.fittingSize.height)))
            alert.accessoryView = stack
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Continue")
            answer = {
                let values = Dictionary(uniqueKeysWithValues: fields.map { qid, field in
                    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (qid, text.isEmpty ? JSONValue.null : .string(String(text.prefix(8_000))))
                })
                return .object(["answers": .object(values)])
            }
        default:
            return nil
        }
        // The notch often has no window that can host a sheet. Denying in that
        // case shows the user nothing and the tool reports "not approved".
        // A modal dialog still asks.
        guard let hostWindow, hostWindow.attachedSheet == nil else {
            let response = alert.runModal()
            return response == .alertSecondButtonReturn ? answer() : nil
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                pending[request.localID] = (alert, continuation)
                alert.beginSheetModal(for: hostWindow) { [weak self] response in
                    self?.finish(request.localID, value: response == .alertSecondButtonReturn ? answer() : nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(request.localID) }
        }
    }

    func withdraw(_ id: UUID) { finish(id, value: nil) }

    private func finish(_ id: UUID, value: JSONValue?) {
        guard let (alert, continuation) = pending.removeValue(forKey: id) else { return }
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
        alert.window.orderOut(nil)
        continuation.resume(returning: value)
    }

    private static func approvalDetail(_ fields: [String: JSONValue]) -> String {
        var parts: [String] = []
        for key in ["description", "command", "reason", "title"] {
            if case .string(let value) = fields[key], !value.isEmpty { parts.append(value) }
        }
        return String((parts.isEmpty ? "HeyMate Agent asks to perform an operation. Allow only if you recognize this request." : parts.joined(separator: "\n\n")).prefix(4_000))
    }
}
