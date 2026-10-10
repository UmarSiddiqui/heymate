//
//  CursorCaptionTiming.swift
//  leanring-buddy
//
//  When the reply caption beside the buddy cursor should go away. The
//  caption outlives the streamed text: it stays while the reply is spoken
//  and long enough to read, then leaves shortly after the voice stops.
//

import Foundation

nonisolated enum CursorCaptionTiming {
    /// Comfortable on-screen reading pace, slower than spoken pace so a
    /// silent reply is not yanked away mid-sentence.
    static let readingWordsPerSecond: Double = 3.3
    static let minimumReadingSeconds: TimeInterval = 3.0
    static let maximumReadingSeconds: TimeInterval = 12.0
    /// Pause after the voice finishes, so the last words are not cut off.
    static let afterSpeechSeconds: TimeInterval = 1.2
    /// How long to wait for speech to start before treating the reply as silent.
    static let speechStartGraceSeconds: TimeInterval = 2.0

    static func readingSeconds(for text: String) -> TimeInterval {
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let seconds = 1.5 + Double(wordCount) / readingWordsPerSecond
        return min(max(seconds, minimumReadingSeconds), maximumReadingSeconds)
    }

    /// True once the caption may hide. `speechEndedAt` is when playback
    /// stopped after having started; nil while speaking or if it never began.
    static func shouldHide(
        text: String,
        shownAt: Date,
        now: Date,
        isSpeaking: Bool,
        speechEndedAt: Date?
    ) -> Bool {
        guard !isSpeaking else { return false }
        guard now.timeIntervalSince(shownAt) >= readingSeconds(for: text) else { return false }
        if let speechEndedAt {
            return now.timeIntervalSince(speechEndedAt) >= afterSpeechSeconds
        }
        return now.timeIntervalSince(shownAt) >= speechStartGraceSeconds
    }
}

extension CompanionManager {
    /// Live streamed text drives the caption. Clearing the stream (cancel,
    /// new chat, new turn) hides it at once; a finished reply re-shows it
    /// through `lingerCursorCaption`.
    func mirrorStreamingTextIntoCursorCaption() {
        cursorCaptionTask?.cancel()
        cursorCaptionTask = nil
        if !streamingAssistantText.isEmpty || !isGuidancePointerHeld {
            cursorCaptionProgress = nil
        }
        if cursorCaptionText != streamingAssistantText {
            cursorCaptionText = streamingAssistantText
        }
    }

    /// Keeps the finished reply beside the cursor while it is spoken and
    /// for long enough to read, then hides it.
    func lingerCursorCaption(
        _ text: String,
        keepingProgress progress: String? = nil,
        shownAt: Date = Date(),
        speechAlreadyEnded: Bool = false
    ) {
        cursorCaptionTask?.cancel()
        guard !text.isEmpty, backgroundRoutineSession == nil else {
            cursorCaptionText = ""
            cursorCaptionProgress = nil
            return
        }
        cursorCaptionText = text
        cursorCaptionProgress = progress
        cursorCaptionTask = Task { [weak self] in
            var speechEndedAt: Date? = speechAlreadyEnded ? Date() : nil
            var hasSpoken = speechAlreadyEnded
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled, let self else { return }
                let isSpeaking = self.isCursorCaptionSpeechPlaying
                if isSpeaking {
                    hasSpoken = true
                    speechEndedAt = nil
                } else if hasSpoken, speechEndedAt == nil {
                    speechEndedAt = Date()
                }
                if CursorCaptionTiming.shouldHide(
                    text: text,
                    shownAt: shownAt,
                    now: Date(),
                    isSpeaking: isSpeaking,
                    speechEndedAt: speechEndedAt
                ) {
                    self.cursorCaptionText = ""
                    self.cursorCaptionProgress = nil
                    self.cursorCaptionTask = nil
                    return
                }
            }
        }
    }
}
