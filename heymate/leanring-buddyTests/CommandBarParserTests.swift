//
//  CommandBarParserTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct CommandBarParserTests {

    @Test func leadingSlashResolvesAKnownCommand() {
        #expect(CommandBarParser.parse("/agents") == .slashCommand(.agents, argument: ""))
        #expect(CommandBarParser.parse("/settings") == .slashCommand(.settings, argument: ""))
        #expect(CommandBarParser.parse("  /help  ") == .slashCommand(.help, argument: ""))
    }

    @Test func aliasesResolveToTheSameCommand() {
        #expect(CommandBarParser.parse("/integrations") == .slashCommand(.connectors, argument: ""))
        #expect(CommandBarParser.parse("/forget") == .slashCommand(.clearMemory, argument: ""))
    }

    @Test func memoryClearIsSpelledBothWays() {
        #expect(CommandBarParser.parse("/memory clear") == .slashCommand(.clearMemory, argument: ""))
        #expect(CommandBarParser.parse("/memory-clear") == .slashCommand(.clearMemory, argument: ""))
        // Bare /memory still opens the page rather than deleting anything.
        #expect(CommandBarParser.parse("/memory") == .slashCommand(.memory, argument: ""))
    }

    @Test func unknownCommandIsNotSentToTheModel() {
        #expect(CommandBarParser.parse("/tskills") == .unknownSlashCommand("tskills"))
        #expect(CommandBarParser.parse("/") == .unknownSlashCommand(""))
    }

    @Test func slashMidSentenceStaysOrdinaryText() {
        #expect(
            CommandBarParser.parse("does this work and/or that")
                == .message(text: "does this work and/or that", contextTokens: [])
        )
    }

    @Test func contextTokensAreLiftedOutOfTheMessage() {
        #expect(
            CommandBarParser.parse("what did I ask for @memory")
                == .message(text: "what did I ask for", contextTokens: [.memory])
        )
        #expect(
            CommandBarParser.parse("@clipboard @skills summarize this")
                == .message(text: "summarize this", contextTokens: [.clipboard, .skills])
        )
    }

    @Test func trailingPunctuationDoesNotBreakAToken() {
        #expect(
            CommandBarParser.parse("check @clipboard.")
                == .message(text: "check", contextTokens: [.clipboard])
        )
    }

    @Test func repeatedTokenIsOnlyAttachedOnce() {
        #expect(
            CommandBarParser.parse("@memory @memory what do you know")
                == .message(text: "what do you know", contextTokens: [.memory])
        )
    }

    @Test func unrecognizedAtWordStaysInTheMessage() {
        #expect(
            CommandBarParser.parse("email @umar about this")
                == .message(text: "email @umar about this", contextTokens: [])
        )
    }

    @Test func everyCommandHasAtLeastOneAlias() {
        for command in SlashCommand.allCases {
            #expect(!command.aliases.isEmpty)
        }
    }

    @Test func onlyClearingMemoryNeedsConfirmation() {
        let commandsNeedingConfirmation = SlashCommand.allCases.filter(\.requiresConfirmation)
        #expect(commandsNeedingConfirmation == [.clearMemory])
    }
}
