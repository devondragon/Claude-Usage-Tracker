import XCTest
@testable import Claude_Usage

@MainActor
final class AutoSwitchEligibilityTests: XCTestCase {

    private func session(_ percent: Double) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = percent
        usage.sessionResetTime = Date().addingTimeInterval(3600)
        return usage
    }

    func testNoCachedUsageIsCandidate() {
        XCTAssertTrue(MenuBarManager.isAutoSwitchCandidate(nil))
    }

    func testSpendLimitedIsNeverCandidate() {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.hasWeeklyWindow = false
        usage.costUsed = 2985
        usage.costLimit = 150000
        usage.costCurrency = "USD"

        XCTAssertFalse(MenuBarManager.isAutoSwitchCandidate(usage))
    }

    func testFullSessionIsNotCandidate() {
        XCTAssertFalse(MenuBarManager.isAutoSwitchCandidate(session(100)))
    }

    func testNormalBelowLimitIsCandidate() {
        XCTAssertTrue(MenuBarManager.isAutoSwitchCandidate(session(40)))
    }

    func testNoWindowAccountWithoutSpendIsNeverCandidate() {
        // Enterprise seat whose spend has not been fetched yet.
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false
        usage.hasWeeklyWindow = false
        XCTAssertFalse(MenuBarManager.isAutoSwitchCandidate(usage))
    }

    func testIdleMaxIsStillCandidate() {
        var usage = ClaudeUsage.empty
        usage.hasSessionWindow = false  // no session running; weekly present
        XCTAssertTrue(MenuBarManager.isAutoSwitchCandidate(usage))
    }
}
