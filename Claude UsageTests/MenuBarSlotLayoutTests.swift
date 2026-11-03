import XCTest
@testable import Claude_Usage

@MainActor
final class MenuBarSlotLayoutTests: XCTestCase {

    private func usage(session: Bool = true, weekly: Bool = true, limit: Double? = nil) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = session
        usage.hasWeeklyWindow = weekly
        if let limit {
            usage.costUsed = 2985
            usage.costLimit = limit
            usage.costCurrency = "USD"
        }
        return usage
    }

    func testNormalAccountShowsEnabledMetrics() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session, .week], usage: usage()),
            [.session: .metric, .week: .metric]
        )
    }

    func testSpendLimitedUsesFirstSlot() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session, .week, .api], usage: usage(session: false, weekly: false, limit: 150000)),
            [.session: .spend, .week: .hidden, .api: .metric]
        )
    }

    func testSpendLimitedWithWeekFirst() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.week], usage: usage(session: false, weekly: false, limit: 150000)),
            [.week: .spend]
        )
    }

    func testIdleSessionKeepsSessionBar() {
        // five_hour null also means "no session running"; the bar stays.
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session, .week], usage: usage(session: false)),
            [.session: .metric, .week: .metric]
        )
    }

    func testNoWindowsWithoutSpendCapKeepsBars() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session], usage: usage(session: false, weekly: false)),
            [.session: .metric]
        )
    }

    // MARK: - Plans without a session limit (Max 20x / Ultra)

    private func noSessionPlan() -> ClaudeUsage {
        var usage = usage(session: false)
        usage.planHasNoSessionLimit = true
        return usage
    }

    func testNoSessionPlanShowsWeeklyInSessionItem() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session], usage: noSessionPlan()),
            [.session: .weekly]
        )
    }

    func testNoSessionPlanHidesSessionWhenWeekEnabled() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session, .week, .api], usage: noSessionPlan()),
            [.session: .hidden, .week: .metric, .api: .metric]
        )
    }

    func testNoSessionPlanWeekOnlyUnchanged() {
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.week], usage: noSessionPlan()),
            [.week: .metric]
        )
    }

    func testSpendLimitWinsOverNoSessionPlan() {
        var usage = usage(session: false, weekly: false, limit: 150000)
        usage.planHasNoSessionLimit = true
        XCTAssertEqual(
            MenuBarSlotLayout.contents(enabled: [.session, .week], usage: usage),
            [.session: .spend, .week: .hidden]
        )
    }
}
