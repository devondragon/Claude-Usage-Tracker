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
        try ClaudeAPIService.parseUsageResponse(Data(json.utf8))
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

    // Abridged from a Max account's /api/oauth/usage response with no session running,
    // 2026-11-02: five_hour is null exactly as on an account without a 5-hour limit.
    private let idleMaxJSON = """
    {
      "five_hour": null,
      "seven_day": {"utilization": 16.0, "resets_at": "2026-11-04T09:00:00.171755+00:00"},
      "extra_usage": {
        "is_enabled": false, "monthly_limit": 10000, "used_credits": 0.0, "currency": "USD",
        "decimal_places": 2, "disabled_reason": "out_of_credits", "spend_limit_reached": false
      },
      "limits": [{"kind": "weekly_all", "group": "weekly", "percent": 16, "is_active": true}]
    }
    """

    func testIdleMaxAccountIsNotSpendLimited() throws {
        let usage = try parse(idleMaxJSON)

        XCTAssertFalse(usage.isSpendLimited)
        XCTAssertTrue(usage.hasWeeklyWindow)
        XCTAssertNil(usage.costLimit)
    }

    func testLimitsEntriesCountAsWindows() throws {
        // No five_hour or seven_day block, but the plan still lists limits:
        // not a spend-only account even with extra usage enabled.
        var json = object(enterpriseJSON)
        json["limits"] = [["kind": "weekly_all", "group": "weekly", "percent": 0, "is_active": false]]
        let usage = try parse(jsonString(json))

        XCTAssertTrue(usage.hasWeeklyWindow)
        XCTAssertFalse(usage.isSpendLimited)
    }

    func testDisabledExtraUsageIsIgnored() throws {
        let usage = try parse(#"{"five_hour": null, "seven_day": null, "extra_usage": {"is_enabled": false, "monthly_limit": 150000, "used_credits": 10}}"#)

        XCTAssertFalse(usage.isSpendLimited)
        XCTAssertNil(usage.costLimit)
    }

    func testAutoStartParserKeepsIdleMaxStartable() throws {
        let (usage, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(idleMaxJSON.utf8))

        // Idle: no open window, and not spend-limited, so auto-start may run.
        XCTAssertFalse(hasOpenWindow)
        XCTAssertFalse(usage.isSpendLimited)
    }

    func testAutoStartParserFlagsMissingSessionWindow() throws {
        let (usage, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(enterpriseJSON.utf8))

        XCTAssertFalse(usage.hasSessionWindow)
        XCTAssertFalse(hasOpenWindow)
        // This usage is saved to the profile, so it must keep the spend data.
        XCTAssertTrue(usage.isSpendLimited)
        XCTAssertEqual(usage.costUsed, 2985)
    }

    func testDisabledExtraUsageFallsThroughToSpendBlock() throws {
        var json = object(enterpriseJSON)
        var extra = json["extra_usage"] as! [String: Any]
        extra["is_enabled"] = false
        json["extra_usage"] = extra
        let usage = try parse(jsonString(json))

        XCTAssertEqual(usage.costLimit, 150000)  // from the enabled spend block
        XCTAssertTrue(usage.isSpendLimited)
    }

    func testParsedSpendRecordsWhenItWasRead() throws {
        let before = Date()
        let usage = try parse(enterpriseJSON)
        XCTAssertNotNil(usage.spendUpdatedAt)
        XCTAssertGreaterThanOrEqual(usage.spendUpdatedAt ?? .distantPast, before.addingTimeInterval(-1))
    }

    func testAutoStartSkipsEnterpriseSeatWithoutSpend() throws {
        // claude.ai's response for an Enterprise seat: no windows, no spend.
        let claudeAI = #"{"five_hour": null, "seven_day": null, "limits": []}"#
        let (seat, _) = try AutoStartSessionService.parseUsageResponse(Data(claudeAI.utf8))
        XCTAssertTrue(AutoStartSessionService.shouldSkipAutoStart(seat))

        let (idleMax, _) = try AutoStartSessionService.parseUsageResponse(Data(idleMaxJSON.utf8))
        XCTAssertFalse(AutoStartSessionService.shouldSkipAutoStart(idleMax))
    }

    func testOverageWithoutLimitDoesNotEraseSpend() throws {
        // claude.ai's overage endpoint can report enabled with no limit (Enterprise seats).
        var usage = try parse(enterpriseJSON)
        let noLimit = try JSONDecoder().decode(
            ClaudeAPIService.OverageSpendLimitResponse.self,
            from: Data(#"{"is_enabled": true, "monthly_credit_limit": null, "used_credits": null, "currency": "USD"}"#.utf8)
        )
        usage = ClaudeAPIService.applyingOverage(noLimit, to: usage)
        XCTAssertEqual(usage.costLimit, 150000)

        let withLimit = try JSONDecoder().decode(
            ClaudeAPIService.OverageSpendLimitResponse.self,
            from: Data(#"{"is_enabled": true, "monthly_credit_limit": 10000, "used_credits": 250, "currency": "USD"}"#.utf8)
        )
        let applied = ClaudeAPIService.applyingOverage(withLimit, to: ClaudeUsage.empty)
        XCTAssertEqual(applied.costLimit, 10000)
        XCTAssertEqual(applied.costUsed, 250)
        XCTAssertNotNil(applied.spendUpdatedAt)
    }
}
