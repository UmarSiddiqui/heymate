import AppKit
import Testing
@testable import HeyMate

@MainActor
struct DisclosureSoundTests {
    @Test func everyKindHasItsOwnSounds() {
        let kinds: [UISoundPlayer.Disclosure] = [.popover, .sheet, .pane, .row]
        let opens = kinds.map { $0.sound(isOpen: true) }
        let closes = kinds.map { $0.sound(isOpen: false) }
        #expect(Set(opens).count == kinds.count)
        #expect(Set(closes).count == kinds.count)
        #expect(Set(opens).isDisjoint(with: closes))
        // None of them reuse the deliberate notch open/close.
        #expect(!(opens + closes).contains(.panelOpen))
        #expect(!(opens + closes).contains(.panelClose))
    }

    @Test func everySoundShipsAnAsset() {
        for sound in UISoundPlayer.Sound.allCases {
            #expect(NSDataAsset(name: sound.rawValue) != nil, "missing asset \(sound.rawValue)")
        }
    }
}
