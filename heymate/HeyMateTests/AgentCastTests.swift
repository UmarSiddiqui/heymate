import Foundation
import Testing
@testable import HeyMate

struct AgentCastTests {
    @Test func recipesHideWhenThatWorkAlreadyExists() {
        let open = AgentRecipeCatalog.offers(existingJobs: ["General chat"])
        #expect(open.map(\.name) == [
            "Day Brief", "Inbox Scout", "Page Watch", "Research Scout", "Desk Clerk",
            "Screen Guide", "Marketing Partner", "LinkedIn Manager", "Developer"
        ])
        let taken = AgentRecipeCatalog.offers(existingJobs: ["Watch the inbox every morning"])
        #expect(!taken.map(\.name).contains("Inbox Scout"))
        #expect(taken.count == open.count - 1)
    }

    /// A recipe fills the review step as written, so nothing in it may be
    /// cut by the builder's limits, and making it must hide it afterwards.
    @Test func everyRecipeSurvivesTheBuilderLimitsAndHidesItself() {
        #expect(Set(AgentRecipeCatalog.all.map(\.id)).count == AgentRecipeCatalog.all.count)
        for recipe in AgentRecipeCatalog.all {
            #expect(AgentDrafter.sanitized(recipe.draft, existingNames: []) == recipe.draft, "\(recipe.name)")
            #expect(recipe.draft.howItWorks.count >= 3, "\(recipe.name)")
            #expect(!recipe.draft.asksFirst.isEmpty, "\(recipe.name)")
            #expect(!recipe.outcome.isEmpty && !recipe.draft.firstTask.isEmpty, "\(recipe.name)")
            #expect(AgentRecipeCatalog.offers(existingJobs: [recipe.job]).contains(recipe) == false, "\(recipe.name)")
        }
    }

    @Test func aScheduledRecipeSaysWhatEachRunDoes() {
        for recipe in AgentRecipeCatalog.all {
            #expect((recipe.runs == .onAsk) == recipe.routineTask.isEmpty, "\(recipe.name)")
            #expect((recipe.runs.schedule == nil) == (recipe.runs.chip == nil))
        }
        #expect(AgentRunsChoice.everyMorning.schedule == .daily(hour: 8, minute: 0))
        #expect(AgentRunsChoice.everyThreeHours.schedule == .everyHours(3))
        #expect(AgentRunsChoice.onAsk.schedule == nil)
    }

    @Test func routineTaskFallsBackToAWholeRequest() {
        var draft = AgentDraft.empty
        draft.role = "Watch web pages and report only what changed"
        draft.firstTask = "Watch this page and tell me when it changes: "
        #expect(AgentRecipeCatalog.routineTask(typed: "  Check the list  ", draft: draft) == "Check the list")
        // An unfinished first task is not something to run on a schedule.
        #expect(AgentRecipeCatalog.routineTask(typed: "", draft: draft) == draft.role)
        draft.firstTask = "Write today's brief."
        #expect(AgentRecipeCatalog.routineTask(typed: " ", draft: draft) == "Write today's brief.")
    }

    @Test func aNewRoutineStartsAtTheNextSlot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9)))
        let mateID = UUID()
        let routine = MateRoutine.scheduled(
            mateID: mateID, task: "Write today's brief.",
            schedule: .daily(hour: 8, minute: 0), now: now, calendar: calendar
        )
        #expect(routine.mateID == mateID && routine.enabled && routine.pausedReason == nil)
        #expect(routine.nextRunAt == calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 8)))
        #expect(!MateRoutineAccounting.isDue(routine, now: now))
    }

    @Test func recipesThatWakeSayWhatToDoAndCanBeSaved() {
        let waking = AgentRecipeCatalog.all.filter { $0.wake != nil }
        #expect(waking.map(\.name).sorted() == ["Day Brief", "Desk Clerk", "Developer", "Inbox Scout", "Research Scout"])
        for recipe in waking {
            #expect(!recipe.wakeTask.isEmpty)
            #expect(recipe.wakeTask.count <= 240)
            if recipe.wake?.requiresMatch == true { #expect(!MateWakeMatcher.terms(recipe.wakeMatch).isEmpty) }
        }
        #expect(AgentRunsChoice.weekdayMornings.schedule == .weekdays(hour: 8, minute: 0))
        #expect(AgentRunsChoice.everyHalfHour.schedule == .everyMinutes(30))
    }
}
