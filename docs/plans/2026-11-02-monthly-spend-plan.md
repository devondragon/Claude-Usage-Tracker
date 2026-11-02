# Monthly Spend Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a monthly spend bar, spend card, and spend notifications for profiles whose account has a monthly spend cap and no 5-hour or weekly window, and stop showing session UI for any account without a 5-hour window.

**Architecture:** The shared usage parser records whether the 5-hour and weekly blocks exist and reads the `extra_usage` spend block into the existing `costUsed`/`costLimit` fields (cents). `ClaudeUsage` gets computed `isSpendLimited` / `reportsNoLimits`. Pure helpers (`SpendPeriod`, `MenuBarSlotLayout`, `MultiProfileBarValues`, `NotificationManager.thresholdAlert`) carry the decisions so they can be unit tested; the renderer, status bar manager, popover, notifications, auto-switch, auto-start, and history code consume them.

**Tech Stack:** Swift 5 mode, SwiftUI/AppKit, XCTest. App target default actor isolation is MainActor; test classes that touch app types are marked `@MainActor`.

**Spec:** `docs/plans/2026-11-02-monthly-spend-design.md`

## Global Constraints

- Work on branch `feat/monthly-spend`. Conventional Commits (`feat(menubar): ...`). No `Co-Authored-By` or any attribution lines in commits or the PR.
- US English in code, comments, strings, and docs. No em dashes or en dashes in user-facing strings or docs.
- Detection is data-driven. No `provider == .anthropic` checks in UI code; Codex keeps working because its provider fills the windows as before (new flags default to `true`).
- `ClaudeUsage` decoding stays tolerant: every new stored field decodes with a default when absent.
- Never rename `Provider` or `MenuBarMetricType` raw values. Do not add a `MenuBarMetricType` case.
- Every new localization key goes into all 14 `Claude Usage/Resources/*.lproj/Localizable.strings` files with a real translation; `scripts/validate_localizations.sh` must pass.
- Amounts are stored in cents in `costUsed` / `costLimit` (the unit the existing "Extra Usage" row already assumes).
- Spend period: UTC calendar month. Reset shown in local time.
- Spend-limited profiles are never auto-switch targets and never trigger auto-switch.
- Test command (all): `xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" -configuration Debug -derivedDataPath build -destination "platform=macOS" CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`. One class: append `-only-testing:"Claude UsageTests/<Class>"`. The hosted test run launches the real app; quit any leftover Debug copy afterward.

## Review Focus

- Profiles stored before this change (no new keys in `profiles_v3`) must decode with both window flags `true` and look exactly as before. Test in Task 2.
- The UTC month boundary: at 6 PM MST on Nov 30 (01:00 UTC Dec 1) the period is December and the elapsed fraction is near 0, not near 1. Test in Task 2.
- Spend above the cap (`used > limit`) or `spend_limit_reached: true`: percentage is not clamped in the model, the bar renders full, and exactly one limit-reached notification is produced. Test in Task 7.
- A cached usage snapshot with `hasSessionWindow == false` survives an encode/decode round trip (non-active profiles show cached usage after failed refreshes). Test in Task 2.
- A Max-style response with both windows and `extra_usage.is_enabled == true` must not be treated as spend-limited. Test in Task 3.

---

### Task 1: Confirm the claude.ai usage response for the Tribe profile

The Tribe profile's claude.ai session key is in the login keychain under the signed app's item, so reading it shows a keychain prompt. Ask Devon before running this; he clicks Allow.

**Files:**
- Modify: `docs/plans/2026-11-02-monthly-spend-design.md` (section "First step: confirm the claude.ai response")

