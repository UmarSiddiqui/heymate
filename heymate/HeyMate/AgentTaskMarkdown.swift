//
//  AgentTaskMarkdown.swift
//  HeyMate
//
//  The prompt file left in the workspace so a human can reopen the folder
//  and see what was asked. The same task text is also passed as a CLI
//  argument — TASK.md is documentation, not the only input.
//

import Foundation

nonisolated enum AgentTaskMarkdown {

    /// A sandbox is a folder HeyMate created for this job, so leaving the
    /// brief there is useful. An attached folder belongs to the user; even a
    /// TASK.md file would dirty it before plan approval.
    static func shouldPersist(in origin: AgentRunOrigin) -> Bool {
        origin == .sandbox
    }

    static func contents(
        title: String,
        prompt: String,
        executor: HeadlessExecutor,
        workspaceURL: URL,
        createdAt: Date,
        screenContext: AgentScreenContext
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return """
        # \(title)

        Executor: \(executor.displayName)
        Workspace: \(workspaceURL.path)
        Created: \(formatter.string(from: createdAt))

        ## Task

        \(prompt)

        ## Context

        Active app: \(screenContext.activeAppName)
        Window title: \(screenContext.windowTitle)
        """
    }

    static func write(
        to workspaceURL: URL,
        title: String,
        prompt: String,
        executor: HeadlessExecutor,
        createdAt: Date,
        screenContext: AgentScreenContext,
        fileManager: FileManager = .default
    ) throws {
        let markdown = contents(
            title: title,
            prompt: prompt,
            executor: executor,
            workspaceURL: workspaceURL,
            createdAt: createdAt,
            screenContext: screenContext
        )
        let fileURL = workspaceURL.appendingPathComponent("TASK.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
