//
//  AutoStartDecision.swift
//  Claude Usage
//
//  Pure decision for one profile on one auto-start check: send the
//  initialization message through the Claude Code CLI, or skip and say why.
//

import Foundation

/// What the usage check found for a profile.
enum AutoStartUsageReading {
    /// Usage was read. `hasOpenWindow` is true when a 5-hour session window is already running.
    case live(ClaudeUsage, hasOpenWindow: Bool)
    /// The access token is expired, so usage cannot be read. The CLI refreshes
    /// it when it runs, so a ping can still go out.
    case tokenExpired
    /// Usage could not be read for another reason.
    case failed(String)
}

enum AutoStartSkipReason: Equatable {
    case outOfSchedule
    case noUsageWindows
    /// The plan has no 5-hour limit (Max 20x / Ultra), so a ping cannot open a window.
    case noSessionLimit
    case windowOpen(until: Date?)
    case weeklyLimitReached
    case backingOff(until: Date)
    case usageFetchFailed(String)
    case noClaudeCodeLogin
    case accountMismatch
    case binaryNotFound
}

enum AutoStartAction: Equatable {
    case ping
    case skip(AutoStartSkipReason)
}

// MARK: - Decision

enum AutoStartDecision {
    static func decide(
        inSchedule: Bool,
        reading: AutoStartUsageReading,
        attempt: AutoStartAttemptPolicy.Decision
    ) -> AutoStartAction {
        guard inSchedule else { return .skip(.outOfSchedule) }

        switch reading {
        case .failed(let message):
            return .skip(.usageFetchFailed(message))
        case .live(let usage, let hasOpenWindow):
            if usage.hasNoUsageWindows { return .skip(.noUsageWindows) }
            if usage.planHasNoSessionLimit { return .skip(.noSessionLimit) }
            if hasOpenWindow { return .skip(.windowOpen(until: usage.sessionResetTime)) }
            if usage.weeklyPercentage >= 100 { return .skip(.weeklyLimitReached) }
        case .tokenExpired:
            break
        }

        if case .wait(let until) = attempt { return .skip(.backingOff(until: until)) }
        return .ping
    }
}
