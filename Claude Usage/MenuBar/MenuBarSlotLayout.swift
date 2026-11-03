//
//  MenuBarSlotLayout.swift
//  Claude Usage
//
//  Decides what each enabled single-profile menu bar item shows. A
//  spend-limited account shows one spend bar in place of its session and
//  weekly bars. A plan without a 5-hour limit (Max 20x / Ultra) shows its
//  weekly bar in place of the session bar. Every other account shows its
//  enabled metrics as before.
//

import Foundation

enum MenuBarSlotContent: Equatable {
    /// Render the metric as usual.
    case metric
    /// Render the monthly spend bar in this item.
    case spend
    /// Render the weekly metric in this item (a session item on a plan with
    /// no session limit).
    case weekly
    /// Show nothing.
    case hidden
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
        } else if usage.planHasNoSessionLimit {
            let weekEnabled = enabled.contains(.week)
            for metric in enabled {
                if metric == .session {
                    result[metric] = weekEnabled ? .hidden : .weekly
                } else {
                    result[metric] = .metric
                }
            }
        } else {
            for metric in enabled {
                result[metric] = .metric
            }
        }
        return result
    }
}
