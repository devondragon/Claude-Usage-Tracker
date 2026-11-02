//
//  AutoStartScheduleEditing.swift
//  Claude Usage
//
//  Pure helpers that convert schedule minutes to and from the Dates a
//  DatePicker edits, and keep a window valid.
//

import Foundation

enum AutoStartScheduleEditing {
    static let minutesPerDay = 1440

    /// A date on `day` at `minute` after local midnight. Minute 1440 (end of
    /// day) maps to 00:00, so a stop picker shows it as 12:00 AM.
    static func date(forMinute minute: Int, on day: Date, calendar: Calendar) -> Date {
        let clamped = max(0, min(minute, minutesPerDay))
        let start = calendar.startOfDay(for: day)
        return calendar.date(
            bySettingHour: (clamped % minutesPerDay) / 60,
            minute: clamped % 60,
            second: 0,
            of: start
        ) ?? start
    }

    /// Minutes after local midnight for the picked time. For a stop time,
    /// 00:00 means end of day (1440).
    static func minute(from date: Date, calendar: Calendar, isStop: Bool = false) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return isStop && minute == 0 ? minutesPerDay : minute
    }

    /// Start capped at 1439; a stop at or before the start becomes start + 1,
    /// and the stop is capped at 1440.
    static func clamped(_ window: AutoStartSchedule.Window) -> AutoStartSchedule.Window {
        let start = max(0, min(window.startMinute, minutesPerDay - 1))
        var stop = min(window.stopMinute, minutesPerDay)
        if stop <= start { stop = start + 1 }
        return AutoStartSchedule.Window(startMinute: start, stopMinute: stop)
    }
}
