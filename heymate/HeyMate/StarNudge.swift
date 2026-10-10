//
//  StarNudge.swift
//  HeyMate
//
//  A single, polite "star HeyMate on GitHub" ask. It waits until HeyMate has
//  answered a handful of the user's own questions, so it only reaches people
//  who have seen it work, and it never comes back once answered either way.
//

import Foundation

nonisolated enum StarNudgePreferences {

    static let answeredQuestionCountKey = "starNudgeAnsweredQuestionCount"
    static let isResolvedKey = "isStarNudgeResolved"

    /// Answers to the user's own questions before the ask appears.
    static let answersBeforeOffering = 5

    static var answeredQuestionCount: Int {
        get { UserDefaults.standard.integer(forKey: answeredQuestionCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: answeredQuestionCountKey) }
    }

    /// Set by either button, so the ask is shown at most once per Mac.
    static var isResolved: Bool {
        get { UserDefaults.standard.bool(forKey: isResolvedKey) }
        set { UserDefaults.standard.set(newValue, forKey: isResolvedKey) }
    }

    static func shouldOffer(answeredQuestionCount: Int, isResolved: Bool) -> Bool {
        !isResolved && answeredQuestionCount >= answersBeforeOffering
    }
}
