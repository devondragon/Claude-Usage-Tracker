# Monthly spend display for spend-limited accounts

Date: 2026-11-02. Related upstream issues: #356 (no 5-hour limit on Ultra), #325 (team "Extra Usage" shows org totals).

## Why

Devon's Tribe profile is a Claude Enterprise seat (`organizationType: claude_enterprise`, `seatTier: enterprise_usage_based`). It has no 5-hour window and no weekly window. Its only limit is a monthly spend cap, currently $1,500, with $29.85 spent (2%) on November 2, 2026. claude.ai (Settings > Usage) shows "resets Nov 30th at 5 PM MST", and Claude Code's `/usage` shows it as "usage credits".

The app shows this profile as two empty bars (0% session, 0% weekly), which says nothing. Devon wants the monthly spend shown instead: a percentage bar in the menu bar, a clear spend card in the dropdown, a pace marker measured against the month, and threshold notifications.

## What the API returns

A read-only request to `https://api.anthropic.com/api/oauth/usage` with the Tribe Claude Code token on 2026-11-02 returned (abridged):

```json
{
  "five_hour": null,
  "seven_day": null,
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [],
  "extra_usage": {
    "is_enabled": true,
    "monthly_limit": 150000,
    "used_credits": 2985.0,
    "utilization": 1.99,
    "currency": "USD",
    "decimal_places": 2,
    "spend_limit_reached": false
  },
  "spend": {
    "used":  { "amount_minor": 2985,   "currency": "USD", "exponent": 2 },
    "limit": { "amount_minor": 150000, "currency": "USD", "exponent": 2 },
    "percent": 2,
    "severity": "normal",
    "enabled": true
  }
}
```

Amounts are minor units (cents for USD, `decimal_places` / `exponent` gives the scale). The response has no reset time for the spend limit. The reset Devon sees (Nov 30, 5 PM MST) is midnight UTC on December 1, so the spend period is the calendar month in UTC.

## Current state of the code

- Both Anthropic auth paths parse the usage response with `ClaudeAPIService.parseUsageResponse` (the claude.ai cookie path calls `/organizations/{org}/usage`, the CLI OAuth path calls `/api/oauth/usage`). `AutoStartSessionService` has its own cookie-only fetch and its own `parseUsageResponse` (~L230 to L330). That parser reads `five_hour`, `seven_day`, and the per-model blocks. It ignores `extra_usage` and `spend`. When `five_hour` is missing it synthesizes a reset time of now + 5 hours.
- The claude.ai cookie path additionally calls `/organizations/{org}/overage_spend_limit` and `/overage_credit_grant` and stores the result in `ClaudeUsage.costUsed`, `costLimit`, `costCurrency`, `overageBalance`. The popover shows it as an "Extra Usage" row (`PopoverContentView.swift` ~L723). For the Tribe profile this produces nothing: its stored usage has `costUsed` and `costLimit` nil.
- The Tribe profile has all three logins linked: claude.ai session key, Claude Code (`~/.claude-tribe`, pinned keychain entry), and the API Console. The claude.ai cookie comes first in the auth order, so the cookie path is what runs.
- Threshold notifications (`NotificationManager.checkAndNotify(usage:profileName:settings:)`) look only at `effectiveSessionPercentage`.
- Auto-switch (`MenuBarManager.checkAutoSwitchIfNeeded`, `findNextAvailableProfile`, ~L1388) also looks only at `effectiveSessionPercentage`, so a spend profile always reads as 0% and is always a valid switch target.
- Multi-profile display (`StatusBarUIManager.updateMultiProfileButtons`, ~L352) draws session and week from the shared `MultiProfileDisplayConfig`, not from each profile's metric list.
- Pace: `PaceStatus.calculate(usedPercentage:elapsedFraction:)` and `UsageStatusCalculator.calculateStatus(..., elapsedFraction:)` already take an elapsed fraction, so they work for any period.

## Goals

1. A profile whose account has a monthly spend cap and no 5-hour or weekly window switches to spend display automatically. No per-profile setting.
2. Menu bar: that profile shows one bar for monthly spend in place of its session and weekly bars, in the same style as the other bars, with "$" in its label, filled to the percentage spent, with the pace tick at the fraction of the month elapsed and pace coloring from the existing rules. (Devon picked this over percentage text or dollar text.)
3. Dropdown: one compact "Monthly spend" card replaces the Session and Weekly cards: the percentage, a bar with the pace tick, "$29.85 of $1,500.00", and "Resets Nov 30, 5:00 PM" in local time. (Devon picked this over a card with projection, amount left, and per-day budget.)
4. Threshold notifications use the spend percentage for these profiles, with the profile's existing 75/90/95/custom thresholds and sound, and wording that names monthly spend.
5. Works with either login: the claude.ai cookie path and the Claude Code OAuth path both produce the spend data.

## Non-goals

