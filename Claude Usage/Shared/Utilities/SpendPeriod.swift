//
//  SpendPeriod.swift
//  Claude Usage
//
//  The period a monthly spend cap covers. The usage API reports the cap and
//  the amount spent but no reset time; claude.ai shows the reset as midnight
//  UTC on the 1st ("resets Nov 30th at 5 PM MST"), so the period is the UTC
//  calendar month.
//

import Foundation

struct SpendPeriod: Equatable {
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The UTC calendar month containing `date`.
    static func containing(_ date: Date) -> SpendPeriod {
        let calendar = utcCalendar
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(30 * 86_400)
        return SpendPeriod(start: start, end: end)
    }

    /// Fraction of the period that has passed at `date`, clamped to 0...1.
    func elapsedFraction(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }
}

// MARK: - Formatting

enum SpendFormatting {
    /// Formats an amount in cents as currency, e.g. 2985 USD -> "$29.85".
    static func string(cents: Double, currency: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = currency
        return formatter.string(from: NSNumber(value: cents / 100)) ?? String(format: "%.2f %@", cents / 100, currency)
    }
}
