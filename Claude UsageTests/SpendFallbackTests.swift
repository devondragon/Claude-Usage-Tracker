import XCTest
@testable import Claude_Usage

@MainActor
final class SpendFallbackTests: XCTestCase {

    private func noWindows() -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.hasWeeklyWindow = false
        return usage
    }

    func testCookieResultWithoutWindowsOrSpendNeedsFallback() {
        XCTAssertTrue(AnthropicUsageProvider.needsSpendFromClaudeCode(noWindows()))
    }

    func testNormalAccountDoesNotNeedFallback() {
        XCTAssertFalse(AnthropicUsageProvider.needsSpendFromClaudeCode(ClaudeUsage.empty))

        var idle = ClaudeUsage.empty
        idle.hasSessionWindow = false  // idle Max: weekly still present
        XCTAssertFalse(AnthropicUsageProvider.needsSpendFromClaudeCode(idle))
    }

    func testAccountWithSpendDoesNotNeedFallback() {
        var usage = noWindows()
        usage.costUsed = 2985
        usage.costLimit = 150000
        XCTAssertFalse(AnthropicUsageProvider.needsSpendFromClaudeCode(usage))
    }

    func testMergeCopiesSpendOnly() {
        var oauth = noWindows()
        oauth.costUsed = 2985
        oauth.costLimit = 150000
        oauth.costCurrency = "USD"
        oauth.spendLimitReached = true
        oauth.weeklyPercentage = 99  // must not be copied

        let merged = AnthropicUsageProvider.mergingSpend(from: oauth, into: noWindows())

        XCTAssertEqual(merged.costUsed, 2985)
        XCTAssertEqual(merged.costLimit, 150000)
        XCTAssertEqual(merged.costCurrency, "USD")
        XCTAssertTrue(merged.spendLimitReached)
        XCTAssertEqual(merged.weeklyPercentage, 0)
        XCTAssertTrue(merged.isSpendLimited)
    }
}
