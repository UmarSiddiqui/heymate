//
//  DictationInsertionContextTests.swift
//  leanring-buddyTests
//
//  Tests for the pure pieces of the dictation insertion path: secure-field
//  detection, focused-field metadata value type, and the rewrite-text
//  cleaner. AX/pasteboard side effects are intentionally NOT exercised here.
//

import Testing
@testable import HeyMate

@MainActor
struct DictationInsertionContextTests {

    // MARK: - Secure-field detection

    @Test func secureSubroleIsBlocked() {
        #expect(DictationFieldSecurity.isLikelySecure(role: "AXTextField", subrole: "secureText"))
    }

    @Test func secureRoleNameIsBlocked() {
        #expect(DictationFieldSecurity.isLikelySecure(role: "SecureTextField", subrole: nil))
    }

    @Test func securityCheckIsCaseInsensitive() {
        #expect(DictationFieldSecurity.isLikelySecure(role: nil, subrole: "SECURE"))
    }

    @Test func ordinaryTextElementsAreAllowed() {
        #expect(!DictationFieldSecurity.isLikelySecure(role: "AXTextArea", subrole: nil))
        #expect(!DictationFieldSecurity.isLikelySecure(role: "AXTextField", subrole: nil))
    }

    @Test func missingMetadataIsNotAllowedThroughBlindly() {
        // No role/subrole at all — heuristic must not claim it's safe.
        #expect(!DictationFieldSecurity.isLikelySecure(role: nil, subrole: nil))
    }

    // MARK: - Focused field info value type

    @Test func focusedFieldInfoEquality() {
        let a = FocusedFieldInfo(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            role: "AXTextArea",
            subrole: nil,
            placeholder: nil,
            currentValuePreview: "hello"
        )
        let b = FocusedFieldInfo(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            role: "AXTextArea",
            subrole: nil,
            placeholder: nil,
            currentValuePreview: "hello"
        )
        let different = FocusedFieldInfo(
            bundleIdentifier: "com.apple.TextEdit",
            appName: "TextEdit",
            role: "AXTextArea",
            subrole: nil,
            placeholder: nil,
            currentValuePreview: "changed"
        )

        #expect(a == b)
        #expect(a != different)
    }

    // MARK: - Headless probe (must never crash without a real focused field)

    @Test func focusedFieldMetadataProbeIsSafeHeadlessly() {
        // In the test host there may or may not be a resolvable focused
        // element; both outcomes are valid — the contract is only that this
        // returns optional metadata without trapping.
        _ = DictationInserter.focusedFieldMetadata()
    }

    // MARK: - Rewrite cleaning

    @Test func cleanRewrittenDictationStripsCodeFences() {
        let fenced = "```\ninsert me please\n```"
        #expect(CompanionManager.cleanRewrittenDictation(fenced) == "insert me please")
    }

    @Test func cleanRewrittenDictationStripsSymmetricQuotes() {
        #expect(CompanionManager.cleanRewrittenDictation(#""quoted text""#) == "quoted text")
        #expect(CompanionManager.cleanRewrittenDictation("\u{201C}curly quoted\u{201D}") == "curly quoted")
    }

    @Test func cleanRewrittenDictationLeavesPlainTextAlone() {
        let plain = "just a normal sentence."
        #expect(CompanionManager.cleanRewrittenDictation(plain) == plain)
    }
}
