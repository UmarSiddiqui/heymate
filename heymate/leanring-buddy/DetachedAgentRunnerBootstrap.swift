//
//  DetachedAgentRunnerBootstrap.swift
//  leanring-buddy
//
//  Spawns HeyMate's signed embedded runner and sends one sensitive launch
//  request over an inherited pipe. argv contains only identifiers and an FD.
//

import Darwin
import Foundation

nonisolated enum DetachedAgentRunnerBootstrapError: Error, Equatable {
    case invalidExecutablePath
    case pipeCreationFailed(Int32)
    case descriptorDuplicationFailed(Int32)
    case spawnFailed(Int32)
    case fileActionFailed(Int32)
    case attributeFailed(Int32)
}

nonisolated enum DetachedAgentRunnerBootstrap {
    /// Runner gets a new process group and no stdio connection to app. Closing
    /// app therefore cannot close CLI pipes or deliver an accidental signal.
    @discardableResult
    static func spawn(
        executableURL: URL,
        request: DetachedAgentLaunchRequest,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int32 {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            throw DetachedAgentRunnerBootstrapError.invalidExecutablePath
        }

        var pipeDescriptors: [Int32] = [0, 0]
        guard Darwin.pipe(&pipeDescriptors) == 0 else {
            throw DetachedAgentRunnerBootstrapError.pipeCreationFailed(errno)
        }
        var readDescriptor = pipeDescriptors[0]
        var writeDescriptor = pipeDescriptors[1]
        if readDescriptor <= DetachedAgentRunnerInvocation.inheritedBootstrapFileDescriptor {
            let duplicate = fcntl(readDescriptor, F_DUPFD_CLOEXEC, 4)
            guard duplicate >= 0 else {
                Darwin.close(readDescriptor)
                Darwin.close(writeDescriptor)
                throw DetachedAgentRunnerBootstrapError.descriptorDuplicationFailed(errno)
            }
            Darwin.close(readDescriptor)
            readDescriptor = duplicate
        }
        if writeDescriptor <= DetachedAgentRunnerInvocation.inheritedBootstrapFileDescriptor {
            let duplicate = fcntl(writeDescriptor, F_DUPFD_CLOEXEC, 4)
            guard duplicate >= 0 else {
                Darwin.close(readDescriptor)
                Darwin.close(writeDescriptor)
                throw DetachedAgentRunnerBootstrapError.descriptorDuplicationFailed(errno)
            }
            Darwin.close(writeDescriptor)
            writeDescriptor = duplicate
        }
        _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeDescriptor, F_SETNOSIGPIPE, 1)

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var processID: pid_t = 0
        var didSpawn = false
        defer {
            Darwin.close(readDescriptor)
            if !didSpawn {
                Darwin.close(writeDescriptor)
            }
        }

        try requireFileActionSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try requireAttributeSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        if readDescriptor == DetachedAgentRunnerInvocation.inheritedBootstrapFileDescriptor {
            try requireFileActionSuccess(
                posix_spawn_file_actions_addinherit_np(&fileActions, readDescriptor)
            )
        } else {
            try requireFileActionSuccess(
                posix_spawn_file_actions_adddup2(
                    &fileActions,
                    readDescriptor,
                    DetachedAgentRunnerInvocation.inheritedBootstrapFileDescriptor
                )
            )
            try requireFileActionSuccess(
                posix_spawn_file_actions_addclose(&fileActions, readDescriptor)
            )
        }
        try requireFileActionSuccess(
            posix_spawn_file_actions_addclose(&fileActions, writeDescriptor)
        )
        // stderr goes to a per-attempt log so a runner that dies before it
        // can journal (a trap, a signal) still leaves a reason behind.
        let standardErrorPath = diagnosticLogURL(attemptID: request.attemptID)?.path ?? "/dev/null"
        for standardDescriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let isStandardError = standardDescriptor == STDERR_FILENO
            let accessMode: Int32 = standardDescriptor == STDIN_FILENO
                ? O_RDONLY
                : (isStandardError ? O_WRONLY | O_CREAT | O_APPEND : O_WRONLY)
            try requireFileActionSuccess(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    standardDescriptor,
                    isStandardError ? standardErrorPath : "/dev/null",
                    accessMode,
                    isStandardError ? 0o600 : 0
                )
            )
        }

        try requireAttributeSuccess(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            )
        )
        try requireAttributeSuccess(posix_spawnattr_setpgroup(&attributes, 0))

        let executablePath = executableURL.path
        let arguments = [
            executablePath,
            DetachedAgentRunnerInvocation.commandLineFlag,
            request.runID.uuidString.lowercased(),
            request.attemptID.uuidString.lowercased(),
            String(DetachedAgentRunnerInvocation.inheritedBootstrapFileDescriptor)
        ]
        var argumentPointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for case let pointer? in argumentPointers { free(pointer) }
        }

        // Runner needs no app-only credentials. Strip same keys child will
        // lose before spawning so secrets never enter runner environment.
        let runnerEnvironment = HeadlessChildEnvironment.build(
            stripping: request.spec.environmentKeysToRemove,
            processEnvironment: environment
        )
        let environmentStrings = runnerEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { strdup($0) }
        environmentPointers.append(nil)
        defer {
            for case let pointer? in environmentPointers { free(pointer) }
        }

        let result = argumentPointers.withUnsafeMutableBufferPointer { argv in
            environmentPointers.withUnsafeMutableBufferPointer { envp in
                posix_spawn(
                    &processID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argv.baseAddress,
                    envp.baseAddress
                )
            }
        }
        guard result == 0 else {
            throw DetachedAgentRunnerBootstrapError.spawnFailed(result)
        }
        didSpawn = true

        let writeHandle = FileHandle(fileDescriptor: writeDescriptor, closeOnDealloc: true)
        do {
            try request.write(to: writeHandle)
            try writeHandle.close()
        } catch {
            // Runner cannot safely continue without complete bootstrap data.
            // Signal only process group created by this spawn.
            Darwin.kill(-processID, SIGKILL)
            var waitStatus: Int32 = 0
            while waitpid(processID, &waitStatus, 0) == -1, errno == EINTR {}
            try? writeHandle.close()
            throw error
        }
        return processID
    }

    /// `~/Library/Logs/HeyMate/agent-runner-<attempt>.log`, or nil when the
    /// folder cannot be made (the runner then falls back to /dev/null).
    static func diagnosticLogURL(
        attemptID: UUID,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logsURL = libraryURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("HeyMate", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: logsURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        return logsURL.appendingPathComponent(
            "agent-runner-\(attemptID.uuidString.lowercased()).log",
            isDirectory: false
        )
    }

    private static func requireFileActionSuccess(_ result: Int32) throws {
        guard result == 0 else {
            throw DetachedAgentRunnerBootstrapError.fileActionFailed(result)
        }
    }

    private static func requireAttributeSuccess(_ result: Int32) throws {
        guard result == 0 else {
            throw DetachedAgentRunnerBootstrapError.attributeFailed(result)
        }
    }
}
