import XCTest
@testable import Claude_Usage

@MainActor
final class SpendNotificationTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
    private let settings = NotificationSettings()

    private func spend(_ percent: Double, reached: Bool = false) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.hasWeeklyWindow = false
        usage.costUsed = 150000 * percent / 100
        usage.costLimit = 150000
        usage.costCurrency = "USD"
        usage.spendLimitReached = reached
        return usage
    }

    private func alert(_ usage: ClaudeUsage) -> ThresholdAlert? {
        NotificationManager.thresholdAlert(for: usage, settings: settings, now: now)
    }

    func testSpendBelowThresholdsGivesNil() {
        XCTAssertNil(alert(spend(2)))
    }

    func testSpendAt91GivesWarning() {
        let result = alert(spend(91))
        XCTAssertEqual(result?.type, .spendWarning)
        XCTAssertEqual(result?.threshold, 90)
        XCTAssertEqual(result?.resetTime, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testSpendAt96GivesCritical() {
        XCTAssertEqual(alert(spend(96))?.type, .spendCritical)
        XCTAssertEqual(alert(spend(96))?.threshold, 95)
    }

    func testSpendAt80GivesInfo() {
        XCTAssertEqual(alert(spend(80))?.type, .spendInfo)
        XCTAssertEqual(alert(spend(80))?.threshold, 75)
    }

    func testLimitReachedWinsOverPercentage() {
        let result = alert(spend(80, reached: true))
        XCTAssertEqual(result?.type, .spendLimitReached)
        XCTAssertEqual(result?.threshold, 100)
    }

    func testOverCapGivesCritical() {
        let result = alert(spend(106))
        XCTAssertEqual(result?.type, .spendCritical)
        XCTAssertEqual(result?.threshold, 95)
    }

    func testNormalSessionUnchanged() {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 92
        usage.sessionResetTime = Date().addingTimeInterval(3600)

        let result = alert(usage)
        XCTAssertEqual(result?.type, .sessionWarning)
        XCTAssertEqual(result?.threshold, 90)
    }

    func testSpendAlertCarriesMonthKey() {
        XCTAssertEqual(alert(spend(80))?.periodKey, "2026-11")
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 92
        usage.sessionResetTime = Date().addingTimeInterval(3600)
        XCTAssertNil(alert(usage)?.periodKey)
    }

    func testAlertIdentifierDiffersByMonth() {
        // Sent-alert IDs persist across restarts; the month keeps November's
        // alert from blocking December's.
        let november = NotificationManager.alertIdentifier(profileName: "Tribe", type: .spendInfo, level: 75, periodKey: "2026-11")
        let december = NotificationManager.alertIdentifier(profileName: "Tribe", type: .spendInfo, level: 75, periodKey: "2026-12")
        XCTAssertNotEqual(november, december)
        XCTAssertEqual(
            NotificationManager.alertIdentifier(profileName: "Tribe", type: .sessionInfo, level: 75, periodKey: nil),
            "Tribe_session_info_75"
        )
    }
}