- [ ] **Step 1: Fetch `/api/organizations/65093de3-e613-4ce5-a47e-08477977dc29/usage` from `https://claude.ai` with the Tribe session key as the `sessionKey` cookie and the browser headers the app uses (User-Agent, Referer and Origin `https://claude.ai`).** Find the key's keychain service name with `/usr/bin/grep -n "service" "Claude Usage/Shared/Services/KeychainService.swift"`. Never print the key; save the response to the session scratchpad.
- [ ] **Step 2: Record in the design doc** whether `five_hour` and `seven_day` are null, whether `extra_usage` is present with the same fields as the OAuth response, and whether any field carries a reset time for the spend limit.
- [ ] **Step 3: Decide.** If `extra_usage` is present: Task 9 is skipped. If it is absent: Task 9 runs. If a spend reset timestamp exists: stop and update Task 2 to store and prefer it before continuing.
- [ ] **Step 4: Commit** the design doc update (`docs(plan): record claude.ai usage response for spend`).

### Task 2: Model fields, spend period, and spend formatting

**Files:**
- Modify: `Claude Usage/Shared/Models/ClaudeUsage.swift`
- Create: `Claude Usage/Shared/Utilities/SpendPeriod.swift`
- Test: `Claude UsageTests/SpendModelTests.swift`

**Interfaces:**
- Produces on `ClaudeUsage` (stored, declared after `userTimezone` with defaults so the memberwise init keeps working at every existing call site): `var hasSessionWindow: Bool = true`, `var hasWeeklyWindow: Bool = true`, `var spendLimitReached: Bool = false`. Coding keys of the same names, decoded with `decodeIfPresent ?? true / true / false`.
- Produces computed: `var isSpendLimited: Bool` (no session window, no weekly window, `costUsed != nil`, `costLimit > 0`), `var reportsNoLimits: Bool` (no session window, no weekly window, not spend-limited), `var spendPercentage: Double` (`costUsed / costLimit * 100`, 0 when either is missing; not clamped).
- Produces `struct SpendPeriod: Equatable { let start: Date; let end: Date; var duration: TimeInterval; static func containing(_ date: Date) -> SpendPeriod; func elapsedFraction(at date: Date) -> Double }`. UTC Gregorian calendar month; `elapsedFraction` clamped to 0...1.
- Produces `enum SpendFormatting { static func string(cents: Double, currency: String, locale: Locale = .current) -> String }` (in `SpendPeriod.swift`), `NumberFormatter` with `.currency`, `currencyCode = currency`, value `cents / 100`.

- [ ] **Step 1: Write failing tests** in `SpendModelTests` (`@MainActor final class`):
  - `testLegacyDataDecodesWithWindows`: decode `{"sessionPercentage": 12, "weeklyPercentage": 30}`; assert `hasSessionWindow == true`, `hasWeeklyWindow == true`, `spendLimitReached == false`, `isSpendLimited == false`.
  - `testNoWindowFlagsSurviveRoundTrip`: usage with both flags `false`, `costUsed: 2985`, `costLimit: 150000`, `costCurrency: "USD"`; encode with `JSONEncoder`, decode; assert flags `false` and `isSpendLimited == true`.
  - `testSpendPercentage`: 2985 / 150000 gives `1.99` (accuracy 0.001); `costUsed: 160000` gives `106.666...` (not clamped).
  - `testReportsNoLimits`: both flags false, `costLimit: nil` gives `reportsNoLimits == true`, `isSpendLimited == false`; `costLimit: 0` same.
  - `testWeeklyOnlyAccountIsNotSpendLimited`: `hasSessionWindow: false`, `hasWeeklyWindow: true`, cost fields set; `isSpendLimited == false`, `reportsNoLimits == false`.
  - `testPeriodIsUTCMonth`: for `2026-11-02T17:27:00Z`, `start == 2026-11-01T00:00:00Z`, `end == 2026-12-01T00:00:00Z`; `elapsedFraction` ≈ `0.0580` (accuracy 0.001).
  - `testPeriodRollsOverAtUTCMidnight`: for `2026-12-01T01:00:00Z` (6 PM MST Nov 30), `start == 2026-12-01T00:00:00Z`, `elapsedFraction < 0.002`.
  - `testPeriodHandlesFebruaryAndDecember`: `2027-02-15T00:00:00Z` gives end `2027-03-01T00:00:00Z`; `2026-12-31T23:59:00Z` gives end `2027-01-01T00:00:00Z`.
  - `testSpendFormatting`: `string(cents: 2985, currency: "USD", locale: Locale(identifier: "en_US")) == "$29.85"`, and `150000` gives `"$1,500.00"`.
