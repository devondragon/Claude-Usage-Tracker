import XCTest
@testable import Claude_Usage

final class AutoStartScheduleEditingTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Denver")!
        return cal
    }()

    private let day = Date(timeIntervalSince1970: 1_793_000_000)

    private func window(_ start: Int, _ stop: Int) -> AutoStartSchedule.Window {
        .init(startMinute: start, stopMinute: stop)
    }

    func testMinuteRoundTrip() {
        for minute in [0, 1, 420, 725, 1200, 1439] {
            let date = AutoStartScheduleEditing.date(forMinute: minute, on: day, calendar: calendar)
            XCTAssertEqual(AutoStartScheduleEditing.minute(from: date, calendar: calendar), minute)
        }
    }

    func testEndOfDayStopRoundTrips() {
        let date = AutoStartScheduleEditing.date(forMinute: 1440, on: day, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: date), 0)
        XCTAssertEqual(AutoStartScheduleEditing.minute(from: date, calendar: calendar, isStop: true), 1440)
        XCTAssertEqual(AutoStartScheduleEditing.minute(from: date, calendar: calendar, isStop: false), 0)
    }

    func testDateStaysOnGivenDay() {
        let date = AutoStartScheduleEditing.date(forMinute: 1439, on: day, calendar: calendar)
        XCTAssertTrue(calendar.isDate(date, inSameDayAs: day))
    }

    func testClampLeavesValidWindowAlone() {
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(420, 1200)), window(420, 1200))
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(0, 1440)), window(0, 1440))
    }

    func testClampStopAtOrBeforeStart() {
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(600, 600)), window(600, 601))
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(600, 300)), window(600, 601))
    }

    func testClampCapsStartAndStop() {
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(1440, 1440)), window(1439, 1440))
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(100, 2000)), window(100, 1440))
        XCTAssertEqual(AutoStartScheduleEditing.clamped(window(-5, 10)), window(0, 10))
    }
}
