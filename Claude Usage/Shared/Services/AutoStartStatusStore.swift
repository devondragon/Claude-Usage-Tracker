//
//  AutoStartStatusStore.swift
//  Claude Usage
//
//  The last auto-start result per profile, shown in settings, and which skip
//  reasons were already logged today, so a skip repeated on every check is
//  logged once per day instead of every 5 minutes.
//

import Foundation

/// Outcome of the last ping auto-start ran (or tried to run) for a profile.
struct AutoStartResult: Codable, Equatable {
    var date: Date
    var success: Bool
    var message: String?
}

extension Notification.Name {
    /// Posted after an auto-start result is saved. `userInfo["profileID"]` is the profile's UUID.
    static let autoStartResultChanged = Notification.Name("autoStartResultChanged")
}

struct AutoStartStatusStore {
    static let resultsKey = "autoStartLastResult"
    static let loggedReasonsKey = "autoStartLoggedReasons"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Results

    func lastResult(for profileID: UUID) -> AutoStartResult? {
        loadResults()[profileID.uuidString]
    }

    func saveResult(_ result: AutoStartResult, for profileID: UUID) {
        var all = loadResults()
        all[profileID.uuidString] = result
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.resultsKey)
        }
        NotificationCenter.default.post(
            name: .autoStartResultChanged,
            object: nil,
            userInfo: ["profileID": profileID]
        )
    }

    private func loadResults() -> [String: AutoStartResult] {
        guard let data = defaults.data(forKey: Self.resultsKey),
              let decoded = try? JSONDecoder().decode([String: AutoStartResult].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: - Once-Per-Day Logging

    /// True the first time `reason` (by case, ignoring associated values) is seen
    /// for the profile on the calendar day containing `now`.
    mutating func shouldLog(_ reason: AutoStartSkipReason, for profileID: UUID, now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)

        var all = loadLoggedReasons()
        var forProfile = all[profileID.uuidString] ?? [:]
        let key = Self.caseName(of: reason)
        if forProfile[key] == day { return false }

        forProfile[key] = day
        all[profileID.uuidString] = forProfile
        defaults.set(all, forKey: Self.loggedReasonsKey)
        return true
    }

    private func loadLoggedReasons() -> [String: [String: String]] {
        defaults.dictionary(forKey: Self.loggedReasonsKey) as? [String: [String: String]] ?? [:]
    }

    static func caseName(of reason: AutoStartSkipReason) -> String {
        switch reason {
        case .outOfSchedule: return "outOfSchedule"
        case .noUsageWindows: return "noUsageWindows"
        case .noSessionLimit: return "noSessionLimit"
        case .windowOpen: return "windowOpen"
        case .weeklyLimitReached: return "weeklyLimitReached"
        case .backingOff: return "backingOff"
        case .usageFetchFailed: return "usageFetchFailed"
        case .noClaudeCodeLogin: return "noClaudeCodeLogin"
        case .accountMismatch: return "accountMismatch"
        case .binaryNotFound: return "binaryNotFound"
        }
    }
}
