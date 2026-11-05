import XCTest
@testable import Claude_Usage

@MainActor
final class AutoStartDecisionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func usage(weekly: Double = 10, noWindows: Bool = false) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.weeklyPercentage = weekly
        u.sessionResetTime = now.addingTimeInterval(3600)
        if noWindows {
            u.hasSessionWindow = false
            u.hasWeeklyWindow = false
        }
        return u
    }

    private func decide(
        inSchedule: Bool = true,
        _ reading: AutoStartUsageReading,
        attempt: AutoStartAttemptPolicy.Decision = .attempt
    ) -> AutoStartAction {
        AutoStartDecision.decide(inSchedule: inSchedule, reading: reading, attempt: attempt)
    }

    func testOutOfScheduleSkips() {
        XCTAssertEqual(decide(inSchedule: false, .live(usage(), hasOpenWindow: false)), .skip(.outOfSchedule))
    }

    func testOutOfScheduleWinsOverFetchFailure() {
        XCTAssertEqual(decide(inSchedule: false, .failed("boom")), .skip(.outOfSchedule))
    }

    func testFetchErrorSkipsWithoutAttempt() {
        XCTAssertEqual(decide(.failed("boom"), attempt: .attempt), .skip(.usageFetchFailed("boom")))
    }

    func testNoUsageWindowsSkips() {
        XCTAssertEqual(decide(.live(usage(noWindows: true), hasOpenWindow: false)), .skip(.noUsageWindows))
    }

    func testNoSessionLimitPlanSkips() {
        var u = usage()
        u.hasSessionWindow = false
        u.planHasNoSessionLimit = true
        XCTAssertEqual(decide(.live(u, hasOpenWindow: false)), .skip(.noSessionLimit))
    }

    func testOpenWindowSkipsWithResetTime() {
        let u = usage()
        XCTAssertEqual(decide(.live(u, hasOpenWindow: true)), .skip(.windowOpen(until: u.sessionResetTime)))
    }

    func testWeeklyAt99Pings() {
        XCTAssertEqual(decide(.live(usage(weekly: 99), hasOpenWindow: false)), .ping)
    }

    func testWeeklyAt100Skips() {
        XCTAssertEqual(decide(.live(usage(weekly: 100), hasOpenWindow: false)), .skip(.weeklyLimitReached))
    }

    func testBackoffSkips() {
        let until = now.addingTimeInterval(300)
        XCTAssertEqual(
            decide(.live(usage(), hasOpenWindow: false), attempt: .wait(until: until)),
            .skip(.backingOff(until: until))
        )
    }

    func testLiveIdleAndAllowedPings() {
        XCTAssertEqual(decide(.live(usage(), hasOpenWindow: false)), .ping)
    }

    func testTokenExpiredPingsWhenAttemptAllowed() {
        XCTAssertEqual(decide(.tokenExpired, attempt: .attempt), .ping)
    }

    func testTokenExpiredRespectsBackoff() {
        let until = now.addingTimeInterval(300)
        XCTAssertEqual(decide(.tokenExpired, attempt: .wait(until: until)), .skip(.backingOff(until: until)))
    }
}
