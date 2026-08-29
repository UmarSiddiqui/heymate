//
//  HeyMateAgentRunnerMain.swift
//  HeyMateAgentRunner
//
//  Command-line-only entrypoint. No AppKit, SwiftUI, LaunchServices, or
//  updater lifecycle is constructed in this process.
//

import Darwin
import Foundation

@main
nonisolated enum HeyMateAgentRunnerMain {
    static func main() {
        guard let invocation = DetachedAgentRunnerInvocation() else {
            let message = "Invalid HeyMateAgentRunner invocation.\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            Darwin.exit(EX_USAGE)
        }
        DetachedAgentRunnerProgram.run(invocation: invocation)
    }
}
