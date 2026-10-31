//
//  DriveFastLane.swift
//  HeyMate
//
//  Steps a drive can take without asking the model.
//
//  A drive step through the agent costs about three seconds. Two things
//  skip it: a short queue of button labels (from the model's own plan, or
//  read straight out of a sum in the goal), run one press at a time while
//  each fresh snapshot still shows the next label, and a deterministic
//  check that the result is on screen. Every queued press goes through
//  `DriveEngine.vet` like any other step; nothing here acts on its own.
//  When a label is missing or ambiguous the queue is dropped and the model
//  decides.
//

import Foundation

/// Labels still to press, in order, plus what the window should show after.
nonisolated struct DrivePlan: Equatable, Sendable {
    var labels: [String]
    /// The text a finished plan should leave in the window, when known.
    var expectedResult: String?
    /// "plan" for the model's own, "sum" for one read from the goal.
    var source: String

    var isEmpty: Bool { labels.isEmpty }
}

enum DriveFastLane {
    nonisolated static let maximumPlannedSteps = 16

    // MARK: Resolving a label

    private nonisolated static let aliases: [String: [String]] = [
        "multiply": ["multiply", "multiplication", "×", "*", "times", "x"],
        "add": ["add", "plus", "+"],
        "subtract": ["subtract", "minus", "−", "-", "–"],
        "divide": ["divide", "division", "÷", "/"],
        "equals": ["equals", "equal", "="],
        "decimal": ["decimal point", "decimal", ".", ","],
    ]

    private nonisolated static func canonical(_ label: String) -> String {
        AccessibilityElementFinder.normalize(label).lowercased()
    }

    /// The one element a queued label names, nil when none or several do.
    /// Only buttons and similar controls count; a text field that happens to
    /// hold "3" is not the "3" key.
    static func resolve(_ label: String, in snapshot: DriveSnapshot) -> DriveElement? {
        let wanted = canonical(label)
        guard !wanted.isEmpty else { return nil }
        let names = Set([wanted] + (aliases.first { $0.key == wanted || $0.value.contains(wanted) }?.value ?? []))
        let matches = snapshot.elements.filter { !$0.isTextEntry && names.contains(canonical($0.label)) }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: Sums in the goal

    /// "work out 9 times 3" → press 9, multiply, 3, equals; expect 27.
    /// Nil unless the window has every key the sum needs plus equals, so a
    /// date or a phone number in some other app's goal never matches.
    static func plan(forGoal goal: String, in snapshot: DriveSnapshot) -> DrivePlan? {
        guard let sum = parseSum(goal) else { return nil }
        var labels: [String] = []
        for token in sum.tokens {
            switch token {
            case .number(let text): labels.append(contentsOf: text.map { $0 == "." ? "decimal" : String($0) })
            case .operation(let name): labels.append(name)
            }
        }
        labels.append("equals")
        guard labels.count <= maximumPlannedSteps,
              labels.allSatisfy({ resolve($0, in: snapshot) != nil }) else { return nil }
        return DrivePlan(labels: labels, expectedResult: sum.result, source: "sum")
    }

    nonisolated enum SumToken: Equatable { case number(String), operation(String) }

    nonisolated struct Sum: Equatable {
        let tokens: [SumToken]
        /// Only for one operation with a whole-number answer.
        let result: String?
    }

    nonisolated static func parseSum(_ goal: String) -> Sum? {
        let number = #"\d+(?:\.\d+)?"#
        let op = #"plus|minus|times|multiplied by|divided by|\+|-|−|×|x|\*|÷|/"#
        let pattern = "(?<![\\w.])" + number + "(?:\\s*(?:" + op + ")\\s*" + number + ")+(?![\\w.])"
        guard let range = goal.lowercased().range(of: pattern, options: .regularExpression) else { return nil }
        let expression = String(goal.lowercased()[range])
        let scanner = try? NSRegularExpression(pattern: "(" + number + ")|(" + op + ")")
        let whole = NSRange(expression.startIndex..., in: expression)
        var tokens: [SumToken] = []
        scanner?.enumerateMatches(in: expression, range: whole) { match, _, _ in
            guard let match, let found = Range(match.range, in: expression) else { return }
            let text = String(expression[found])
            if Range(match.range(at: 1), in: expression) != nil {
                tokens.append(.number(text))
            } else {
                let name: String
                switch text {
                case "plus", "+": name = "add"
                case "minus", "-", "−": name = "subtract"
                case "times", "multiplied by", "×", "x", "*": name = "multiply"
                default: name = "divide"
                }
                tokens.append(.operation(name))
            }
        }
        guard tokens.count >= 3, tokens.count % 2 == 1 else { return nil }
        var result: String?
        if tokens.count == 3, case .number(let left) = tokens[0], case .operation(let name) = tokens[1],
           case .number(let right) = tokens[2], let a = Double(left), let b = Double(right) {
            let value: Double?
            switch name {
            case "add": value = a + b
            case "subtract": value = a - b
            case "multiply": value = a * b
            default: value = b == 0 ? nil : a / b
            }
            if let value, value >= 0, value == value.rounded(), value < 1e12 { result = String(Int(value)) }
        }
        return Sum(tokens: tokens, result: result)
    }

    /// True when some text in the window is exactly the expected result,
    /// ignoring digit grouping and the invisible marks Calculator adds.
    static func windowShows(_ result: String, in snapshot: DriveSnapshot) -> Bool {
        snapshot.visibleStrings.contains { text in
            let plain = text.filter { "0123456789.-".contains($0) }
            return !plain.isEmpty && plain == result && text.filter(\.isLetter).isEmpty
        }
    }
}
