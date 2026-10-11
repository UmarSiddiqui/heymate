//
//  DictationVocabulary.swift
//  HeyMate
//
//  Dictation that learns from the user's fixes. After HeyMate types a
//  dictation into a field, it watches that same field for a short while.
//  When the user swaps one word of what was inserted for a similar-looking
//  word ("hey mate" → "HeyMate", "Kubernetis" → "Kubernetes"), the corrected
//  word becomes a recognition hint for every later utterance, and once the
//  same fix has been made twice the misheard form is also rewritten in
//  transcripts directly, for engines that ignore hints (the on-device model).
//
//  Only single words are kept, never the surrounding text, and the field is
//  read through the same Accessibility handle insertion used, so secure
//  fields (which insertion refuses) are never observed.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

// MARK: - Detection

/// One word the user replaced in freshly inserted dictation.
nonisolated struct DictationWordCorrection: Equatable {
    let heard: String
    let corrected: String
}

nonisolated enum DictationCorrectionDetector {

    static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]{}")

    /// Compares the field right after insertion with the field now and
    /// returns the correction when the only edit is one word inside the
    /// inserted text turning into a similar word. Anything broader (a new
    /// sentence, a deleted clause, a different word altogether) is the user
    /// writing, not fixing, and returns nil.
    static func correction(
        afterInsertion before: String,
        insertedRange: Range<String.Index>,
        now after: String
    ) -> DictationWordCorrection? {
        guard before != after else { return nil }

        let prefixLength = before.commonPrefix(with: after).count
        let maxSuffix = min(before.count, after.count) - prefixLength
        let suffixLength = min(
            String(before.reversed()).commonPrefix(with: String(after.reversed())).count,
            maxSuffix
        )

        // Widen the changed span in each string out to whole words.
        let beforeWord = wordAround(before, changedFrom: prefixLength, to: before.count - suffixLength)
        let afterWord = wordAround(after, changedFrom: prefixLength, to: after.count - suffixLength)
        guard let beforeWord, let afterWord else { return nil }

        // The fix has to land inside what HeyMate typed.
        guard beforeWord.range.lowerBound >= insertedRange.lowerBound,
              beforeWord.range.upperBound <= insertedRange.upperBound else { return nil }

        let heard = beforeWord.text.trimmingCharacters(in: edgePunctuation)
        let corrected = afterWord.text.trimmingCharacters(in: edgePunctuation)
        guard isPlausibleFix(heard: heard, corrected: corrected) else { return nil }
        return DictationWordCorrection(heard: heard, corrected: corrected)
    }

    /// A real fix keeps the word recognizable. "Their" → "there" style
    /// homophone swaps are too short to be worth learning, and a word that
    /// changes into something unrelated is an edit of meaning.
    static func isPlausibleFix(heard: String, corrected: String) -> Bool {
        guard heard != corrected,
              corrected.count >= 3, corrected.count <= 40,
              heard.count >= 2,
              !corrected.contains(where: \.isWhitespace),
              corrected.contains(where: \.isLetter) else { return false }

        let a = normalizedForComparison(heard)
        let b = normalizedForComparison(corrected)
        if a == b { return true }   // casing or spacing only: "hey mate" → "HeyMate"
        let distance = editDistance(a, b)
        return Double(distance) / Double(max(a.count, b.count)) <= 0.5
    }

    // MARK: Helpers

    private struct Word {
        let text: String
        let range: Range<String.Index>
    }

    /// The text from the start of the word containing `start` to the end of
    /// the word containing `end` (offsets in Characters). Up to two words on
    /// the heard side are allowed so split compounds ("hey mate") can merge.
    private static func wordAround(_ text: String, changedFrom start: Int, to end: Int) -> Word? {
        let characters = Array(text)
        var lower = min(start, characters.count)
        var upper = max(min(end, characters.count), lower)
        while lower > 0, !characters[lower - 1].isWhitespace { lower -= 1 }
        while upper < characters.count, !characters[upper].isWhitespace { upper += 1 }
        let span = String(characters[lower..<upper])
        let words = span.split(whereSeparator: \.isWhitespace)
        guard (1...2).contains(words.count) else { return nil }
        let lowerIndex = text.index(text.startIndex, offsetBy: lower)
        let upperIndex = text.index(text.startIndex, offsetBy: upper)
        return Word(text: span, range: lowerIndex..<upperIndex)
    }

    private static func normalizedForComparison(_ word: String) -> String {
        word.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            previous = current
        }
        return previous[b.count]
    }
}

// MARK: - Store

