import AppKit
import Foundation

@main struct TalkContextProbe {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "TalkContextProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks += 1
        }
        for phrase in ["yes", "again", "and this one", "do you see it now", "tell me a joke"] {
            try check(TalkContextPolicy.shouldCaptureScreen(for: phrase, hasSpatialSelection: false, isPushToTalk: true), phrase)
        }
        for phrase in ["tell me a joke", "explain database connection pooling"] {
            try check(!TalkContextPolicy.shouldCaptureScreen(for: phrase, hasSpatialSelection: false), "Typed text: \(phrase)")
        }
        for phrase in ["what does this error mean", "click save", "where is the share button", "open chrome"] {
            try check(TalkContextPolicy.shouldCaptureScreen(for: phrase, hasSpatialSelection: false), phrase)
        }
        try check(!TalkContextPolicy.allowCapture(wantsScreen: true, typedInsideHeyMate: true, frontmostIsHeyMate: true), "Typed HeyMate exclusion")
        try check(TalkContextPolicy.allowCapture(wantsScreen: true, typedInsideHeyMate: false, frontmostIsHeyMate: true), "Voice capture")
        let labels = ScreenContextPrompt.withImageLabels("Question", images: [
            (Data([1]), "cursor display 2048x850\n[10,20,30,40] Save"),
            (Data([2]), "secondary display 1280x900")
        ])
        try check(labels.contains("Image 1:\ncursor display 2048x850"), "First image identity")
        try check(labels.contains("Image 2:\nsecondary display 1280x900"), "Second image identity")
        try check(labels.contains("[10,20,30,40] Save"), "Measured boxes")
        try check(ScreenContextPrompt.withImageLabels("hello", images: []) == "hello", "Text-only prompt unchanged")
        try check(SpeechText.sanitize("The screenshot didn't come through.") == "I couldn't see your screen.", "Natural capture failure speech")
        for word in ["screenshot", "screenshots", "Screen Shot", "SCREEN-SHOTS"] {
            try check(!SpeechText.sanitize(word).lowercased().contains("screenshot"), "Capture vocabulary: \(word)")
        }
        try check(SpeechText.sanitize("**Hello**.\n* Open Settings\n* Click Privacy") == "Hello. Open Settings. Click Privacy.", "Existing speech cleanup")
        let flags = NSEvent.ModifierFlags([.control, .option]).rawValue
        try check(PushToTalkShortcut.transition(for: .flagsChanged, keyCode: 58, modifierFlagsRawValue: UInt64(flags), wasHeld: false, option: .controlOption) == .pressed, "Control-Option press")
        try check(PushToTalkShortcut.transition(for: .flagsChanged, keyCode: 58, modifierFlagsRawValue: 0, wasHeld: true, option: .controlOption) == .released, "Control-Option release")
        print("PASS: \(checks) production screen-policy, hotkey, image-label and speech checks")
    }
}
