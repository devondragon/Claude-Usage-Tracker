//
//  AutoStartAttemptPolicy.swift
//  Claude Usage
//
//  Limits how often auto-start may try to open a session window for one
//  profile (upstream #334). Without a limit, an initialization message that
//  keeps failing, or that succeeds without opening a window, is retried on
//  every 5-minute check indefinitely.
//

import Foundation

/// Attempts made for one profile since its session window was last seen open.
struct AutoStartAttemptState: Codable, Equatable {
    var attempts: Int
    var lastAttempt: Date
}

// MARK: - Policy

enum AutoStartAttemptPolicy {
    /// Attempts allowed before pausing.
    static let maxAttempts = 3
    /// Wait after the first attempt; doubles after each further attempt.
    static let baseInterval: TimeInterval = 300
    /// Pause after `maxAttempts` attempts that did not open a window.
    static let pauseAfterMaxAttempts: TimeInterval = 5 * 3600
    /// The check timer has 30 s tolerance and the previous attempt started a
    /// moment after its check, so allow attempts slightly early.
    static let timerSlack: TimeInterval = 30

    enum Decision: Equatable {
        case attempt
        case wait(until: Date)
    }

    static func decide(state: AutoStartAttemptState?, now: Date) -> Decision {
        guard let state, state.attempts > 0 else { return .attempt }

        // A last attempt in the future means the clock moved back since it
        // was saved. The saved time is meaningless then, so don't wait on it.
        guard state.lastAttempt <= now else { return .attempt }

        let wait = state.attempts >= maxAttempts
            ? pauseAfterMaxAttempts
            : baseInterval * pow(2, Double(state.attempts - 1))
        let earliest = state.lastAttempt.addingTimeInterval(wait)
        return now >= earliest.addingTimeInterval(-timerSlack) ? .attempt : .wait(until: earliest)
    }

    /// State to persist when an attempt starts. A finished pause starts a new count.
    static func stateAfterAttempt(_ state: AutoStartAttemptState?, now: Date) -> AutoStartAttemptState {
        let previous = state.map { $0.attempts >= maxAttempts ? 0 : $0.attempts } ?? 0
        return AutoStartAttemptState(attempts: previous + 1, lastAttempt: now)
    }
}

// MARK: - Persistence

/// Keeps attempt state in UserDefaults so an app restart does not reset the
/// limit (a launch runs a check immediately).
struct AutoStartAttemptStore {
    static let defaultsKey = "autoStartAttemptState"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func state(for profileID: UUID) -> AutoStartAttemptState? {
        load()[profileID.uuidString]
    }

    func save(_ state: AutoStartAttemptState, for profileID: UUID) {
        var all = load()
        all[profileID.uuidString] = state
        write(all)
    }

    func clear(for profileID: UUID) {
        var all = load()
        guard all.removeValue(forKey: profileID.uuidString) != nil else { return }
        write(all)
    }

    private func load() -> [String: AutoStartAttemptState] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: AutoStartAttemptState].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func write(_ all: [String: AutoStartAttemptState]) {
        if all.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
