import XCTest
@testable import Claude_Usage

@MainActor
final class AutoStartStatusStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var calendar: Calendar!
    private let profileID = UUID()

    override func setUp() {
        super.setUp()
        suiteName = "AutoStartStatusStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testShouldLogOncePerDay() {
        var store = AutoStartStatusStore(defaults: defaults)
        XCTAssertTrue(store.shouldLog(.weeklyLimitReached, for: profileID, now: date(2, 8), calendar: calendar))
        XCTAssertFalse(store.shouldLog(.weeklyLimitReached, for: profileID, now: date(2, 8, 5), calendar: calendar))
        XCTAssertFalse(store.shouldLog(.weeklyLimitReached, for: profileID, now: date(2, 23, 59), calendar: calendar))
    }

    func testShouldLogComparesByCaseIgnoringAssociatedValues() {
        var store = AutoStartStatusStore(defaults: defaults)
        XCTAssertTrue(store.shouldLog(.usageFetchFailed("429"), for: profileID, now: date(2, 8), calendar: calendar))
        XCTAssertFalse(store.shouldLog(.usageFetchFailed("timeout"), for: profileID, now: date(2, 9), calendar: calendar))
    }

    func testShouldLogAgainNextDay() {
        var store = AutoStartStatusStore(defaults: defaults)
        XCTAssertTrue(store.shouldLog(.binaryNotFound, for: profileID, now: date(2, 23), calendar: calendar))
        XCTAssertTrue(store.shouldLog(.binaryNotFound, for: profileID, now: date(3, 0, 1), calendar: calendar))
    }

    func testDifferentReasonsLogSeparately() {
        var store = AutoStartStatusStore(defaults: defaults)
        XCTAssertTrue(store.shouldLog(.accountMismatch, for: profileID, now: date(2, 8), calendar: calendar))
        XCTAssertTrue(store.shouldLog(.noClaudeCodeLogin, for: profileID, now: date(2, 8), calendar: calendar))
        XCTAssertTrue(store.shouldLog(.accountMismatch, for: UUID(), now: date(2, 8), calendar: calendar))
    }

    func testShouldLogPersistsAcrossInstances() {
        var first = AutoStartStatusStore(defaults: defaults)
        XCTAssertTrue(first.shouldLog(.accountMismatch, for: profileID, now: date(2, 8), calendar: calendar))
        var second = AutoStartStatusStore(defaults: defaults)
        XCTAssertFalse(second.shouldLog(.accountMismatch, for: profileID, now: date(2, 9), calendar: calendar))
    }

    func testResultRoundTrip() {
        let store = AutoStartStatusStore(defaults: defaults)
        XCTAssertNil(store.lastResult(for: profileID))

        let result = AutoStartResult(date: date(2, 7), success: false, message: "claude timed out")
        store.saveResult(result, for: profileID)
        XCTAssertEqual(AutoStartStatusStore(defaults: defaults).lastResult(for: profileID), result)

        let later = AutoStartResult(date: date(2, 12), success: true, message: nil)
        store.saveResult(later, for: profileID)
        XCTAssertEqual(store.lastResult(for: profileID), later)
        XCTAssertNil(store.lastResult(for: UUID()))
    }

    func testSaveResultPostsNotification() {
        let store = AutoStartStatusStore(defaults: defaults)
        let posted = expectation(forNotification: .autoStartResultChanged, object: nil)
        store.saveResult(AutoStartResult(date: date(2, 7), success: true, message: nil), for: profileID)
        wait(for: [posted], timeout: 1)
    }
}
