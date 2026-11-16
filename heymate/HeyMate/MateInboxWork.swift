import Foundation

/// A private, bounded receipt for one turn. The receipt keeps display labels
/// and known failure reasons without storing tool payloads or provider reasoning.
nonisolated struct MateInboxWork: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case running, needsInput, resultReady, failed, stopped, resumed

        var title: String {
            switch self {
            case .running: "Working"
            case .needsInput: "Waiting on you"
            case .resultReady: "Result ready"
            case .failed: "Couldn't finish"
            case .stopped: "Stopped"
            case .resumed: "Resumed"
            }
        }
    }

    enum Action: Equatable {
        case resume, retry, followUp

        var title: String {
            switch self {
            case .resume: "Continue"
            case .retry: "Retry failed step"
            case .followUp: "Follow up"
            }
        }
    }

    struct Step: Codable, Equatable, Identifiable {
        enum State: String, Codable {
            case running, finished, failed, stopped, notice

            var title: String {
                switch self {
                case .running: "In progress"
                case .finished: "Returned"
                case .failed: "Failed"
                case .stopped: "Interrupted"
                case .notice: "Update"
                }
            }
        }

        enum Failure: String, Codable {
            case missingFile = "missing_file"
            case inaccessibleFile = "inaccessible_file"
            case expectedFile = "expected_file"
            case denied
            case uncertain
            case browserHeld = "browser_held"
            case browserPageChanged = "browser_page_changed"
            case browserTimeout = "browser_timeout"

            var message: String {
                switch self {
                case .missingFile: "File not found. Restore it at the original location before retrying."
                case .inaccessibleFile: "Access denied. Check the file’s permissions before retrying."
                case .expectedFile: "This location is a folder. Follow up with the file to use."
                case .denied: "Permission was declined. Review the request if you choose to retry."
                case .uncertain: "The action may already have run. Check the outcome before retrying."
                case .browserHeld: "You have control of the browser. Use Hand back before retrying."
                case .browserPageChanged: "The page changed. The Mate needs to inspect it again."
                case .browserTimeout: "The expected page did not appear. Check the browser before retrying."
                }
            }

            static func scopedToolError(_ text: String) -> Self? {
                if text.hasPrefix("You have control of this Mate's browser") { return .browserHeld }
                if text.hasPrefix("Stale or foreign element ref.") { return .browserPageChanged }
                if text.hasPrefix("Timed out waiting for expected page.") { return .browserTimeout }
                if text.hasPrefix("Browser access declined.") || text.hasPrefix("Browser step declined.") { return .denied }
                if text.hasPrefix("Isolated browser stopped:") { return .uncertain }
                return nil
            }
        }

        let id: String
        var title: String
        var state: State
        let date: Date
        var item: String?
        var failure: Failure?

        var displayTitle: String {
            item.map { "\(title) · \($0)" } ?? title
        }
    }

    let id: UUID
    let mateID: UUID
    let chatID: UUID
    let mateName: String
    let title: String
    let background: Bool
    var originalWorkID: UUID?
    var updatedAt = Date()
    var state: State = .running
    var steps: [Step] = []
    var result: String?
    var resultKey: String?
    var plan: String?

    var isVisible: Bool {
        background || plan != nil || !steps.isEmpty || state == .needsInput || state == .failed
    }

    var currentStep: Step? { steps.last { $0.state == .running } }
    var lastFailedStep: Step? { steps.last { $0.state == .failed } }
    var finishedStepCount: Int { steps.filter { $0.state == .finished }.count }
    var taskID: UUID { originalWorkID ?? id }

    var displayState: State {
        if state == .resultReady, steps.last(where: { $0.state != .notice })?.state == .failed {
            return .failed
        }
        return state
    }

    var actions: [Action] {
        switch displayState {
        case .running, .resumed: []
        case .needsInput: [.resume]
        case .failed, .stopped:
            lastFailedStep == nil ? [.resume, .followUp] : [.resume, .retry, .followUp]
        case .resultReady: [.followUp]
        }
    }

    func checkpointPrompt(instruction: String) -> String {
        let history = steps.suffix(16).map { "- \($0.displayTitle): \($0.state.title)" }.joined(separator: "\n")
        return """
        Resume the same task in this chat: \(title)

        Last attempt's steps:
        \(history.isEmpty ? "No tool steps recorded." : history)

        Last report:
        \(result ?? "No report recorded.")

        Use the previous chat and tool results as the checkpoint. Keep completed work and use its existing outputs. Do not rerun successful actions or recreate their outputs. Inspect the current state before repeating any interrupted action or action with an uncertain outcome.

        Current instruction: \(instruction)
        """
    }

    mutating func record(event: String, payload: JSONValue?) {
        let fields: [String: JSONValue]
        if case .object(let values) = payload { fields = values }
        else { fields = [:] }
        if event == "agent.opener", case .string(let text) = fields["text"] {
            plan = Self.safeText(text, limit: 280)
        } else if event == "tool.start" || event == "tool.end" {
            guard case .string(let id) = fields["tool_call_id"], !id.isEmpty,
                  case .string(let name) = fields["name"], !name.hasPrefix("hm_") else { return }
            let status: Step.State = event == "tool.start" ? .running
                : (fields["is_error"] == .bool(true) ? .failed : .finished)
            let item: String?
            if ["read", "write", "edit"].contains(name), case .string(let value) = fields["file_name"] {
                item = value.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
                    .map { Self.safeText(String($0).components(separatedBy: .newlines).first ?? "", limit: 120) }
            } else {
                item = nil
            }
            let failure: Step.Failure?
            if status == .failed, case .string(let value) = fields["failure_code"] {
                failure = Step.Failure(rawValue: value)
            } else {
                failure = nil
            }
            recordStep(id: id, title: Self.toolTitle(name), state: status, item: item, failure: failure)
        } else if event == "connection.reconnecting" {
            recordStep(id: UUID().uuidString, title: "Reconnecting to agent", state: .notice)
        } else if event == "request.expired" || event == "request.disconnected" {
            recordStep(id: UUID().uuidString, title: event == "request.expired"
                ? "Request expired before it was answered" : "Request closed when the agent disconnected", state: .failed)
        }
    }

    mutating func recordStep(id: String, title: String, state: Step.State, item: String? = nil, failure: Step.Failure? = nil) {
        if let index = steps.firstIndex(where: { $0.id == id }) {
            steps[index].state = state
            steps[index].title = title
            if let item, !item.isEmpty { steps[index].item = item }
            steps[index].failure = failure
        } else {
            steps.append(Step(id: id, title: title, state: state, date: Date(), item: item, failure: failure))
            if steps.count > 36 { steps.removeFirst(steps.count - 36) }
        }
        updatedAt = Date()
    }

    mutating func finish(_ state: State, result: String?) {
        self.state = state
        self.result = result
        for index in steps.indices where steps[index].state == .running {
            steps[index].state = .stopped
        }
        updatedAt = Date()
    }

    static func toolTitle(_ name: String) -> String {
        switch name {
        case "read": return "Read a local file"
        case "write": return "Write a local file"
        case "edit": return "Edit a local file"
        case "bash": return "Run a shell command"
        case "ask_user", "ask_person": return "Ask you a question"
        case "send_to_mate": return "Hand work to another Mate"
        case "manage_routines": return "Manage a routine"
        case "create_mate": return "Create a Mate"
        case "note_read": return "Read the task note"
        case "use_browser", "use_chrome": return "Use the browser"
        default: return String(name.prefix(100)).replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func safeText(_ text: String, limit: Int) -> String {
        String(AgentReceiptPrivacy.privateAnswer(text).prefix(limit))
    }
}

/// The store keeps attempts in start order, newest first. A recent update to
/// an older attempt must not replace the currently running attempt.
nonisolated struct MateInboxTaskActivity: Identifiable {
    let current: MateInboxWork
    let earlier: [MateInboxWork]

    var id: UUID { current.taskID }

    static func group(_ work: [MateInboxWork]) -> [Self] {
        Dictionary(grouping: work.filter(\.isVisible), by: \.taskID).values.compactMap { attempts in
            guard let current = attempts.first else { return nil }
            return Self(current: current, earlier: Array(attempts.dropFirst()))
        }.sorted {
            if $0.current.updatedAt == $1.current.updatedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.current.updatedAt > $1.current.updatedAt
        }
    }
}
