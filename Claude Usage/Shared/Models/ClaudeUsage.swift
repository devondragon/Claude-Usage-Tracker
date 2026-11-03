import Foundation

/// Main data model representing Claude Code usage statistics
struct ClaudeUsage: Codable, Equatable {
    // Session data (5-hour rolling window)
    var sessionTokensUsed: Int
    var sessionLimit: Int
    var sessionPercentage: Double
    var sessionResetTime: Date

    /// Returns 0% if the 5-hour session window has expired, otherwise the raw percentage.
    var effectiveSessionPercentage: Double {
        sessionResetTime < Date() ? 0.0 : sessionPercentage
    }

    // Weekly data (all models)
    var weeklyTokensUsed: Int
    var weeklyLimit: Int
    var weeklyPercentage: Double
    var weeklyResetTime: Date

    // Weekly data (Opus only)
    var opusWeeklyTokensUsed: Int
    var opusWeeklyPercentage: Double

    // Weekly data (Sonnet only)
    var sonnetWeeklyTokensUsed: Int
    var sonnetWeeklyPercentage: Double
    var sonnetWeeklyResetTime: Date?

    // Weekly data (Design only)
    var designWeeklyTokensUsed: Int
    var designWeeklyPercentage: Double
    var designWeeklyResetTime: Date?

    // Weekly data (Fable only)
    var fableWeeklyTokensUsed: Int
    var fableWeeklyPercentage: Double
    var fableWeeklyResetTime: Date?

    // Extra usage data
    var costUsed: Double?
    var costLimit: Double?
    var costCurrency: String?

    // Overage credit grant balance
    var overageBalance: Double?
    var overageBalanceCurrency: String?

    // Provider plan/credits (populated by providers that report them, e.g. Codex)
    var planType: String?
    var creditsBalance: Double?
    var creditsUnlimited: Bool?

    // Metadata
    var lastUpdated: Date
    var userTimezone: TimeZone

    // Whether the usage response carried a 5-hour block / any weekly limit.
    // A null five_hour block also means "no session running" on Max and Pro,
    // so these flags alone must not hide UI; only `isSpendLimited` (no window,
    // no plan limits, and a monthly spend cap: Enterprise seats) changes the
    // display. Declared after `userTimezone` with defaults so the memberwise
    // initializer keeps working at existing call sites.
    var hasSessionWindow: Bool = true
    var hasWeeklyWindow: Bool = true
    var spendLimitReached: Bool = false
    /// When the spend fields were last read from an API response. A cached
    /// spend from an earlier month must not be reused.
    var spendUpdatedAt: Date? = nil
    /// The account's plan has no 5-hour session limit at all (Max 20x /
    /// Ultra), as opposed to an idle session. Read from the Claude Code
    /// login's rate-limit tier, since the usage response looks the same for
    /// both. False when the tier is unknown.
    var planHasNoSessionLimit: Bool = false

    /// The response had no 5-hour block and no weekly limit at all. True for
    /// Enterprise seats even before their spend is loaded; false for idle Max
    /// and Pro accounts, which still report a weekly limit. Used where a wrong
    /// guess costs most (auto-switch, auto-start, history).
    var hasNoUsageWindows: Bool {
        !hasSessionWindow && !hasWeeklyWindow
    }

    /// Applies the profile's "Check Extra Usage Limit" setting. Accounts with
    /// usage windows drop the cost fields when it is off; a spend-only account
    /// keeps them, since the spend cap is its only limit.
    func respectingOverageOptOut(enabled: Bool) -> ClaudeUsage {
        guard !enabled, !hasNoUsageWindows else { return self }
        var usage = self
        usage.costUsed = nil
        usage.costLimit = nil
        usage.costCurrency = nil
        usage.overageBalance = nil
        usage.overageBalanceCurrency = nil
        usage.spendLimitReached = false
        usage.spendUpdatedAt = nil
        return usage
    }

