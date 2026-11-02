import XCTest
@testable import Claude_Usage

@MainActor
final class AutoStartSchedulePolicyTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        return cal
    }()

    private let schedule = AutoStartSchedule.default

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func inSchedule(_ d: Date, _ s: AutoStartSchedule? = nil) -> Bool {
        AutoStartSchedulePolicy.isInSchedule(s ?? schedule, at: d, calendar: calendar)
    }

    private func nextStart(_ d: Date, _ s: AutoStartSchedule? = nil) -> Date {
        AutoStartSchedulePolicy.nextStart(after: d, schedule: s ?? schedule, calendar: calendar)
    }

    // MARK: - isInSchedule

    func testWeekdayInsideWindow() {
        XCTAssertTrue(inSchedule(date(2026, 11, 2, 8)))
    }

    func testExactlyAtStartIsIn() {
        XCTAssertTrue(inSchedule(date(2026, 11, 2, 7)))
        XCTAssertFalse(inSchedule(date(2026, 11, 2, 6, 59)))
    }

    func testAfterStopIsOutOfSchedule() {
        XCTAssertFalse(inSchedule(date(2026, 11, 2, 20)))
        XCTAssertTrue(inSchedule(date(2026, 11, 2, 19, 59)))
    }

    func testSaturdayUsesWeekendWindow() {
        XCTAssertFalse(inSchedule(date(2026, 11, 7, 8)))
        XCTAssertTrue(inSchedule(date(2026, 11, 7, 9)))
    }

    // MARK: - nextStart

    func testNextStartLaterToday() {
        XCTAssertEqual(nextStart(date(2026, 11, 2, 5)), date(2026, 11, 2, 7))
    }

    func testNextStartAcrossWeekend() {
        XCTAssertEqual(nextStart(date(2026, 11, 6, 21)), date(2026, 11, 7, 9))
        XCTAssertEqual(nextStart(date(2026, 11, 8, 23)), date(2026, 11, 9, 7))
    }

    func testSpringForwardDay() {
        // 2027-03-14 is a Sunday; 2:00 to 3:00 does not exist in Denver.
        let custom = AutoStartSchedule(
            weekdays: schedule.weekdays,
            weekends: AutoStartSchedule.Window(startMinute: 60, stopMinute: 22 * 60)
        )
        XCTAssertTrue(inSchedule(date(2027, 3, 14, 2, 30), custom))
        XCTAssertEqual(nextStart(date(2027, 3, 13, 23), custom), date(2027, 3, 14, 1))
    }

    // MARK: - Profile

    func testProfileDecodesWithoutSchedule() throws {
        let data = try JSONEncoder().encode(Profile(name: "P", autoStartSchedule: schedule))
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["autoStartSchedule"])
        json.removeValue(forKey: "autoStartSchedule")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Profile.self, from: stripped)
        XCTAssertNil(decoded.autoStartSchedule)
        XCTAssertEqual(decoded.effectiveAutoStartSchedule, .default)
    }

    func testProfileRoundTripsSchedule() throws {
        let custom = AutoStartSchedule(
            weekdays: AutoStartSchedule.Window(startMinute: 360, stopMinute: 1080),
            weekends: AutoStartSchedule.Window(startMinute: 600, stopMinute: 900)
        )
        let data = try JSONEncoder().encode(Profile(name: "P", autoStartSchedule: custom))
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.autoStartSchedule, custom)
        XCTAssertEqual(decoded.effectiveAutoStartSchedule, custom)
    }
}
