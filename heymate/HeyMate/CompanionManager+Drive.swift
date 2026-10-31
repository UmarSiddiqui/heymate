//
//  CompanionManager+Drive.swift
//  HeyMate
//
//  Where drives come in: a Talk reply's `[ACT:drive:App|goal]`, and the
//  local bridge's `/drive/offer` (which is how a spawned agent asks).
//

import Foundation

extension CompanionManager {

    /// Runs every drive directive in a finished reply, one after another,
    /// and returns what happened for the chat. Nil when there are none.
    func performDriveDirectives(in responseText: String) async -> String? {
        let requests = DriveDirectiveParser.requests(in: responseText)
        guard !requests.isEmpty else { return nil }
        var reports: [String] = []
        for request in requests {
            guard !Task.isCancelled else { break }
            driveController.currentTurnToken = currentChat.id.uuidString
            let outcome = await driveController.run(request)
            reports.append(outcome.report)
        }
        return reports.joined(separator: "\n")
    }

    /// Bridge entry. Refused while computer control is off, so a switched-off
    /// Mac never even shows the card.
    func offerDrive(_ request: DriveRequest) -> LocalControlResponse {
        guard computerUseCoordinator.isEnabled else {
            return .error(403, "Computer control is switched off in HeyMate Settings.")
        }
        guard let identifier = driveController.offer(request) else {
            return .error(409, "Another drive is already running.")
        }
        return .accepted(["driveIdentifier": identifier, "phase": "offered"])
    }
}

/// `[ACT:drive:App name|goal sentence]`, or `[ACT:drive:goal]` for the app
/// in front. `ComputerUseTagParser` leaves the `drive` verb alone, and the
/// guided parser strips every `[ACT…]` tag from what is spoken.
nonisolated enum DriveDirectiveParser {
    static func requests(in text: String) -> [DriveRequest] {
        guard let expression = try? NSRegularExpression(pattern: #"\[ACT:\s*drive\s*:([^\]]+)\]"#, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let bodyRange = Range(match.range(at: 1), in: text) else { return nil }
            let body = String(text[bodyRange])
            let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let (app, goal) = parts.count == 2 ? (parts[0], parts[1]) : (nil, parts.first ?? "")
            guard !goal.isEmpty else { return nil }
            return DriveRequest(goal: goal, applicationName: app?.isEmpty == false ? app : nil, origin: "talk")
        }
    }
}