    /// `self` with `planHasNoSessionLimit` set. An unknown plan (nil) leaves
    /// the field as it was, so the session bar keeps its usual behavior.
    func stampingPlan(noSessionLimit: Bool?) -> ClaudeUsage {
        guard let noSessionLimit else { return self }
        var usage = self
        usage.planHasNoSessionLimit = noSessionLimit
        return usage
    }

    /// The account's only limit is a monthly spend cap (costUsed / costLimit, in cents).
    var isSpendLimited: Bool {
        !hasSessionWindow && !hasWeeklyWindow && costUsed != nil && (costLimit ?? 0) > 0
    }

    /// Share of the monthly spend cap used, in percent. Not clamped: spend can exceed the cap.
    var spendPercentage: Double {
        guard let used = costUsed, let limit = costLimit, limit > 0 else { return 0 }
        return used / limit * 100
    }

    /// Remaining percentage (100 - used percentage)
    var remainingPercentage: Double {
        max(0, 100 - effectiveSessionPercentage)
    }

    /// Returns the status level based on remaining percentage (like Mac battery indicator)
    /// DEPRECATED: Use UsageStatusCalculator.calculateStatus() instead for display-aware logic
    /// This property remains for backwards compatibility only
    /// - > 20% remaining: safe (green)
    /// - 10-20% remaining: moderate (orange)
    /// - < 10% remaining: critical (red)
    @available(*, deprecated, message: "Use UsageStatusCalculator.calculateStatus() with showRemaining parameter")
    var statusLevel: UsageStatusLevel {
        switch remainingPercentage {
        case 20...:
            return .safe
        case 10..<20:
            return .moderate
        default:
            return .critical
        }
    }

    /// Empty usage data (used when no data is available)
    static var empty: ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: 0,
            sessionResetTime: Date().addingTimeInterval(5 * 60 * 60),
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 0,
            weeklyResetTime: Date().nextMonday1259pm(),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0,
            designWeeklyPercentage: 0,
            designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

}

/// Usage status level for color coding
/// Thresholds depend on display mode (used vs remaining percentage)
enum UsageStatusLevel {
    case safe       // Used mode: 0-50% used | Remaining mode: >20% remaining
    case moderate   // Used mode: 50-80% used | Remaining mode: 10-20% remaining
    case critical   // Used mode: 80-100% used | Remaining mode: <10% remaining
}

