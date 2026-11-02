import XCTest
@testable import Claude_Usage

@MainActor
final class AutoStartAttemptPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Policy

    func testFirstAttemptIsAllowed() {
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: nil, now: now), .attempt)
    }

    func testSecondAttemptWaitsForBaseInterval() {
        let state = AutoStartAttemptState(attempts: 1, lastAttempt: now)

        XCTAssertNotEqual(AutoStartAttemptPolicy.decide(state: state, now: now.addingTimeInterval(120)), .attempt)
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: now.addingTimeInterval(300)), .attempt)
    }

    func testTimerJitterDoesNotSkipACycle() {
        // The 5-minute timer can fire a few seconds before 300 s have passed
        // since the previous attempt started.
        let state = AutoStartAttemptState(attempts: 1, lastAttempt: now)
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: now.addingTimeInterval(290)), .attempt)
    }

    func testThirdAttemptBacksOff() {
        let state = AutoStartAttemptState(attempts: 2, lastAttempt: now)

        XCTAssertEqual(
            AutoStartAttemptPolicy.decide(state: state, now: now.addingTimeInterval(300)),
            .wait(until: now.addingTimeInterval(600))
        )
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: now.addingTimeInterval(600)), .attempt)
    }

    func testPausesAfterMaxAttempts() {
        let state = AutoStartAttemptState(attempts: AutoStartAttemptPolicy.maxAttempts, lastAttempt: now)
        let resume = now.addingTimeInterval(AutoStartAttemptPolicy.pauseAfterMaxAttempts)

        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: now.addingTimeInterval(3600)), .wait(until: resume))
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: resume), .attempt)
        // Timer jitter just before the pause ends does not cost a cycle.
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: resume.addingTimeInterval(-10)), .attempt)
    }

    func testLastAttemptInTheFutureDoesNotBlock() {
        // The clock moved back after the attempt was saved.
        let state = AutoStartAttemptState(attempts: AutoStartAttemptPolicy.maxAttempts, lastAttempt: now.addingTimeInterval(86_400))
        XCTAssertEqual(AutoStartAttemptPolicy.decide(state: state, now: now), .attempt)
    }

    func testStateAfterAttemptCountsUpAndRestartsAfterPause() {
        let first = AutoStartAttemptPolicy.stateAfterAttempt(nil, now: now)
        XCTAssertEqual(first, AutoStartAttemptState(attempts: 1, lastAttempt: now))

        let second = AutoStartAttemptPolicy.stateAfterAttempt(first, now: now.addingTimeInterval(300))
        XCTAssertEqual(second.attempts, 2)

        let exhausted = AutoStartAttemptState(attempts: AutoStartAttemptPolicy.maxAttempts, lastAttempt: now)
        let later = now.addingTimeInterval(AutoStartAttemptPolicy.pauseAfterMaxAttempts)
        XCTAssertEqual(
            AutoStartAttemptPolicy.stateAfterAttempt(exhausted, now: later),
            AutoStartAttemptState(attempts: 1, lastAttempt: later)
        )
    }

    // MARK: - Store

    func testStorePersistsAcrossInstancesAndClears() {
        let suiteName = "AutoStartAttemptPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profileID = UUID()
        let otherID = UUID()
        let state = AutoStartAttemptState(attempts: 2, lastAttempt: now)

        AutoStartAttemptStore(defaults: defaults).save(state, for: profileID)
        AutoStartAttemptStore(defaults: defaults).save(state, for: otherID)

        let reloaded = AutoStartAttemptStore(defaults: defaults)
        XCTAssertEqual(reloaded.state(for: profileID), state)

        reloaded.clear(for: profileID)
        XCTAssertNil(AutoStartAttemptStore(defaults: defaults).state(for: profileID))
        XCTAssertEqual(AutoStartAttemptStore(defaults: defaults).state(for: otherID), state)
    }
}
