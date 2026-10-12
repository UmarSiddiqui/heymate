//
//  ComputerUseElementPickerTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct ComputerUseElementPickerTests {

    @Test(arguments: [
        ("Send", nil, "send"),
        ("Draft", "Tap Send when ready", "send"),
        ("Remove", "delete this file", "delete"),
        ("Checkout", "Confirm purchase", "purchase"),
        ("Pay invoice", nil, "pay"),
        ("OK", "confirm-purchase flow", "confirm-purchase")
    ])
    func denyListBlocksProtectedLabels(title: String?, description: String?, expectedFragment: String) {
        let reason = ComputerUseElementPicker.denialReasonIfBlocked(title: title, description: description)
        #expect(reason != nil)
        #expect(reason?.lowercased().contains(expectedFragment) == true)
    }

    @Test(arguments: [
        ("Save", "Save"),
        ("save", "Save changes"),
        ("Cancel", "Dismiss dialog"),
        (nil, "Continue editing")
    ])
    func denyListAllowsOrdinaryControls(title: String?, description: String?) {
        #expect(ComputerUseElementPicker.denialReasonIfBlocked(title: title, description: description) == nil)
    }

    @Test func nameQueryUsesAccessibilityScoring() {
        #expect(ComputerUseElementPicker.matchesNameQuery("send", candidateLabel: "Send"))
        #expect(ComputerUseElementPicker.matchesNameQuery("send", candidateLabel: "Send Later"))
        #expect(!ComputerUseElementPicker.matchesNameQuery("send", candidateLabel: "Cancel"))
    }

    @Test func nameQueryIsCaseAndAccentInsensitive() {
        #expect(ComputerUseElementPicker.matchesNameQuery("envoyer", candidateLabel: "Envoyér"))
    }
}
