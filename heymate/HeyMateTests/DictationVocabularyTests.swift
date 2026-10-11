//
//  DictationVocabularyTests.swift
//  HeyMateTests
//
//  Correction detection and the learned-word store. The AX watcher itself
//  is not exercised here.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct DictationVocabularyTests {

    private func detect(field before: String, inserted: String, now after: String) -> DictationWordCorrection? {
        let range = before.range(of: inserted, options: .backwards)!
        return DictationCorrectionDetector.correction(afterInsertion: before, insertedRange: range, now: after)
    }

    // MARK: - Detection

    @Test func learnsMisspelledWordFix() {
        let fix = detect(field: "Deploy to Kubernetis today", inserted: "Deploy to Kubernetis today",
                         now: "Deploy to Kubernetes today")
        #expect(fix == DictationWordCorrection(heard: "Kubernetis", corrected: "Kubernetes"))
    }

    @Test func mergesSplitCompound() {
        let fix = detect(field: "ask hey mate now", inserted: "ask hey mate now", now: "ask HeyMate now")
        #expect(fix == DictationWordCorrection(heard: "hey mate", corrected: "HeyMate"))
    }

    @Test func keepsTrailingPunctuationOutOfTheWord() {
        let fix = detect(field: "Ping umer.", inserted: "Ping umer.", now: "Ping Umar.")
        #expect(fix == DictationWordCorrection(heard: "umer", corrected: "Umar"))
    }

    @Test func ignoresUnrelatedWordSwap() {
        #expect(detect(field: "the cat sat", inserted: "the cat sat", now: "the dog sat") == nil)
    }

    @Test func ignoresAppendedText() {
        #expect(detect(field: "hello there", inserted: "hello there", now: "hello there, friend") == nil)
    }

    @Test func ignoresEditsOutsideInsertedText() {
        let before = "Dear Jon, thanks for the notes"
        #expect(detect(field: before, inserted: "thanks for the notes", now: "Dear John, thanks for the notes") == nil)
    }

    @Test func ignoresShortWords() {
        #expect(DictationCorrectionDetector.isPlausibleFix(heard: "to", corrected: "so") == false)
    }

    @Test func editDistanceCountsSubstitutions() {
        #expect(DictationCorrectionDetector.editDistance("kitten", "sitting") == 3)
    }

    // MARK: - Store

    private func scratchVocabulary() -> DictationVocabulary {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-vocabulary-\(UUID().uuidString).json")
        return DictationVocabulary(fileURL: url)
    }

    @Test func learnedWordBecomesKeytermAndPersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-vocabulary-\(UUID().uuidString).json")
        DictationVocabulary(fileURL: url).learn(.init(heard: "kubernetis", corrected: "Kubernetes"))
        #expect(DictationVocabulary(fileURL: url).keyterms == ["Kubernetes"])
        try? FileManager.default.removeItem(at: url)
    }

    @Test func rewritesOnlyAfterRepeatedFix() {
        let vocabulary = scratchVocabulary()
        vocabulary.learn(.init(heard: "hey mate", corrected: "HeyMate"))
        #expect(vocabulary.applyLearnedCorrections(to: "open hey mate") == "open hey mate")
        vocabulary.learn(.init(heard: "Hey Mate", corrected: "HeyMate"))
        #expect(vocabulary.applyLearnedCorrections(to: "open Hey mate please") == "open HeyMate please")
        #expect(vocabulary.applyLearnedCorrections(to: "they mated") == "they mated")
    }

    @Test func removeAllClears() {
        let vocabulary = scratchVocabulary()
        vocabulary.learn(.init(heard: "umer", corrected: "Umar"))
        vocabulary.removeAll()
        #expect(vocabulary.keyterms.isEmpty)
    }
}

struct SystemOverlayYieldTests {
    @Test func screenshotShortcutsTriggerTheWatch() {
        let commandShift: CGEventFlags = [.maskCommand, .maskShift]
        #expect(SystemOverlayYield.isScreenshotShortcut(keyCode: 21, flags: commandShift))
        #expect(SystemOverlayYield.isScreenshotShortcut(keyCode: 23, flags: commandShift))
        #expect(!SystemOverlayYield.isScreenshotShortcut(keyCode: 21, flags: .maskCommand))
        #expect(!SystemOverlayYield.isScreenshotShortcut(keyCode: 0, flags: commandShift))
    }
}
