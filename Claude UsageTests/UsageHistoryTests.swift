import XCTest
@testable import Claude_Usage

final class UsageHistoryTests: XCTestCase {

    // MARK: - Reset Detection (#337)

    func testJitterAcrossMinuteBoundaryIsNotReset() {
        // Consecutive reset times observed from the API for the same weekly reset
        let before = Date(timeIntervalSinceReferenceDate: 812354399.789)
        let after = Date(timeIntervalSinceReferenceDate: 812354400.410)
        XCTAssertFalse(ResetDetection.isReset(from: before, to: after))
        XCTAssertFalse(ResetDetection.isReset(from: after, to: before))
    }

    func testSmallDriftIsNotReset() {
        let before = Date(timeIntervalSinceReferenceDate: 812354400)
        XCTAssertFalse(ResetDetection.isReset(from: before, to: before.addingTimeInterval(60)))
        XCTAssertFalse(ResetDetection.isReset(from: before, to: before))
    }

    func testSessionResetIsDetected() {
        let before = Date(timeIntervalSinceReferenceDate: 812354400)
        XCTAssertTrue(ResetDetection.isReset(from: before, to: before.addingTimeInterval(5 * 3600)))
    }

    func testWeeklyResetIsDetected() {
        // Real weekly transition from the same history file
        let before = Date(timeIntervalSinceReferenceDate: 811749599.752)
        let after = Date(timeIntervalSinceReferenceDate: 812354400.45)
        XCTAssertTrue(ResetDetection.isReset(from: before, to: after))
    }

    func testBackwardJumpIsDetected() {
        let before = Date(timeIntervalSinceReferenceDate: 812354400)
        XCTAssertTrue(ResetDetection.isReset(from: before, to: before.addingTimeInterval(-3600)))
    }

    func testPlaceholderDriftWhileResetIsUpcomingIsNotReset() {
        // Idle session with no resets_at: parsers substitute now + 5h, which moves
        // by the refresh interval (max 300 s) plus request latency on every poll.
        let now = Date(timeIntervalSinceReferenceDate: 812354400)
        let previous = now.addingTimeInterval(5 * 3600 - 310)
        let new = now.addingTimeInterval(5 * 3600)
        XCTAssertFalse(ResetDetection.isReset(from: previous, to: new, now: now))
    }

    func testResetIsDetectedOncePreviousResetTimeHasPassed() {
        let now = Date(timeIntervalSinceReferenceDate: 812354400)
        let previous = now.addingTimeInterval(-30)
        XCTAssertTrue(ResetDetection.isReset(from: previous, to: now.addingTimeInterval(5 * 3600), now: now))
    }

    // MARK: - Pruning (#337)

    private func snapshot(_ type: ResetType, at timestamp: Date, triggeringResetTime: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            timestamp: timestamp,
            resetType: type,
            sessionPercentage: 10,
            triggeringResetTime: triggeringResetTime ?? timestamp
        )
    }

    func testPruneRemovesSnapshotsWithFutureResetTime() {
        let now = Date()
        var history = UsageHistoryData(snapshots: [
            snapshot(.weeklyReset, at: now),
            snapshot(.weeklyReset, at: now, triggeringResetTime: now.addingTimeInterval(3 * 86400)),
            snapshot(.sessionReset, at: now, triggeringResetTime: now.addingTimeInterval(3600))
        ])

        XCTAssertTrue(history.prune(limits: [:]))
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.weeklySnapshots.count, 1)
    }

    func testPruneCapsEachTypeKeepingNewest() {
        let base = Date(timeIntervalSinceReferenceDate: 800000000)
        let sessions = (0..<10).map { snapshot(.sessionReset, at: base.addingTimeInterval(Double($0) * 600)) }
        let weekly = (0..<4).map { snapshot(.weeklyReset, at: base.addingTimeInterval(Double($0) * 7200)) }
        var history = UsageHistoryData(snapshots: (sessions + weekly).shuffled())

        XCTAssertTrue(history.prune(limits: [.sessionReset: 3, .weeklyReset: 5]))

        XCTAssertEqual(history.sessionSnapshots.map(\.timestamp), sessions.suffix(3).reversed().map(\.timestamp))
        XCTAssertEqual(history.weeklySnapshots.count, 4)
    }

    func testPruneReportsNoChangeWhenWithinLimits() {
        let now = Date()
        var history = UsageHistoryData(snapshots: [snapshot(.sessionReset, at: now)])
        XCTAssertFalse(history.prune(limits: [.sessionReset: 10]))
        XCTAssertEqual(history.count, 1)
    }
}

// MARK: - Billing reset time parsing (#337)

final class BillingResetTimeParsingTests: XCTestCase {

    func testParsesWithFractionalSeconds() {
        let date = ClaudeAPIService.parseBillingResetTime("2026-12-01T00:00:00.000Z")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testParsesWithoutFractionalSeconds() {
        let date = ClaudeAPIService.parseBillingResetTime("2026-12-01T00:00:00Z")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testUnparseableValueFallsBackToStableStartOfNextMonth() {
        let now = ISO8601DateFormatter().date(from: "2026-11-01T23:54:00Z")!
        let later = now.addingTimeInterval(600)
        let expected = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")
        XCTAssertEqual(ClaudeAPIService.parseBillingResetTime("", now: now), expected)
        XCTAssertEqual(ClaudeAPIService.parseBillingResetTime("", now: later), expected)
    }
}
