//
//  HeyMateEntrypoint.swift
//  HeyMate
//
//  Explicit entrypoint starts only SwiftUI. Detached work belongs to
//  HeyMateAgentRunner, never to app's LaunchServices identity.
//

import Darwin
import Foundation
import SwiftUI

@main
nonisolated enum HeyMateEntrypoint {
    static func main() {
        if DetachedAgentRunnerInvocation.containsRunnerFlag() {
            let message = "HeyMate cannot run agent-helper mode.\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            Darwin.exit(EX_USAGE)
        }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--appearance-render"),
           CommandLine.arguments.indices.contains(index + 1) {
            do { try MainActor.assumeIsolated { try CompanionAppearancePreview.render(to: CommandLine.arguments[index + 1]) } }
            catch { fputs("Appearance render failed: \(error)\n", stderr); Darwin.exit(EXIT_FAILURE) }
            return
        }
        if CommandLine.arguments.contains("--appearance-preview") {
            MainActor.assumeIsolated { CompanionAppearancePreview.run() }
            return
        }
        #endif
        // Before anything reads or writes a preference.
        HeyMateDataDirectory.protectPreferencesWhileHostingTests()
        HeyMateApp.main()
    }
}
