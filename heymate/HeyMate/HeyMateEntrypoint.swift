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
        // Before anything reads or writes a preference.
        HeyMateDataDirectory.protectPreferencesWhileHostingTests()
        HeyMateApp.main()
    }
}
