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

    func testSpendFetchIsThrottled() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(AnthropicUsageProvider.shouldFetchSpend(lastFetch: nil, now: now))
        XCTAssertFalse(AnthropicUsageProvider.shouldFetchSpend(lastFetch: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(AnthropicUsageProvider.shouldFetchSpend(lastFetch: now.addingTimeInterval(-300), now: now))
    }

    func testCachedSpendIsKeptWhenFetchIsSkipped() {
        var cached = noWindows()
        cached.costUsed = 2985
        cached.costLimit = 150000
        cached.costCurrency = "USD"

        let merged = AnthropicUsageProvider.mergingSpend(from: cached, into: noWindows())
        XCTAssertTrue(merged.isSpendLimited)
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

    func testEnabledZeroLimitStillNeedsFallback() {
        // claude.ai's overage endpoint can report an enabled limit of 0.
        var usage = noWindows()
        usage.costUsed = 0
        usage.costLimit = 0
        XCTAssertTrue(AnthropicUsageProvider.needsSpendFromClaudeCode(usage))
    }

    // MARK: - resolveSpend

    private let now = ISO8601DateFormatter().date(from: "2026-11-01T06:00:00Z")!

    private func withSpend(_ base: ClaudeUsage, limit: Double?, at date: Date?) -> ClaudeUsage {
        var usage = base
        usage.costUsed = limit == nil ? nil : 1440
        usage.costLimit = limit
        usage.costCurrency = limit == nil ? nil : "USD"
        usage.spendUpdatedAt = date
        return usage
    }

    func testSuccessfulFetchWithoutCapClearsCachedCap() {
        let cached = withSpend(noWindows(), limit: 150000, at: now.addingTimeInterval(-60))
        let fetched = withSpend(noWindows(), limit: nil, at: now)

        let result = AnthropicUsageProvider.resolveSpend(usage: noWindows(), fetched: fetched, cached: cached, now: now)
        XCTAssertNil(result.costLimit)
        XCTAssertFalse(result.isSpendLimited)
    }

    func testCachedSpendFromLastMonthIsDropped() {
        // October's spend must not be shown or alerted on in November.
        let october = ISO8601DateFormatter().date(from: "2026-10-31T23:00:00Z")!
        let cached = withSpend(noWindows(), limit: 150000, at: october)

        let result = AnthropicUsageProvider.resolveSpend(usage: noWindows(), fetched: nil, cached: cached, now: now)
        XCTAssertNil(result.costLimit)
    }

    func testCachedSpendFromThisMonthIsKept() {
        let cached = withSpend(noWindows(), limit: 150000, at: now.addingTimeInterval(-120))

        let result = AnthropicUsageProvider.resolveSpend(usage: noWindows(), fetched: nil, cached: cached, now: now)
        XCTAssertEqual(result.costLimit, 150000)
        XCTAssertEqual(result.spendUpdatedAt, cached.spendUpdatedAt)
    }
}