- [ ] **Step 2: Run** `-only-testing:"Claude UsageTests/SpendModelTests"`. Expected: build failure (types missing).
- [ ] **Step 3: Implement** the fields, decoding, computed properties, `SpendPeriod`, and `SpendFormatting` as specified above.
- [ ] **Step 4: Run** the class. Expected: all pass. Then run the full suite. Expected: no regressions.
- [ ] **Step 5: Commit** `feat(usage): model no-window accounts and monthly spend period`.

### Task 3: Parse windows and spend in both usage parsers; skip auto-start without a session window

**Files:**
- Modify: `Claude Usage/Shared/Services/ClaudeAPIService.swift` (`parseUsageResponse`, ~L803)
- Modify: `Claude Usage/Shared/Services/AutoStartSessionService.swift` (`parseUsageResponse`, `parseUtilization`, `checkProfile`)
- Test: `Claude UsageTests/SpendParsingTests.swift`

**Interfaces:**
- Consumes: Task 2 fields.
- Produces: `ClaudeAPIService.parseUsageResponse(_ data: Data) throws -> ClaudeUsage` becomes internal (was `private`). It sets `hasSessionWindow = json["five_hour"] is [String: Any]`, `hasWeeklyWindow = json["seven_day"] is [String: Any]`, and spend fields from `static func parseSpend(from json: [String: Any]) -> ParsedSpend?`.
- Produces `struct ParsedSpend: Equatable { let usedCents: Double; let limitCents: Double; let currency: String; let limitReached: Bool }` nested in `ClaudeAPIService` (in `ClaudeAPIService+Types.swift`). Source order: `extra_usage` (`is_enabled == true`, `monthly_limit`, `used_credits`, `currency`, `decimal_places`, `spend_limit_reached`), else `spend` (`enabled == true`, `used.amount_minor`, `limit.amount_minor`, `used.currency`, `used.exponent`). Convert minor units to cents: `value * pow(10, 2 - decimalPlaces)`. Returns nil when disabled, missing, or limit is 0.
- Produces: `AutoStartSessionService.parseUsageResponse(_ data: Data) throws -> (usage: ClaudeUsage, hasOpenWindow: Bool)` becomes `static` and internal, with `usage.hasSessionWindow` set the same way; `parseUtilization` becomes `static`.
- When `parseSpend` returns a value, the parser sets `costUsed`, `costLimit`, `costCurrency`, `spendLimitReached`. The claude.ai path's later `overage_spend_limit` assignment still overwrites them only when that endpoint reports enabled (unchanged).

- [ ] **Step 1: Write failing tests** in `SpendParsingTests` (`@MainActor`), with JSON fixtures as string literals:
  - `testEnterpriseResponse`: the Tribe JSON from the design doc. Assert `hasSessionWindow == false`, `hasWeeklyWindow == false`, `costUsed == 2985`, `costLimit == 150000`, `costCurrency == "USD"`, `isSpendLimited == true`, `spendLimitReached == false`.
  - `testSpendBlockFallback`: same JSON without `extra_usage`; same cost assertions from `spend`.
  - `testDecimalPlacesScale`: `extra_usage` with `decimal_places: 3`, `used_credits: 29850`, `monthly_limit: 1500000`; `costUsed == 2985`, `costLimit == 150000`.
  - `testLimitReachedFlag`: `spend_limit_reached: true` gives `spendLimitReached == true`.
  - `testMaxPlanWithExtraUsageKeepsWindows`: `five_hour` and `seven_day` objects with utilization and `resets_at`, plus enabled `extra_usage`; assert both flags `true`, `isSpendLimited == false`, cost fields set.
  - `testUltraResponseHasNoSessionWindow`: `five_hour: null`, `seven_day` present; `hasSessionWindow == false`, `hasWeeklyWindow == true`.
  - `testDisabledExtraUsageIsIgnored`: both windows null, `extra_usage.is_enabled: false`; `reportsNoLimits == true`.
  - `testAutoStartParserFlagsMissingSessionWindow`: `AutoStartSessionService.parseUsageResponse` on the Tribe JSON gives `usage.hasSessionWindow == false` and `hasOpenWindow == false`.