// MARK: - Backward-compatible decoding
//
// Synthesized Codable makes every newly added non-optional field a decode
// REQUIREMENT for data written by older app versions. Profiles cache their
// last ClaudeUsage in profiles_v3, so a strict decoder here made
// ProfileStore.loadProfiles() throw on pre-upgrade data and return [] —
// wiping every profile on update (found via PR #271, thanks @yelloduxx).
// Every field decodes tolerantly with a neutral default, so new fields can
// be added without a migration. Lives in an extension so the struct keeps
// its memberwise initializer.
extension ClaudeUsage {
    private enum CodingKeys: String, CodingKey {
        case sessionTokensUsed, sessionLimit, sessionPercentage, sessionResetTime
        case weeklyTokensUsed, weeklyLimit, weeklyPercentage, weeklyResetTime
        case opusWeeklyTokensUsed, opusWeeklyPercentage
        case sonnetWeeklyTokensUsed, sonnetWeeklyPercentage, sonnetWeeklyResetTime
        case designWeeklyTokensUsed, designWeeklyPercentage, designWeeklyResetTime
        case fableWeeklyTokensUsed, fableWeeklyPercentage, fableWeeklyResetTime
        case costUsed, costLimit, costCurrency
        case overageBalance, overageBalanceCurrency
        case planType, creditsBalance, creditsUnlimited
        case lastUpdated, userTimezone
        case hasSessionWindow, hasWeeklyWindow, spendLimitReached, spendUpdatedAt
        case planHasNoSessionLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionTokensUsed: try c.decodeIfPresent(Int.self, forKey: .sessionTokensUsed) ?? 0,
            sessionLimit: try c.decodeIfPresent(Int.self, forKey: .sessionLimit) ?? 0,
            sessionPercentage: try c.decodeIfPresent(Double.self, forKey: .sessionPercentage) ?? 0,
            sessionResetTime: try c.decodeIfPresent(Date.self, forKey: .sessionResetTime) ?? Date(),
            weeklyTokensUsed: try c.decodeIfPresent(Int.self, forKey: .weeklyTokensUsed) ?? 0,
            weeklyLimit: try c.decodeIfPresent(Int.self, forKey: .weeklyLimit) ?? 0,
            weeklyPercentage: try c.decodeIfPresent(Double.self, forKey: .weeklyPercentage) ?? 0,
            weeklyResetTime: try c.decodeIfPresent(Date.self, forKey: .weeklyResetTime) ?? Date(),
            opusWeeklyTokensUsed: try c.decodeIfPresent(Int.self, forKey: .opusWeeklyTokensUsed) ?? 0,
            opusWeeklyPercentage: try c.decodeIfPresent(Double.self, forKey: .opusWeeklyPercentage) ?? 0,
            sonnetWeeklyTokensUsed: try c.decodeIfPresent(Int.self, forKey: .sonnetWeeklyTokensUsed) ?? 0,
            sonnetWeeklyPercentage: try c.decodeIfPresent(Double.self, forKey: .sonnetWeeklyPercentage) ?? 0,
            sonnetWeeklyResetTime: try c.decodeIfPresent(Date.self, forKey: .sonnetWeeklyResetTime),
            designWeeklyTokensUsed: try c.decodeIfPresent(Int.self, forKey: .designWeeklyTokensUsed) ?? 0,
            designWeeklyPercentage: try c.decodeIfPresent(Double.self, forKey: .designWeeklyPercentage) ?? 0,
            designWeeklyResetTime: try c.decodeIfPresent(Date.self, forKey: .designWeeklyResetTime),
            fableWeeklyTokensUsed: try c.decodeIfPresent(Int.self, forKey: .fableWeeklyTokensUsed) ?? 0,
            fableWeeklyPercentage: try c.decodeIfPresent(Double.self, forKey: .fableWeeklyPercentage) ?? 0,
            fableWeeklyResetTime: try c.decodeIfPresent(Date.self, forKey: .fableWeeklyResetTime),
            costUsed: try c.decodeIfPresent(Double.self, forKey: .costUsed),
            costLimit: try c.decodeIfPresent(Double.self, forKey: .costLimit),
            costCurrency: try c.decodeIfPresent(String.self, forKey: .costCurrency),
            overageBalance: try c.decodeIfPresent(Double.self, forKey: .overageBalance),
            overageBalanceCurrency: try c.decodeIfPresent(String.self, forKey: .overageBalanceCurrency),
            planType: try c.decodeIfPresent(String.self, forKey: .planType),
            creditsBalance: try c.decodeIfPresent(Double.self, forKey: .creditsBalance),
            creditsUnlimited: try c.decodeIfPresent(Bool.self, forKey: .creditsUnlimited),
            lastUpdated: try c.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date(),
            userTimezone: try c.decodeIfPresent(TimeZone.self, forKey: .userTimezone) ?? .current,
            hasSessionWindow: try c.decodeIfPresent(Bool.self, forKey: .hasSessionWindow) ?? true,
            hasWeeklyWindow: try c.decodeIfPresent(Bool.self, forKey: .hasWeeklyWindow) ?? true,
            spendLimitReached: try c.decodeIfPresent(Bool.self, forKey: .spendLimitReached) ?? false,
            spendUpdatedAt: try c.decodeIfPresent(Date.self, forKey: .spendUpdatedAt),
            planHasNoSessionLimit: try c.decodeIfPresent(Bool.self, forKey: .planHasNoSessionLimit) ?? false
        )
    }
}
