//
//  MenuBarSlotLayout.swift
//  Claude Usage
//
//  Decides what each enabled single-profile menu bar item shows, given which
//  limits the account has. A spend-limited account shows one spend bar in
//  place of its session and weekly bars; an account without a 5-hour window
//  hides its session bar.
//

import Foundation

enum MenuBarSlotContent: Equatable {
    /// Render the metric as usual.
    case metric
    /// Render the monthly spend bar in this item.
    case spend
    /// Show nothing (zero width).
    case hidden
    /// Show the app logo (nothing else is visible).
    case appLogo
}

enum MenuBarSlotLayout {
    static func contents(enabled: [MenuBarMetricType], usage: ClaudeUsage) -> [MenuBarMetricType: MenuBarSlotContent] {
        var result: [MenuBarMetricType: MenuBarSlotContent] = [:]

        if usage.isSpendLimited {
            var spendPlaced = false
            for metric in enabled {
                if metric == .api {
                    result[metric] = .metric
                } else if !spendPlaced {
                    result[metric] = .spend
                    spendPlaced = true
                } else {
                    result[metric] = .hidden
                }
            }
        } else {
            for metric in enabled {
                switch metric {
                case .session: result[metric] = usage.hasSessionWindow ? .metric : .hidden
                case .week: result[metric] = usage.hasWeeklyWindow ? .metric : .hidden
                case .api: result[metric] = .metric
                }
            }
        }

        let anyVisible = result.values.contains { $0 == .metric || $0 == .spend }
        if !anyVisible, let first = enabled.first {
            result[first] = .appLogo
        }
        return result
    }
}