/// A word the user taught HeyMate by correcting it.
nonisolated struct LearnedDictationWord: Codable, Equatable, Identifiable {
    var word: String
    /// Lowercased forms the engine produced before the user fixed them.
    var misheardForms: [String: Int]
    var learnedAt: Date
    var id: String { word }

    /// Misheard forms seen at least this often are rewritten in transcripts.
    static let rewriteThreshold = 2
}

@MainActor
final class DictationVocabulary: ObservableObject {
    static let shared = DictationVocabulary()

    /// The cap keeps hint lists inside what engines accept (ElevenLabs takes 50).
    static let maximumWords = 40

    @Published private(set) var words: [LearnedDictationWord] = []

    private let fileURL: URL

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent("dictation-vocabulary.json")) {
        self.fileURL = fileURL
        load()
    }

    /// Learned words, newest first, for engines that take recognition hints.
    var keyterms: [String] { words.map(\.word) }

    func learn(_ correction: DictationWordCorrection) {
        let heard = correction.heard.lowercased()
        if let index = words.firstIndex(where: { $0.word == correction.corrected }) {
            var entry = words.remove(at: index)
            entry.misheardForms[heard, default: 0] += 1
            entry.learnedAt = Date()
            words.insert(entry, at: 0)
        } else {
            words.insert(
                LearnedDictationWord(word: correction.corrected, misheardForms: [heard: 1], learnedAt: Date()),
                at: 0
            )
        }
        words = Array(words.prefix(Self.maximumWords))
        save()
        HeyMateLog.log("📖 Dictation learned \"\(correction.corrected)\"")
    }

    func remove(_ word: String) {
        words.removeAll { $0.word == word }
        save()
    }

    func removeAll() {
        words = []
        save()
    }

    /// Rewrites misheard forms the user has corrected repeatedly. Matching is
    /// whole-word and case-insensitive, so "hey mate" is replaced but
    /// "they mated" is not.
    func applyLearnedCorrections(to transcript: String) -> String {
        var result = transcript
        for entry in words {
            for (heard, count) in entry.misheardForms where count >= LearnedDictationWord.rewriteThreshold {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: heard) + "(?![\\p{L}\\p{N}])"
                guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                result = expression.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: entry.word)
                )
            }
        }
        return result
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LearnedDictationWord].self, from: data) else { return }
        words = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(words).write(to: fileURL, options: .atomic)
        } catch {
            HeyMateLog.log("⚠️ Dictation vocabulary couldn't save: \(error.localizedDescription)")
        }
    }
}

// MARK: - Learner

/// Watches the field dictation was just typed into and hands any one-word
/// fix to the vocabulary. One field is watched at a time; a new dictation,
/// a focus change or the end of the window stops the watch.
@MainActor
final class DictationCorrectionLearner {
    static let shared = DictationCorrectionLearner()

    private static let observationWindow: Duration = .seconds(30)
    private static let pollInterval: Duration = .milliseconds(700)
    /// A value has to sit still this long before it counts: mid-word typing
    /// would otherwise read as a fix to a half-typed word.
    private static let settleInterval: Duration = .milliseconds(1400)

    private var observationTask: Task<Void, Never>?

    func observe(_ element: AXUIElement, inserted text: String, vocabulary: DictationVocabulary = .shared) {
        observationTask?.cancel()
        observationTask = nil

        guard let baseline = Self.value(of: element),
              let insertedRange = baseline.range(of: text, options: .backwards) else { return }

        observationTask = Task { @MainActor in
            let clock = ContinuousClock()
            let deadline = clock.now + Self.observationWindow
            var lastSeen = baseline
            var lastChange = clock.now

            while clock.now < deadline {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                guard Self.isStillFocused(element), let current = Self.value(of: element) else { return }

                if current != lastSeen {
                    lastSeen = current
                    lastChange = clock.now
                    continue
                }
                guard current != baseline, clock.now - lastChange >= Self.settleInterval else { continue }

                if let correction = DictationCorrectionDetector.correction(
                    afterInsertion: baseline, insertedRange: insertedRange, now: current
                ) {
                    vocabulary.learn(correction)
                }
                // One verdict per dictation: further edits are the user writing.
                return
            }
        }
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    private static func value(of element: AXUIElement) -> String? {
        var boxedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &boxedValue) == .success else { return nil }
        return boxedValue as? String
    }

    private static func isStillFocused(_ element: AXUIElement) -> Bool {
        var focusedBox: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focusedBox
        ) == .success, let focused = focusedBox else { return false }
        return CFEqual(focused, element)
    }
}