- [ ] **Step 2: Run** the class. Expected: build failure.
- [ ] **Step 3: Implement** the parser changes and `parseSpend` as specified. In `AutoStartSessionService.checkProfile`, right after fetching usage: if `!usage.hasSessionWindow`, log at debug level (`"Skipping profile '<name>' - account has no 5-hour session window"`), clear `attemptStore` for the profile, and return before any auto-start logic.
- [ ] **Step 4: Run** the class, then the full suite. Expected: all pass.
- [ ] **Step 5: Commit** `feat(usage): parse spend limits and missing usage windows`.

### Task 4: Single-profile menu bar layout and spend rendering

**Files:**
- Create: `Claude Usage/MenuBar/MenuBarSlotLayout.swift`
- Modify: `Claude Usage/MenuBar/StatusBarUIManager.swift` (`updateAllButtons`, `updateButton`)
- Modify: `Claude Usage/MenuBar/MenuBarIconRenderer.swift`
- Test: `Claude UsageTests/MenuBarSlotLayoutTests.swift`

**Interfaces:**
- Consumes: Task 2 (`isSpendLimited`, `reportsNoLimits`, `spendPercentage`, `SpendPeriod`).
- Produces `enum MenuBarSlotContent: Equatable { case metric, spend, hidden, appLogo }` and `enum MenuBarSlotLayout { static func contents(enabled: [MenuBarMetricType], usage: ClaudeUsage) -> [MenuBarMetricType: MenuBarSlotContent] }`. Rules, applied to `enabled` in order:
  - spend-limited: the first enabled non-`.api` metric gets `.spend`, other `.session`/`.week` get `.hidden`, `.api` gets `.metric`.
  - otherwise `.session` is `.hidden` when `!hasSessionWindow`, `.week` is `.hidden` when `!hasWeeklyWindow`, everything else `.metric`.
  - if no entry is `.metric` or `.spend`, the first enabled metric gets `.appLogo`.
- Produces on `MenuBarIconRenderer`: `func createSpendImage(config: MetricIconConfig, globalConfig: MenuBarIconConfiguration, usage: ClaudeUsage, isDarkMode: Bool, colorMode: MenuBarColorMode, singleColorHex: String, showIconName: Bool, now: Date = Date()) -> NSImage`. It renders with `config.iconStyle` like a session bar, using `usage.spendPercentage` (display-adjusted for "show remaining"), the time marker and pace from `SpendPeriod.containing(now).elapsedFraction(at: now)`, pace coloring through `UsageStatusCalculator.calculateStatus`, and labels `"$"` where the session bar draws `"S"`, `"Spend"` where it draws `"Session"`, and `"$:"` for the prefix. The style functions pick labels from `metricType` today; give them a label override parameter rather than duplicating them.

- [ ] **Step 1: Write failing tests** in `MenuBarSlotLayoutTests`:
  - `testNormalAccountShowsEnabledMetrics`: enabled `[.session, .week]`, default usage gives both `.metric`.
  - `testSpendLimitedUsesFirstSlot`: enabled `[.session, .week, .api]`, spend-limited usage gives `.session: .spend, .week: .hidden, .api: .metric`.
  - `testSpendLimitedWithWeekFirst`: enabled `[.week]` gives `.week: .spend`.
  - `testUltraHidesSessionKeepsWeek`: `hasSessionWindow: false`, enabled `[.session, .week]` gives `.session: .hidden, .week: .metric`.
  - `testNoLimitsShowsAppLogo`: `reportsNoLimits` usage, enabled `[.session]` gives `.session: .appLogo`.
  - `testUltraWithOnlySessionEnabledShowsAppLogo`: `hasSessionWindow: false`, enabled `[.session]` gives `.session: .appLogo`.
