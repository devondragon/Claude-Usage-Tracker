//
//  AutoStartSchedulePolicy.swift
//  Claude Usage
//
//  Weekday and weekend hours during which auto-start may open a session
//  window for a profile.
//

import Foundation

/// Daily start and stop times, as minutes since local midnight, for weekdays
/// and for weekends.
struct AutoStartSchedule: Codable, Equatable {
    struct Window: Codable, Equatable {
        var startMinute: Int
        var stopMinute: Int
    }

    var weekdays: Window
    var weekends: Window

    static let `default` = AutoStartSchedule(
        weekdays: Window(startMinute: 420, stopMinute: 1200),
        weekends: Window(startMinute: 540, stopMinute: 1320)
    )
}

// MARK: - Policy

enum AutoStartSchedulePolicy {
    /// Window that applies to the calendar day containing `date`.
    static func window(for date: Date, in schedule: AutoStartSchedule, calendar: Calendar) -> AutoStartSchedule.Window {
        isWeekend(date, calendar: calendar) ? schedule.weekends : schedule.weekdays
    }

    /// True when `date` is at or after the day's start and before its stop.
    static func isInSchedule(_ schedule: AutoStartSchedule, at date: Date, calendar: Calendar) -> Bool {
        let window = window(for: date, in: schedule, calendar: calendar)
        // Wall-clock minutes, not elapsed seconds, so DST days compare correctly.
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= window.startMinute && minute < window.stopMinute
    }

    /// First window start strictly after `date`.
    static func nextStart(after date: Date, schedule: AutoStartSchedule, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let window = window(for: day, in: schedule, calendar: calendar)
            guard let start = calendar.date(
                bySettingHour: window.startMinute / 60,
                minute: window.startMinute % 60,
                second: 0,
                of: day
            ) else { continue }
            if start > date { return start }
        }
        // Unreachable for valid minutes; fall back to a day later.
        return date.addingTimeInterval(86_400)
    }

    private static func isWeekend(_ date: Date, calendar: Calendar) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }
}
