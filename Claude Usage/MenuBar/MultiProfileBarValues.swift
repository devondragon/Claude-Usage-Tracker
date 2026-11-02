//
//  MultiProfileBarValues.swift
//  Claude Usage
//
//  The values one profile's multi-profile menu bar icon draws. Normally a
//  session bar plus a weekly bar; a spend-limited profile draws one monthly
//  spend bar instead.
//

import Foundation

struct MultiProfileBarValues: Equatable {
    /// Used percentage for the first bar (session, weekly, or spend).
    let primaryUsed: Double
    let primaryElapsed: Double?
    /// Used percentage for the second bar, or nil when there is none.
    let secondaryUsed: Double?
    let secondaryElapsed: Double?
    /// The first bar is monthly spend.
    let isSpend: Bool

    /// The profile label to draw. Multi-profile icons show at most three
    /// characters, so the spend marker replaces the third: "Tribe" -> "Tr$".
    static func label(for profileName: String, isSpend: Bool) -> String {
        isSpend ? "\(profileName.prefix(2))$" : profileName
    }

    static func make(for usage: ClaudeUsage, showWeek: Bool, now: Date) -> MultiProfileBarValues {
        if usage.isSpendLimited {
            return MultiProfileBarValues(
                // Spend can exceed the cap; the bar draws full at most.
                primaryUsed: min(usage.spendPercentage, 100),
                primaryElapsed: SpendPeriod.containing(now).elapsedFraction(at: now),
                secondaryUsed: nil,
                secondaryElapsed: nil,
                isSpend: true
            )
        }

        let weekElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.weeklyResetTime,
            duration: Constants.weeklyWindow,
            showRemaining: false
        )

        let sessionElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.sessionResetTime,
            duration: Constants.sessionWindow,
            showRemaining: false
        )
        return MultiProfileBarValues(
            primaryUsed: usage.effectiveSessionPercentage,
            primaryElapsed: sessionElapsed,
            secondaryUsed: showWeek ? usage.weeklyPercentage : nil,
            secondaryElapsed: showWeek ? weekElapsed : nil,
            isSpend: false
        )
    }
}