- [ ] **Step 2: Run** the class. Expected: build failure.
- [ ] **Step 3: Implement** `MenuBarSlotLayout` and `createSpendImage`. In `updateAllButtons`, compute `MenuBarSlotLayout.contents` from `config.enabledMetrics.map(\.metricType)` and the usage; `.metric` keeps today's `createImage` call, `.spend` calls `createSpendImage`, `.appLogo` uses `createDefaultAppLogo` (as the no-credentials branch does), `.hidden` sets an empty 1x1 transparent image and `statusItem.length = 0`, restoring `NSStatusItem.variableLength` when the slot becomes visible again. Route `updateButton` through the same layout.
- [ ] **Step 4: Run** the class and the full suite. Expected: pass.
- [ ] **Step 5: Manual check.** Run `scripts/install-local.sh` from the branch with the Tribe profile active in single-profile mode. Expected: one bar labeled "$" near 2% with the pace tick near 6%; Personal unchanged. Quit and reinstall from `main` afterward if the branch is not merged.
- [ ] **Step 6: Commit** `feat(menubar): show monthly spend bar for spend-limited profiles`.

### Task 5: Multi-profile menu bar

**Files:**
- Create: `Claude Usage/MenuBar/MultiProfileBarValues.swift`
- Modify: `Claude Usage/MenuBar/StatusBarUIManager.swift` (`updateMultiProfileButtons`, ~L352)
- Test: `Claude UsageTests/MultiProfileBarValuesTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces `struct MultiProfileBarValues: Equatable { let primaryUsed: Double; let primaryElapsed: Double?; let secondaryUsed: Double?; let secondaryElapsed: Double?; let isSpend: Bool; let showsAppLogo: Bool }` with `static func make(for usage: ClaudeUsage, showWeek: Bool, now: Date) -> MultiProfileBarValues`. Rules: spend-limited gives primary = `spendPercentage`, elapsed = month fraction, no secondary, `isSpend`. No session window but weekly gives primary = weekly, no secondary. `reportsNoLimits` gives `showsAppLogo`. Otherwise session primary and week secondary (when `showWeek`), elapsed fractions from `UsageStatusCalculator.elapsedFraction` as today.

- [ ] **Step 1: Write failing tests**: `testNormalProfile` (session 42 / week 31 with `showWeek` gives both), `testSpendProfile` (2985/150000 at `2026-11-02T17:27:00Z` gives primary 1.99, elapsed ≈ 0.058, secondary nil, `isSpend`), `testWeeklyOnlyProfile` (primary = weekly, secondary nil), `testNoLimitsProfile` (`showsAppLogo`).
- [ ] **Step 2: Run** the class. Expected: build failure.
- [ ] **Step 3: Implement** `make(for:showWeek:now:)` and switch `updateMultiProfileButtons` to it. The second bar is passed as absent (`nil` or 0, as each style already does when `showWeek` is off). Name labels get a `" $"` suffix when `isSpend` (`"Tribe $"`); styles that draw only an initial keep the initial. `showsAppLogo` draws the default app logo for that profile.
- [ ] **Step 4: Run** the class and the full suite. Expected: pass.
- [ ] **Step 5: Manual check** in multi-profile mode: Tribe shows one bar labeled "Tribe $"; Personal shows its two bars.
- [ ] **Step 6: Commit** `feat(menubar): spend bar in multi-profile display`.

### Task 6: Dropdown spend card

**Files:**
- Modify: `Claude Usage/MenuBar/PopoverContentView.swift` (usage rows, ~L640 to L740)
- Modify: all 14 `Claude Usage/Resources/*.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Task 2 (`isSpendLimited`, `reportsNoLimits`, `spendPercentage`, `SpendPeriod`, `SpendFormatting`).
- New keys (English values): `"menubar.monthly_spend" = "Monthly spend";`, `"menubar.spend_of_limit" = "%@ of %@";`, `"menubar.no_limits_reported" = "No usage limits reported";`.

- [ ] **Step 1: Implement.** When `usage.isSpendLimited`: show one `UsageRow` with title `menubar.monthly_spend`, subtitle `menubar.spend_of_limit` filled with `SpendFormatting.string(cents:currency:)` for used and limit, `usedPercentage: usage.spendPercentage`, `resetTime: period.end`, `periodDuration: period.duration` (period = `SpendPeriod.containing(Date())`), and the same marker and coloring settings the session row gets. Hide the session, weekly, per-model, and "Extra Usage" rows. When `usage.reportsNoLimits`: one secondary-styled line `menubar.no_limits_reported`. Otherwise today's rows, with the session row only when `hasSessionWindow` and the weekly row only when `hasWeeklyWindow`.
- [ ] **Step 2: Add the three keys** to every lproj with translations. Run `scripts/validate_localizations.sh`. Expected: passes.
- [ ] **Step 3: Build and run the full suite.** Expected: pass.
- [ ] **Step 4: Manual check** with the Tribe profile: card reads "Monthly spend", "2%", "$29.85 of $1,500.00", reset "Nov 30, 5:00 PM" (local), pace tick near 6%. Personal's dropdown unchanged.
- [ ] **Step 5: Commit** `feat(popover): monthly spend card`.

### Task 7: Spend threshold notifications

**Files:**
- Modify: `Claude Usage/Shared/Services/NotificationManager.swift` (`checkAndNotify(usage:profileName:settings:)`, `AlertType`)
- Modify: all 14 `Localizable.strings`
- Test: `Claude UsageTests/SpendNotificationTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces `AlertType` cases `spendInfo = "spend_info"`, `spendWarning = "spend_warning"`, `spendCritical = "spend_critical"`, `spendLimitReached = "spend_limit_reached"`.
- Produces `struct ThresholdAlert: Equatable { let type: NotificationManager.AlertType; let threshold: Int; let percentage: Double; let resetTime: Date? }` and `static func thresholdAlert(for usage: ClaudeUsage, settings: NotificationSettings, now: Date) -> ThresholdAlert?`. Rules: spend-limited and `spendLimitReached` gives `.spendLimitReached` with threshold 100; spend-limited otherwise gives the highest threshold from `settings.sortedThresholds` at or below `spendPercentage`, mapped 95+ critical, 90 to 94 warning, else info, `resetTime` = period end; no session window and not spend-limited gives nil; otherwise today's session mapping.
- New keys (English): `notification.spend_info.title` "Monthly spend", `notification.spend_warning.title` "Monthly spend high", `notification.spend_critical.title` "Monthly spend almost used", `notification.spend_limit_reached.title` "Monthly spend limit reached"; messages `notification.spend_info.message`, `.spend_warning.message`, `.spend_critical.message` = "You've used %@ of your monthly spend limit. %@", `notification.spend_limit_reached.message` = "You've reached your monthly spend limit. %@".

- [ ] **Step 1: Write failing tests**: `testSpendBelowThresholdsGivesNil` (2%), `testSpendAt91GivesWarning` (threshold 90, `.spendWarning`), `testSpendAt96GivesCritical`, `testLimitReachedWinsOverPercentage` (`spendLimitReached` at 80% gives `.spendLimitReached`, threshold 100), `testOverCapGivesCritical` (106%, not reached flag, gives `.spendCritical` 95), `testWeeklyOnlyAccountGivesNoSessionAlert` (`hasSessionWindow: false`, weekly account, nil), `testNormalSessionUnchanged` (session 92% gives `.sessionWarning` 90).
- [ ] **Step 2: Run** the class. Expected: build failure.
- [ ] **Step 3: Implement** `thresholdAlert` and route `checkAndNotify` through it. Only run the session-reset alert when `usage.hasSessionWindow`. Track `previousSpendPeriodStart: [String: Date]` per profile name; when `SpendPeriod.containing(now).start` differs from the stored value, remove that profile's entries from `sentNotifications` before checking. Add the eight keys to every lproj; run `scripts/validate_localizations.sh`.
- [ ] **Step 4: Run** the class and the full suite. Expected: pass.
- [ ] **Step 5: Commit** `feat(notifications): alert on monthly spend thresholds`.

### Task 8: Auto-switch exclusion and history guards

**Files:**
- Modify: `Claude Usage/MenuBar/MenuBarManager.swift` (`checkAutoSwitchIfNeeded` ~L1388, `findNextAvailableProfile` ~L1462, reset detection `checkAndRecordSessionReset` and the weekly counterpart ~L1490 to L1600)
- Modify: `Claude Usage/Shared/Services/UsageHistoryService.swift` (`recordSessionPeriodic`, `recordWeeklyPeriodic`, `recordSessionReset`, `recordWeeklyReset`)
- Test: `Claude UsageTests/AutoSwitchEligibilityTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces `static func isAutoSwitchCandidate(_ usage: ClaudeUsage?) -> Bool` on `MenuBarManager`: `nil` gives `true` (unchanged behavior); spend-limited gives `false`; otherwise `effectiveSessionPercentage < 100`.

- [ ] **Step 1: Write failing tests**: `testNoCachedUsageIsCandidate`, `testSpendLimitedIsNeverCandidate` (2% spend), `testFullSessionIsNotCandidate` (100%), `testNormalBelowLimitIsCandidate` (40%).
- [ ] **Step 2: Run** the class. Expected: build failure.
- [ ] **Step 3: Implement.** `findNextAvailableProfile` uses `isAutoSwitchCandidate(candidate.claudeUsage)`. `checkAutoSwitchIfNeeded` returns at the top when `usage.isSpendLimited`. History: the session record and reset functions return early when the relevant usage has `hasSessionWindow == false`, the weekly ones when `hasWeeklyWindow == false`; `MenuBarManager`'s reset detection skips the same way, so constant zeros and synthesized reset times never count as resets.
- [ ] **Step 4: Run** the class and the full suite. Expected: pass.
- [ ] **Step 5: Commit** `fix(profiles): never auto-switch to spend-limited profiles; skip history without windows`.

### Task 9 (only if Task 1 found no `extra_usage` in the claude.ai response): spend from the Claude Code login

**Files:**
- Modify: `Claude Usage/Shared/Services/ClaudeAPIService.swift` (claude.ai branch of `fetchUsageData`, ~L515 to L545, and the per-profile fetch used by `AnthropicUsageProvider`)
- Modify: `docs/plans/2026-11-01-claude-code-accounts.md` (remove "extra-usage spend" from Out of scope)

- [ ] **Step 1: Implement.** After a claude.ai-cookie fetch where both windows are absent and no spend was parsed, and the profile has a Claude Code token (pinned entry or stored CLI JSON) that is not expired, call `fetchUsageData(oauthAccessToken:)` and copy `costUsed`, `costLimit`, `costCurrency`, `spendLimitReached` from its result. Never refresh the token (read-only rule from the Claude Code accounts design). On any failure keep the cookie result.
- [ ] **Step 2: Run the full suite.** Expected: pass. Manual check: Tribe shows spend with the claude.ai login first in the auth order.
- [ ] **Step 3: Commit** `feat(usage): read spend through the Claude Code login when claude.ai omits it`.

### Task 10: Final verification and PR

- [ ] **Step 1: Run** the full suite and `scripts/validate_localizations.sh`. Expected: all tests pass (2 Keychain tests skipped as usual), validation passes.
- [ ] **Step 2: Install** with `scripts/install-local.sh` and check, in single-profile and multi-profile mode: Tribe spend bar and card match Tasks 4 to 6; Personal unchanged; no auto-start attempts logged for Tribe.
- [ ] **Step 3: Update** the triage plan Status section (`docs/plans/2026-11-01-upstream-triage.md`): monthly spend added; #356 session-window handling done; Codex Pro still open.
- [ ] **Step 4: Push** `feat/monthly-spend` and open the PR with `gh pr create`, summarizing behavior, tests, and the Task 1 finding. No attribution lines.
