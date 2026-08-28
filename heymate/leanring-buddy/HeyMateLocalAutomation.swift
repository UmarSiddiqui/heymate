//
//  HeyMateLocalAutomation.swift
//  leanring-buddy
//
//  osascript runner + AppleScript string-literal escape. Right size for
//  Reminders/Messages glue. Do not grow this into computer use.
//

import Foundation

nonisolated struct HeyMateLocalAutomationResult: Equatable, Sendable {
    let output: String
    let errorOutput: String
    let terminationStatus: Int32

    var succeeded: Bool { terminationStatus == 0 }
}

nonisolated enum HeyMateLocalAutomation {

    static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func runAppleScript(_ script: String) -> HeyMateLocalAutomationResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-ss", "-e", script]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return HeyMateLocalAutomationResult(
                output: "",
                errorOutput: error.localizedDescription,
                terminationStatus: -1
            )
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return HeyMateLocalAutomationResult(
            output: output.trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            terminationStatus: process.terminationStatus
        )
    }
}
