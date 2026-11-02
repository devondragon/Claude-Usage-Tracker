import XCTest
@testable import Claude_Usage

@MainActor
final class SpendModelTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func spendUsage(used: Double = 2985, limit: Double? = 150000) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.hasWeeklyWindow = false
        usage.costUsed = used
        usage.costLimit = limit
        usage.costCurrency = "USD"
        return usage
    }

    // MARK: - Decoding

    func testLegacyDataDecodesWithWindows() throws {
        let json = #"{"sessionPercentage": 12, "weeklyPercentage": 30}"#
        let usage = try JSONDecoder().decode(ClaudeUsage.self, from: Data(json.utf8))

        XCTAssertTrue(usage.hasSessionWindow)
        XCTAssertTrue(usage.hasWeeklyWindow)
        XCTAssertFalse(usage.spendLimitReached)
        XCTAssertFalse(usage.isSpendLimited)
    }

    func testNoWindowFlagsSurviveRoundTrip() throws {
        let original = spendUsage()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClaudeUsage.self, from: data)

        XCTAssertFalse(decoded.hasSessionWindow)
        XCTAssertFalse(decoded.hasWeeklyWindow)
        XCTAssertTrue(decoded.isSpendLimited)
    }

    // MARK: - Computed state

    func testSpendPercentage() {
        XCTAssertEqual(spendUsage().spendPercentage, 1.99, accuracy: 0.001)
        XCTAssertEqual(spendUsage(used: 160000).spendPercentage, 106.666, accuracy: 0.001)
    }

    func testNoSpendCapIsNotSpendLimited() {
        XCTAssertFalse(spendUsage(limit: nil).isSpendLimited)
        XCTAssertFalse(spendUsage(limit: 0).isSpendLimited)
    }

    func testWeeklyWindowIsNotSpendLimited() {
        var usage = spendUsage()
        usage.hasWeeklyWindow = true

        XCTAssertFalse(usage.isSpendLimited)
    }

    // MARK: - Spend period

    func testPeriodIsUTCMonth() {
        let now = date("2026-11-02T17:27:00Z")
        let period = SpendPeriod.containing(now)

        XCTAssertEqual(period.start, date("2026-11-01T00:00:00Z"))
        XCTAssertEqual(period.end, date("2026-12-01T00:00:00Z"))
        XCTAssertEqual(period.elapsedFraction(at: now), 0.0580, accuracy: 0.001)
    }

    func testPeriodRollsOverAtUTCMidnight() {
        // 6 PM MST on November 30 is already December in UTC.
        let now = date("2026-12-01T01:00:00Z")
        let period = SpendPeriod.containing(now)

        XCTAssertEqual(period.start, date("2026-12-01T00:00:00Z"))
        XCTAssertLessThan(period.elapsedFraction(at: now), 0.002)
    }

    func testPeriodHandlesFebruaryAndDecember() {
        XCTAssertEqual(SpendPeriod.containing(date("2027-02-15T00:00:00Z")).end, date("2027-03-01T00:00:00Z"))
        XCTAssertEqual(SpendPeriod.containing(date("2026-12-31T23:59:00Z")).end, date("2027-01-01T00:00:00Z"))
    }

    // MARK: - Formatting

    func testSpendFormatting() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(SpendFormatting.string(cents: 2985, currency: "USD", locale: locale), "$29.85")
        XCTAssertEqual(SpendFormatting.string(cents: 150000, currency: "USD", locale: locale), "$1,500.00")
    }
}
