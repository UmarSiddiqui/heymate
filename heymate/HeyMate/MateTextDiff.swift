//
//  MateTextDiff.swift
//  HeyMate
//
//  Line diff for a file's version history. Common lines at both ends are
//  matched directly; the middle uses a longest-common-subsequence table,
//  bounded so a huge file falls back to "all removed, all added".
//

import Foundation

nonisolated enum MateDiffLine: Equatable, Sendable {
    case same(String)
    case removed(String)
    case added(String)
    /// Unchanged lines folded away in the compact view.
    case skipped(Int)
}

nonisolated enum MateTextDiff {
    static let maximumCells = 4_000_000

    /// UTF-8 without NUL bytes in its first 8 KB.
    static func text(from data: Data) -> String? {
        guard !data.prefix(8_192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    static func lines(old: String, new: String, maximumCells: Int = maximumCells) -> [MateDiffLine] {
        let a = split(old)
        let b = split(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let middleA = Array(a[prefix..<(a.count - suffix)])
        let middleB = Array(b[prefix..<(b.count - suffix)])
        var result: [MateDiffLine] = a[..<prefix].map { .same($0) }
        result += middle(middleA, middleB, maximumCells: maximumCells)
        result += a[(a.count - suffix)...].map { .same($0) }
        return result
    }

    private static func middle(_ a: [String], _ b: [String], maximumCells: Int) -> [MateDiffLine] {
        if a.isEmpty { return b.map { .added($0) } }
        if b.isEmpty { return a.map { .removed($0) } }
        guard a.count * b.count <= maximumCells else {
            return a.map { .removed($0) } + b.map { .added($0) }
        }
        let width = b.count + 1
        var table = [Int32](repeating: 0, count: (a.count + 1) * width)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i * width + j] = a[i] == b[j]
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
            }
        }
        var result: [MateDiffLine] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(.same(a[i])); i += 1; j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                result.append(.removed(a[i])); i += 1
            } else {
                result.append(.added(b[j])); j += 1
            }
        }
        result += a[i...].map { .removed($0) }
        result += b[j...].map { .added($0) }
        return result
    }

    /// Keeps `context` unchanged lines around each change and folds the rest.
    static func compact(_ lines: [MateDiffLine], context: Int = 3) -> [MateDiffLine] {
        let changed = lines.indices.filter {
            if case .same = lines[$0] { return false }
            return true
        }
        guard !changed.isEmpty else { return lines.isEmpty ? [] : [.skipped(lines.count)] }
        var keep = Set<Int>()
        for index in changed {
            for near in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(near) }
        }
        var result: [MateDiffLine] = []
        var run = 0
        for index in lines.indices {
            if keep.contains(index) {
                if run > 0 { result.append(.skipped(run)); run = 0 }
                result.append(lines[index])
            } else {
                run += 1
            }
        }
        if run > 0 { result.append(.skipped(run)) }
        return result
    }
}
