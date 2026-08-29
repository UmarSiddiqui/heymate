//
//  OpenCodeTemporaryDirectoryCleanerTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct OpenCodeTemporaryDirectoryCleanerTests {
    private func makeRoot() throws -> (base: URL, root: URL) {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeCleanerTests-\(UUID().uuidString)", isDirectory: true)
        let rootURL = baseURL
            .appendingPathComponent("com.heymate.app", isDirectory: true)
            .appendingPathComponent("opencode-config", isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
        return (baseURL, rootURL.resolvingSymlinksInPath())
    }

    @Test func removesOnlyRequestedDirectChildWithoutFollowingContainedSymlink() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outsideURL = fixture.base.appendingPathComponent("outside", isDirectory: true)
        let outsideFileURL = outsideURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideFileURL)

        let targetURL = fixture.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let siblingURL = fixture.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nestedURL = targetURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: targetURL.path
        )
        try Data("scratch".utf8).write(to: nestedURL.appendingPathComponent("scratch.txt"))
        try FileManager.default.createSymbolicLink(
            at: targetURL.appendingPathComponent("outside-link"),
            withDestinationURL: outsideURL
        )
        try FileManager.default.createDirectory(
            at: siblingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        #expect(try OpenCodeTemporaryDirectoryCleaner.remove(
            targetURL,
            allowedRootURL: fixture.root
        ))
        #expect(!FileManager.default.fileExists(atPath: targetURL.path))
        #expect(FileManager.default.fileExists(atPath: siblingURL.path))
        #expect(FileManager.default.fileExists(atPath: outsideFileURL.path))
    }

    @Test func rejectsOutsideNestedAndSymlinkLeafTargets() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let outsideURL = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directURL = fixture.root.appendingPathComponent("direct", isDirectory: true)
        let nestedURL = directURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directURL.path
        )
        let symlinkURL = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideURL
        )

        #expect(try !OpenCodeTemporaryDirectoryCleaner.remove(
            outsideURL,
            allowedRootURL: fixture.root
        ))
        #expect(try !OpenCodeTemporaryDirectoryCleaner.remove(
            nestedURL,
            allowedRootURL: fixture.root
        ))
        #expect(try !OpenCodeTemporaryDirectoryCleaner.remove(
            symlinkURL,
            allowedRootURL: fixture.root
        ))
        #expect(FileManager.default.fileExists(atPath: outsideURL.path))
        #expect(FileManager.default.fileExists(atPath: nestedURL.path))
        #expect(FileManager.default.fileExists(atPath: symlinkURL.path))
    }

    @Test func rejectsSymbolicLinkInAllowedRootHierarchy() throws {
        let fixture = try makeRoot()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let rootLinkURL = fixture.base.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: rootLinkURL,
            withDestinationURL: fixture.root
        )
        let targetURL = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        #expect(try !OpenCodeTemporaryDirectoryCleaner.remove(
            rootLinkURL.appendingPathComponent("target", isDirectory: true),
            allowedRootURL: rootLinkURL
        ))
        #expect(FileManager.default.fileExists(atPath: targetURL.path))
    }
}
