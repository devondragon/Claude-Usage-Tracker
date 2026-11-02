import XCTest
@testable import Claude_Usage

@MainActor
final class MultiProfileBarValuesTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-11-02T17:27:00Z")!

    func testNormalProfile() {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 42
        usage.sessionResetTime = now.addingTimeInterval(2 * 3600)
        usage.weeklyPercentage = 31
        usage.weeklyResetTime = now.addingTimeInterval(3 * 86_400)

        let values = MultiProfileBarValues.make(for: usage, showWeek: true, now: now)

        XCTAssertEqual(values.primaryUsed, 42)
        XCTAssertEqual(values.secondaryUsed, 31)
        XCTAssertNotNil(values.primaryElapsed)
        XCTAssertNotNil(values.secondaryElapsed)
        XCTAssertFalse(values.isSpend)
    }

    func testSpendProfile() {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.hasWeeklyWindow = false
        usage.costUsed = 2985
        usage.costLimit = 150000
        usage.costCurrency = "USD"

        let values = MultiProfileBarValues.make(for: usage, showWeek: true, now: now)

        XCTAssertEqual(values.primaryUsed, 1.99, accuracy: 0.001)
        XCTAssertEqual(values.primaryElapsed ?? 0, 0.058, accuracy: 0.001)
        XCTAssertNil(values.secondaryUsed)
        XCTAssertNil(values.secondaryElapsed)
        XCTAssertTrue(values.isSpend)
    }

    func testIdleSessionKeepsBothBars() {
        // five_hour null also means "no session running"; both bars stay.
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.weeklyPercentage = 31
        usage.weeklyResetTime = now.addingTimeInterval(3 * 86_400)

        let values = MultiProfileBarValues.make(for: usage, showWeek: true, now: now)

        XCTAssertEqual(values.primaryUsed, 0)
        XCTAssertEqual(values.secondaryUsed, 31)
        XCTAssertFalse(values.isSpend)
    }
}
