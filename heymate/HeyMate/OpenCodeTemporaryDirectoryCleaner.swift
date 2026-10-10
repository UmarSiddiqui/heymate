//
//  OpenCodeTemporaryDirectoryCleaner.swift
//  HeyMate
//
//  Descriptor-relative removal for process-private OpenCode scratch homes.
//

import Darwin
import Foundation

nonisolated enum OpenCodeTemporaryDirectoryCleaner {
    private static let expectedOwner = UInt32(getuid())

    /// Removes only direct child directories of HeyMate's OpenCode scratch
    /// root. Unsafe, missing, or raced targets are left untouched.
    static func remove(_ directories: [URL]) {
        let allowedRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.heymate.app", isDirectory: true)
            .appendingPathComponent("opencode-config", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        for directoryURL in directories {
            _ = try? remove(directoryURL, allowedRootURL: allowedRootURL)
        }
    }

    /// Testable core. Caller supplies an already-canonical trusted root; every
    /// path component is then opened relative to its parent with O_NOFOLLOW.
    @discardableResult
    static func remove(
        _ directoryURL: URL,
        allowedRootURL: URL
    ) throws -> Bool {
        let rootURL = normalizeSystemTemporaryAlias(allowedRootURL.standardizedFileURL)
        let targetURL = directoryURL.standardizedFileURL
        let childName = targetURL.lastPathComponent
        guard rootURL.isFileURL,
              targetURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              !childName.isEmpty,
              childName != ".",
              childName != "..",
              !childName.contains("/") else {
            return false
        }

        // Resolve only target's parent. Leaf stays unopened until openat with
        // O_NOFOLLOW, so a symlink leaf can never redirect deletion.
        let targetParentURL = normalizeSystemTemporaryAlias(
            targetURL.deletingLastPathComponent().standardizedFileURL
        )
        guard targetParentURL.path == rootURL.path else { return false }

        let rootDescriptor: Int32
        do {
            rootDescriptor = try openDirectoryHierarchy(rootURL)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && [Int(ELOOP), Int(ENOTDIR), Int(ENOENT)].contains(error.code) {
            return false
        }
        defer { Darwin.close(rootDescriptor) }
        let rootInformation = try validatedDirectory(
            descriptor: rootDescriptor,
            expectedDevice: nil,
            requirePrivatePermissions: true
        )

        let childDescriptor = childName.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard childDescriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return false }
            throw posixError("open scratch child")
        }
        defer { Darwin.close(childDescriptor) }
        let childInformation = try validatedDirectory(
            descriptor: childDescriptor,
            expectedDevice: rootInformation.st_dev,
            requirePrivatePermissions: true
        )

        try removeContents(
            of: childDescriptor,
            expectedDevice: rootInformation.st_dev
        )

        // Confirm root name still identifies opened inode before removing it.
        guard try entryStillMatches(
            parentDescriptor: rootDescriptor,
            name: childName,
            expected: childInformation
        ) else {
            return false
        }
        let unlinkResult = childName.withCString {
            Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
        }
        guard unlinkResult == 0 else {
            if errno == ENOENT { return false }
            throw posixError("remove scratch child")
        }
        guard Darwin.fsync(rootDescriptor) == 0 else {
            throw posixError("fsync scratch root")
        }
        return true
    }

    private static func openDirectoryHierarchy(_ directoryURL: URL) throws -> Int32 {
        let components = directoryURL.pathComponents.filter { $0 != "/" }
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw posixError("open filesystem root") }

        do {
            for component in components {
                let nextDescriptor = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    throw posixError("open scratch root component")
                }
                Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// macOS exposes trusted `/tmp` and `/var` aliases as root-owned symlinks.
    /// Normalize only those fixed aliases; arbitrary caller-controlled
    /// symlinks remain in the hierarchy and fail O_NOFOLLOW traversal.
    private static func normalizeSystemTemporaryAlias(_ url: URL) -> URL {
        let path = url.path
        if path == "/tmp" || path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: true)
        }
        if path == "/var" || path.hasPrefix("/var/") {
            return URL(fileURLWithPath: "/private" + path, isDirectory: true)
        }
        return url
    }

    private static func removeContents(
        of directoryDescriptor: Int32,
        expectedDevice: dev_t
    ) throws {
        let enumerationDescriptor = Darwin.dup(directoryDescriptor)
        guard enumerationDescriptor >= 0 else { throw posixError("duplicate scratch directory") }
        guard let directoryStream = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            throw posixError("enumerate scratch directory")
        }
        defer { Darwin.closedir(directoryStream) }

        while let entry = Darwin.readdir(directoryStream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            try removeEntry(
                named: name,
                from: directoryDescriptor,
                expectedDevice: expectedDevice
            )
        }
    }

    private static func removeEntry(
        named name: String,
        from parentDescriptor: Int32,
        expectedDevice: dev_t
    ) throws {
        var entryInformation = stat()
        let statusResult = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &entryInformation, AT_SYMLINK_NOFOLLOW)
        }
        guard statusResult == 0 else {
            if errno == ENOENT { return }
            throw posixError("inspect scratch entry")
        }
        guard entryInformation.st_dev == expectedDevice else { return }

        if entryInformation.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
            let childDescriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard childDescriptor >= 0 else {
                if errno == ENOENT || errno == ELOOP || errno == ENOTDIR { return }
                throw posixError("open nested scratch directory")
            }
            defer { Darwin.close(childDescriptor) }
            let openedInformation = try validatedDirectory(
                descriptor: childDescriptor,
                expectedDevice: expectedDevice,
                requirePrivatePermissions: false
            )
            guard sameFile(entryInformation, openedInformation) else { return }
            try removeContents(of: childDescriptor, expectedDevice: expectedDevice)
            guard try entryStillMatches(
                parentDescriptor: parentDescriptor,
                name: name,
                expected: openedInformation
            ) else {
                return
            }
            let removeResult = name.withCString {
                Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            guard removeResult == 0 || errno == ENOENT else {
                throw posixError("remove nested scratch directory")
            }
            return
        }

        // unlinkat removes a symlink itself; no target path is ever followed.
        let removeResult = name.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        guard removeResult == 0 || errno == ENOENT else {
            throw posixError("remove scratch entry")
        }
    }

    private static func validatedDirectory(
        descriptor: Int32,
        expectedDevice: dev_t?,
        requirePrivatePermissions: Bool
    ) throws -> stat {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw posixError("inspect scratch directory")
        }
        guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              information.st_uid == expectedOwner else {
            throw POSIXError(.EPERM)
        }
        if let expectedDevice, information.st_dev != expectedDevice {
            throw POSIXError(.EXDEV)
        }
        if requirePrivatePermissions,
           information.st_mode & 0o077 != 0 {
            throw POSIXError(.EPERM)
        }
        return information
    }

    private static func entryStillMatches(
        parentDescriptor: Int32,
        name: String,
        expected: stat
    ) throws -> Bool {
        var current = stat()
        let result = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &current, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw posixError("revalidate scratch entry")
        }
        return sameFile(current, expected)
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: operation]
        )
    }
}
