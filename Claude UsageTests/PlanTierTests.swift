import XCTest
@testable import Claude_Usage

@MainActor
final class PlanTierTests: XCTestCase {

    private func credentials(tier: String?, subscription: String?) -> String {
        var oauth: [String: Any] = ["accessToken": "x"]
        if let tier { oauth["rateLimitTier"] = tier }
        if let subscription { oauth["subscriptionType"] = subscription }
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        return String(data: data, encoding: .utf8)!
    }

    func testMax20xHasNoSessionLimit() {
        let json = credentials(tier: "default_claude_max_20x", subscription: "max")
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: json), true)
    }

    func testUltraHasNoSessionLimit() {
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: credentials(tier: nil, subscription: "ultra")), true)
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: credentials(tier: "default_claude_ultra", subscription: nil)), true)
    }

    func testMax5xAndProKeepSessionLimit() {
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: credentials(tier: "default_claude_max_5x", subscription: "max")), false)
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: credentials(tier: "default_claude_pro", subscription: "pro")), false)
    }

    func testUnknownPlanIsNil() {
        XCTAssertNil(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: credentials(tier: nil, subscription: nil)))
        XCTAssertNil(AnthropicUsageProvider.planHasNoSessionLimit(credentialsJSON: "not json"))
    }

    // MARK: - oauthAccount (from ~/.claude.json, stored on the profile)

    private func oauthAccount(org: String?, user: String?) -> String {
        var account: [String: Any] = ["emailAddress": "a@example.com"]
        if let org { account["organizationRateLimitTier"] = org }
        if let user { account["userRateLimitTier"] = user }
        let data = try! JSONSerialization.data(withJSONObject: account)
        return String(data: data, encoding: .utf8)!
    }

    func testOAuthAccountMax20xHasNoSessionLimit() {
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(oauthAccountJSON: oauthAccount(org: "default_claude_max_20x", user: nil)), true)
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(oauthAccountJSON: oauthAccount(org: nil, user: "default_claude_ultra")), true)
    }

    func testOAuthAccountOtherTiersKeepSessionLimit() {
        XCTAssertEqual(AnthropicUsageProvider.planHasNoSessionLimit(oauthAccountJSON: oauthAccount(org: "default_claude_max_5x", user: nil)), false)
    }

    func testOAuthAccountWithoutTierIsNil() {
        XCTAssertNil(AnthropicUsageProvider.planHasNoSessionLimit(oauthAccountJSON: oauthAccount(org: nil, user: nil)))
        XCTAssertNil(AnthropicUsageProvider.planHasNoSessionLimit(oauthAccountJSON: "not json"))
    }

    func testStampingNilLeavesUsageUnchanged() {
        var usage = ClaudeUsage.empty
        usage.planHasNoSessionLimit = true
        XCTAssertTrue(usage.stampingPlan(noSessionLimit: nil).planHasNoSessionLimit)
        XCTAssertFalse(usage.stampingPlan(noSessionLimit: false).planHasNoSessionLimit)
    }

    func testFlagSurvivesCodableRoundTripAndOldDataDecodesFalse() throws {
        var usage = ClaudeUsage.empty
        usage.planHasNoSessionLimit = true
        let decoded = try JSONDecoder().decode(ClaudeUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertTrue(decoded.planHasNoSessionLimit)

        let old = try JSONDecoder().decode(ClaudeUsage.self, from: Data("{}".utf8))
        XCTAssertFalse(old.planHasNoSessionLimit)
    }
}
