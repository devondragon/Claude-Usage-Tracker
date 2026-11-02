import XCTest
@testable import Claude_Usage

@MainActor
final class SpendParsingTests: XCTestCase {

    // Abridged from the Tribe (Claude Enterprise) /api/oauth/usage response, 2026-11-02.
    private let enterpriseJSON = """
    {
      "five_hour": null, "seven_day": null, "seven_day_opus": null, "seven_day_sonnet": null,
      "limits": [],
      "extra_usage": {
        "is_enabled": true, "monthly_limit": 150000, "used_credits": 2985.0, "utilization": 1.99,
        "currency": "USD", "decimal_places": 2, "spend_limit_reached": false
      },
      "spend": {
        "used": {"amount_minor": 2985, "currency": "USD", "exponent": 2},
        "limit": {"amount_minor": 150000, "currency": "USD", "exponent": 2},
        "percent": 2, "severity": "normal", "enabled": true
      }
    }
    """

    private func parse(_ json: String) throws -> ClaudeUsage {
        try ClaudeAPIService().parseUsageResponse(Data(json.utf8))
    }

    private func object(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    private func jsonString(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testEnterpriseResponse() throws {
        let usage = try parse(enterpriseJSON)

        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertFalse(usage.hasWeeklyWindow)
        XCTAssertEqual(usage.costUsed, 2985)
        XCTAssertEqual(usage.costLimit, 150000)
        XCTAssertEqual(usage.costCurrency, "USD")
        XCTAssertTrue(usage.isSpendLimited)
        XCTAssertFalse(usage.spendLimitReached)
    }

    func testSpendBlockFallback() throws {
        var json = object(enterpriseJSON)
        json.removeValue(forKey: "extra_usage")
        let usage = try parse(jsonString(json))

        XCTAssertEqual(usage.costUsed, 2985)
        XCTAssertEqual(usage.costLimit, 150000)
        XCTAssertEqual(usage.costCurrency, "USD")
        XCTAssertTrue(usage.isSpendLimited)
    }

    func testDecimalPlacesScale() throws {
        var json = object(enterpriseJSON)
        json["extra_usage"] = [
            "is_enabled": true, "monthly_limit": 1500000, "used_credits": 29850,
            "currency": "USD", "decimal_places": 3, "spend_limit_reached": false
        ]
        let usage = try parse(jsonString(json))

        XCTAssertEqual(usage.costUsed ?? 0, 2985, accuracy: 0.0001)
        XCTAssertEqual(usage.costLimit ?? 0, 150000, accuracy: 0.0001)
    }

    func testLimitReachedFlag() throws {
        var json = object(enterpriseJSON)
        var extra = json["extra_usage"] as! [String: Any]
        extra["spend_limit_reached"] = true
        json["extra_usage"] = extra

        XCTAssertTrue(try parse(jsonString(json)).spendLimitReached)
    }

    func testMaxPlanWithExtraUsageKeepsWindows() throws {
        var json = object(enterpriseJSON)
        json["five_hour"] = ["utilization": 42, "resets_at": "2026-11-02T20:00:00.000Z"]
        json["seven_day"] = ["utilization": 31, "resets_at": "2026-11-06T20:00:00.000Z"]
        let usage = try parse(jsonString(json))

        XCTAssertTrue(usage.hasSessionWindow)
        XCTAssertTrue(usage.hasWeeklyWindow)
        XCTAssertFalse(usage.isSpendLimited)
        XCTAssertEqual(usage.costUsed, 2985)
        XCTAssertEqual(usage.costLimit, 150000)
    }

    func testUltraResponseHasNoSessionWindow() throws {
        let usage = try parse(#"{"five_hour": null, "seven_day": {"utilization": 12, "resets_at": "2026-11-06T20:00:00.000Z"}}"#)

        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertTrue(usage.hasWeeklyWindow)
    }

    func testDisabledExtraUsageIsIgnored() throws {
        let usage = try parse(#"{"five_hour": null, "seven_day": null, "extra_usage": {"is_enabled": false, "monthly_limit": 150000, "used_credits": 10}}"#)

        XCTAssertTrue(usage.reportsNoLimits)
        XCTAssertNil(usage.costLimit)
    }

    func testAutoStartParserFlagsMissingSessionWindow() throws {
        let (usage, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(enterpriseJSON.utf8))

        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertFalse(hasOpenWindow)
        // This usage is saved to the profile, so it must keep the spend data.
        XCTAssertTrue(usage.isSpendLimited)
        XCTAssertEqual(usage.costUsed, 2985)
    }
}
