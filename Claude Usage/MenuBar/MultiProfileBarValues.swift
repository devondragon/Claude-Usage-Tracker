//
//  MultiProfileBarValues.swift
//  Claude Usage
//
//  The values one profile's multi-profile menu bar icon draws. Normally a
//  session bar plus a weekly bar; a spend-limited profile draws one monthly
//  spend bar instead, and an account without a 5-hour window draws only its
//  weekly bar.
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
    /// The account reports no limits; draw the app logo.
    let showsAppLogo: Bool

    static func make(for usage: ClaudeUsage, showWeek: Bool, now: Date) -> MultiProfileBarValues {
        if usage.isSpendLimited {
            return MultiProfileBarValues(
                primaryUsed: usage.spendPercentage,
                primaryElapsed: SpendPeriod.containing(now).elapsedFraction(at: now),
                secondaryUsed: nil,
                secondaryElapsed: nil,
                isSpend: true,
                showsAppLogo: false
            )
        }

        if usage.reportsNoLimits {
            return MultiProfileBarValues(
                primaryUsed: 0, primaryElapsed: nil,
                secondaryUsed: nil, secondaryElapsed: nil,
                isSpend: false, showsAppLogo: true
            )
        }

        let weekElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.weeklyResetTime,
            duration: Constants.weeklyWindow,
            showRemaining: false
        )

        if !usage.hasSessionWindow {
            return MultiProfileBarValues(
                primaryUsed: usage.weeklyPercentage, primaryElapsed: weekElapsed,
                secondaryUsed: nil, secondaryElapsed: nil,
                isSpend: false, showsAppLogo: false
            )
        }

        let sessionElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.sessionResetTime,
            duration: Constants.sessionWindow,
            showRemaining: false
        )
        let showSecond = showWeek && usage.hasWeeklyWindow
        return MultiProfileBarValues(
            primaryUsed: usage.effectiveSessionPercentage,
            primaryElapsed: sessionElapsed,
            secondaryUsed: showSecond ? usage.weeklyPercentage : nil,
            secondaryElapsed: showSecond ? weekElapsed : nil,
            isSpend: false,
            showsAppLogo: false
        )
    }
}