- The Claude Code statusline. Devon does not use it.
- The API Console data. On this profile it reports the Tribe organization's API-key spend (about $1,075.67 so far in November across eight keys), which is unrelated to the seat cap. Keep it as it is and do not mix it into the spend bar.
- A spend history chart, purchasing credits, or org-wide team spend (#325).
- Changing accounts that have normal windows and extra usage turned on (for example a Max plan). They keep their bars and the existing "Extra Usage" row.

## Anti-goals

- A spend profile must never show a 0% session or weekly bar, a session reset time, or a "session reset" notification. Those are the misleading parts today.
- Auto-switch must never move work onto a spend-limited profile.
- Auto-start must never try to start a session on a profile with no 5-hour window. Today the zero percentage and missing window would make it try on every check.
- No false resets in usage history (the #337 problem). A spend profile's constant zeros must not be read as resets.

## Design decisions

1. **Detection.** The parser records, for every response, whether a `five_hour` block and a `seven_day` block were present (decision 3). A profile is spend-limited when the parsed usage response has no `five_hour` block (null or absent), no `seven_day` block, and `extra_usage.is_enabled == true` with `monthly_limit > 0`. This is decided per response, so a plan change takes effect on the next refresh.
2. **Parsing.** `parseUsageResponse` reads `extra_usage` (used, limit, currency, decimal places, `spend_limit_reached`) for every response, and records whether the 5-hour and weekly blocks were present. Prefer `extra_usage` over `spend`; fall back to `spend` if `extra_usage` is missing. Scale minor units by `decimal_places`.
3. **No-window state.** `ClaudeUsage` gets an explicit way to say "this account has no session window" and "no weekly window" instead of zeros with synthesized reset times. New stored fields must decode from old data (decoding is already tolerant; keep it that way). These flags apply to every account, not only spend-limited ones: an account with a weekly window but no 5-hour window (Ultra, upstream #356) hides its session bar, session card, session notifications, and session history, and keeps its weekly display. (Claude's call: this is the "has session limit" concept the triage plan already wants for #356 and Codex Pro.)
   An account with neither window and no usable spend cap (`extra_usage` missing, disabled, or limit 0) shows no bars: the menu bar shows the plain app icon for that profile and the dropdown shows one line, "No usage limits reported". (Claude's call.)
4. **Spend period.** If the confirmation step finds a reset timestamp for the spend limit in any response, use it. Otherwise start is the first instant of the current UTC calendar month, end is the first instant of the next. Elapsed fraction = (now - start) / (end - start). Reset time shown to the user = end, formatted in local time.
5. **Pace.** Reuse `PaceStatus.calculate` and `UsageStatusCalculator.calculateStatus` with the month's elapsed fraction.
6. **Menu bar.** For a spend-limited profile the renderer draws one spend metric regardless of which metrics the profile has enabled. In single-profile mode it uses the icon style of the profile's first enabled metric; in multi-profile mode it uses the style from `MultiProfileDisplayConfig` and takes the place of that profile's session and week pair. Label "$" (with the profile name when names are shown, as other metrics do). The "show remaining" setting applies the same way it does to other bars: on, the bar shows the share of the budget left. (Claude's call.)
7. **Dropdown.** The spend card replaces the Session and Weekly cards and the per-model weekly bars, and the "Extra Usage" row is hidden for that profile so the same numbers do not appear twice.
8. **Notifications.** For spend-limited profiles, `checkAndNotify` compares spend percentage to the thresholds. New alert wording ("Monthly spend at 90%", and a limit-reached alert when `spend_limit_reached` is true). Sent-notification dedupe clears when the spend period rolls over. New strings go into all 14 `Localizable.strings` files (`scripts/validate_localizations.sh`).
9. **Auto-start.** `AutoStartSessionService` skips a profile whose usage response has no `five_hour` block. This is the same check #356 needs for Ultra. Its private parser has to get this check too, or be replaced by the shared parser (builder's choice).
10. **History.** Spend-limited profiles do not record session or weekly history snapshots, so reset detection never sees them.
11. **Auto-switch.** Spend-limited profiles are never an auto-switch target (Devon's decision: auto-switch must not move work onto a company-paid seat). An active spend-limited profile also never triggers auto-switch, including when `spend_limit_reached` is true; the limit-reached notification covers that case. (Not switching away is Claude's call: switching off the work seat would move work onto a personal account.)

## First step: confirm the claude.ai response

Only the OAuth response has been seen. Before building on decision 2, fetch `/organizations/{org}/usage` with the Tribe claude.ai session key and check that it carries `extra_usage` with the same shape. If it does not, the cookie path gets spend another way: either from the profile's Claude Code token via the OAuth endpoint (read-only, under the rules in `2026-11-01-claude-code-accounts.md`), or from whichever claude.ai endpoint Settings > Usage uses. Record which in this doc.

## Related doc

`2026-11-01-claude-code-accounts.md` lists "using the CLI token for ... extra-usage spend" as out of scope. If the confirmation step picks the CLI token as the spend source, update that doc.

## Left to the builder

- Field names and types on `ClaudeUsage`, and whether the existing `costUsed` / `costLimit` fields are reused for spend-limited profiles or new ones are added.
- Where the detection logic lives (a computed property on `ClaudeUsage` is the obvious place) and how the provider capability flags express it, following `docs/ADDING_A_PROVIDER.md`. No `provider == .anthropic` checks in UI code.
- Currency formatting (use `NumberFormatter` with the response currency).
- Tests: parser tests from the JSON above, month-fraction tests (start, middle, last day, UTC versus local around midnight), notification threshold and rollover tests, and an auto-start skip test.
