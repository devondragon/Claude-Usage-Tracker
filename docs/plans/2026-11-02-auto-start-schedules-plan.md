# Auto-start schedules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-profile weekday/weekend auto-start schedules that open 5-hour windows by running `claude -p` under the profile's own Claude Code login, replacing the claude.ai chat path.

**Architecture:** Pure policy types (schedule, login resolution, start decision, CLI arguments and result parsing) carry the logic and the tests. `AutoStartSessionService` keeps its timer and wake observer, adds one-shot timers, fetches usage live per profile (cookie or OAuth token), and launches the CLI through a small process runner. The settings card gains four time pickers and a last-result line.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Foundation `Process`. macOS 14+.

**Spec:** `docs/plans/2026-11-02-auto-start-schedules-design.md`

## Global Constraints

- Branch `feat/auto-start-schedules`; Conventional Commits with scope `autostart`; no `Co-Authored-By` or other attribution lines in commits.
- Build and test commands are the ones in `CLAUDE.md` (unsigned Debug, `-derivedDataPath build`). The test target is hosted in the app; quit any leftover Debug copy afterward.
- Tests must never launch the real `claude` binary or make network calls.
- CLI arguments, verbatim: `-p ping --model haiku --tools "" --strict-mcp-config --setting-sources "" --no-session-persistence --system-prompt "Reply with the single word ok." --output-format json` (the empty strings are real empty arguments in the `Process` argument array).
- CLI timeout 60 s. Working directory: an empty directory `~/Library/Caches/com.devondragon.ClaudeUsage/autostart-cwd` (create if missing).
- Default login: `CLAUDE_CONFIG_DIR` removed from the child environment. Linked login: `CLAUDE_CONFIG_DIR` set to the dir path.
- Default schedule: weekdays 7:00 to 20:00 (420 to 1200), weekends 9:00 to 22:00 (540 to 1320).
- Weekly skip threshold: `weeklyPercentage >= 100`.
- Keep `AutoStartAttemptPolicy` and `AutoStartAttemptStore` unchanged.
- Every new user-facing string goes into all 14 `Resources/*.lproj/Localizable.strings`; `scripts/validate_localizations.sh` must pass.
- US English, no em or en dashes in strings or comments.

## Review Focus

1. Overlapping checks (timer, one-shot timer, and wake firing within seconds): a profile must not be pinged twice. Covered in Task 5 by a per-profile in-flight set and a test.
2. Wake after the stop time, or across midnight into a weekend day: no start outside today's schedule. Covered in Task 2 tests (`testAfterStopIsOutOfSchedule`, `testSaturdayUsesWeekendWindow`).
3. DST change days: 7:00 local still means 7:00. Covered in Task 2 (`testSpringForwardDay`).
4. The `claude` binary moves (Claude Code self-update, Homebrew upgrade): the cached path is cleared when launch fails with "file not found" and located again next check. Covered in Task 4 (`testLocatorRetriesAfterInvalidate`).
5. Usage endpoint 429 or network error: skip without counting an attempt and without pinging. Covered in Task 3 (`testFetchErrorSkipsWithoutAttempt`).

---

### Task 1: Verify the CLI ping opens a window (manual gate)

No code. Stop and report to Devon if either check fails.

- [ ] **Step 1:** In the app (or with `curl` against `https://api.anthropic.com/api/oauth/usage` using the access token from `security find-generic-password -s "Claude Code-credentials-03be7f69" -w`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`), confirm the Lumena account has no open window: `five_hour.resets_at` is null or absent. Ask Devon before using a different account. Never print the token.
- [ ] **Step 2:** Run the ping from the Global Constraints with `CLAUDE_CONFIG_DIR=~/.claude-lumena`, using `command claude` so the shell alias does not apply. Expected: JSON with `"is_error": false`.
- [ ] **Step 3:** Read usage again within a minute. Expected: `five_hour.resets_at` is about 5 hours ahead, in the same ISO 8601 with fractional seconds format the claude.ai endpoint uses. Record the raw `five_hour` and `seven_day` objects (no tokens) in the PR description.

### Task 2: Schedule model and policy

**Files:**
- Create: `Claude Usage/Shared/Services/AutoStartSchedulePolicy.swift`
- Modify: `Claude Usage/Shared/Models/Profile.swift` (property, init parameter, `CodingKeys`, `init(from:)`, `encode(to:)`)
- Test: `Claude UsageTests/AutoStartSchedulePolicyTests.swift`

**Interfaces:**
- Produces:
  - `struct AutoStartSchedule: Codable, Equatable { struct Window: Codable, Equatable { var startMinute: Int; var stopMinute: Int }; var weekdays: Window; var weekends: Window; static let `default` }`
  - `Profile.autoStartSchedule: AutoStartSchedule?` and `Profile.effectiveAutoStartSchedule: AutoStartSchedule` (nil → `.default`)
  - `enum AutoStartSchedulePolicy { static func window(for date: Date, in schedule: AutoStartSchedule, calendar: Calendar) -> AutoStartSchedule.Window; static func isInSchedule(_ schedule: AutoStartSchedule, at date: Date, calendar: Calendar) -> Bool; static func nextStart(after date: Date, schedule: AutoStartSchedule, calendar: Calendar) -> Date }`

- [ ] **Step 1: Write the failing tests** with a Gregorian calendar fixed to `America/Denver`:
  - `testWeekdayInsideWindow`: Monday 2026-11-02 08:00 → `isInSchedule == true`.
  - `testExactlyAtStartIsIn` (Monday 07:00 → true) and `testAfterStopIsOutOfSchedule` (Monday 20:00 → false, 19:59 → true).
  - `testSaturdayUsesWeekendWindow`: Saturday 2026-11-07 08:00 → false, 09:00 → true.
  - `testNextStartLaterToday`: Monday 05:00 → Monday 07:00.
  - `testNextStartAcrossWeekend`: Friday 2026-11-06 21:00 → Saturday 2026-11-07 09:00; Sunday 2026-11-08 23:00 → Monday 2026-11-09 07:00.
  - `testSpringForwardDay`: Sunday 2027-03-14 with weekends 01:00 to 22:00 and 2:30 → `isInSchedule == true`; `nextStart(after: Saturday 23:00)` is 2027-03-14 01:00 local.
  - `testProfileDecodesWithoutSchedule`: encode a `Profile`, strip `autoStartSchedule` from the JSON, decode → `autoStartSchedule == nil`, `effectiveAutoStartSchedule == .default`.
  - `testProfileRoundTripsSchedule`.
- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:"Claude UsageTests/AutoStartSchedulePolicyTests"`. Expected: build fails (types missing).
- [ ] **Step 3: Implement.** Weekend is `calendar.component(.weekday, from:)` in {1, 7}. Compare minutes since `calendar.startOfDay(for:)` using `calendar.dateComponents([.hour, .minute])` (not elapsed seconds, so DST days work). `nextStart` builds the start with `calendar.date(bySettingHour:minute:second:of:)` for today if still ahead, else walks forward day by day (at most 7).
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(autostart): add weekday and weekend schedule model`.

### Task 3: Start decision

**Files:**
- Create: `Claude Usage/Shared/Services/AutoStartDecision.swift`
- Test: `Claude UsageTests/AutoStartDecisionTests.swift`

**Interfaces:**
- Consumes: `AutoStartAttemptPolicy.Decision`, `ClaudeUsage.hasNoUsageWindows`, `ClaudeUsage.weeklyPercentage`.
- Produces:
  - `enum AutoStartUsageReading { case live(ClaudeUsage, hasOpenWindow: Bool); case tokenExpired; case failed(String) }`
  - `enum AutoStartSkipReason: Equatable { case outOfSchedule, noUsageWindows, windowOpen(until: Date?), weeklyLimitReached, backingOff(until: Date), usageFetchFailed(String), noClaudeCodeLogin, accountMismatch, binaryNotFound }`
  - `enum AutoStartAction: Equatable { case ping; case skip(AutoStartSkipReason) }`
  - `enum AutoStartDecision { static func decide(inSchedule: Bool, reading: AutoStartUsageReading, attempt: AutoStartAttemptPolicy.Decision) -> AutoStartAction }`

Order, from the spec: out of schedule → `.outOfSchedule`; `.failed` → `.usageFetchFailed`; `.live` with `hasNoUsageWindows` → `.noUsageWindows`; open window → `.windowOpen(until: usage.sessionResetTime)`; weekly ≥ 100 → `.weeklyLimitReached`; attempt `.wait` → `.backingOff`; otherwise `.ping`. `.tokenExpired` skips the usage checks and goes straight to the attempt check.

- [ ] **Step 1: Write failing tests**, one per branch above, including `testFetchErrorSkipsWithoutAttempt` (`.failed` with attempt `.attempt` → `.skip(.usageFetchFailed)`), `testTokenExpiredPingsWhenAttemptAllowed`, `testTokenExpiredRespectsBackoff`, `testWeeklyAt99Pings`, `testWeeklyAt100Skips`.
- [ ] **Step 2: Run**, expect build failure. **Step 3: Implement.** **Step 4: Run**, expect PASS.
- [ ] **Step 5: Commit** `feat(autostart): add start decision policy`.

### Task 4: Login resolution, CLI command, and runner

**Files:**
- Create: `Claude Usage/Shared/Services/ClaudeCLIPing.swift` (login resolution, arguments, environment, result parsing, binary locator, runner)
- Modify: `Claude Usage/Shared/Services/ClaudeCodeSyncService.swift`: extract `func configDirPath(forKeychainService serviceName: String, homePath: String = ...) -> String?` from `readOAuthAccount(forKeychainService:homePath:)` (which then calls it); make `legacyServiceName` internal (`static let`, not private).
- Test: `Claude UsageTests/ClaudeCLIPingTests.swift`

**Interfaces:**
- Produces:
  - `enum AutoStartLogin: Equatable { case defaultLogin; case configDir(path: String, keychainService: String) }`
  - `enum ClaudeCLIPing`:
    - `static func resolveLogin(customKeychainService: String?, profileAccountJSON: String?, defaultAccountJSON: String?, hasCliCredentials: Bool, configDirPath: (String) -> String?) -> Result<AutoStartLogin, AutoStartSkipReason>`. A non-legacy `customKeychainService` → `.configDir` (or `.noClaudeCodeLogin` if `configDirPath` returns nil). Otherwise requires `hasCliCredentials` and matching `accountUuid` (fallback `emailAddress`) between the two `oauthAccount` JSON strings → `.defaultLogin`, else `.accountMismatch`; no CLI credentials → `.noClaudeCodeLogin`.
    - `static let arguments: [String]` (verbatim from Global Constraints)
    - `static func environment(for login: AutoStartLogin, base: [String: String]) -> [String: String]`
    - `static func parseResult(exitCode: Int32, stdout: Data, timedOut: Bool) -> Result<Void, String>`: success only for exit 0 and JSON `is_error == false`; failure message includes the exit code, `timed out`, or the JSON `result` text truncated to 200 characters.
  - `struct ClaudeBinaryLocator { init(candidates: [String], isExecutable: (String) -> Bool, shellLookup: () -> String?); mutating func locate() -> String?; mutating func invalidate() }`, with `static let defaultCandidates` = `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude` (tilde expanded). `shellLookup` in production runs `$SHELL -lc 'command -v claude'` with a 10 s timeout.
  - `protocol ClaudeProcessRunning { func run(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL, timeout: TimeInterval) async -> (exitCode: Int32, stdout: Data, timedOut: Bool) }` and `struct ClaudeProcessRunner: ClaudeProcessRunning` using `Process` with a pipe; on timeout, `terminate()` then report `timedOut: true`. Launch failure returns exit code `-1`.

- [ ] **Step 1: Write failing tests:**
  - `testLinkedProfileUsesConfigDir`, `testLinkedProfileWithUnknownHashIsSkipped`, `testUnlinkedMatchingAccountUsesDefaultLogin` (same `accountUuid`), `testUnlinkedFallsBackToEmail`, `testUnlinkedMismatchIsSkipped`, `testNoCliCredentialsIsSkipped`, `testLegacyServiceNameCountsAsUnlinked`.
  - `testArgumentsMatchSpec`: equals the verbatim array, including two `""` elements.
  - `testDefaultLoginRemovesConfigDirVariable` (base has `CLAUDE_CONFIG_DIR=/x` → absent), `testConfigDirLoginSetsVariable`.
  - `testParseSuccess`, `testParseIsErrorTrue`, `testParseNonZeroExit`, `testParseTimeout`, `testParseGarbageStdout`.
  - `testLocatorPicksFirstExecutableCandidate`, `testLocatorFallsBackToShell`, `testLocatorCachesResult` (shellLookup called once across two `locate()`), `testLocatorRetriesAfterInvalidate`.
  - `testConfigDirPathForHashedService` (temp home with `.claude-test`; service name built with `sha256HexPrefix`).
- [ ] **Step 2: Run**, expect build failure. **Step 3: Implement.** **Step 4: Run** these tests plus `PinnedKeychainOAuthAccountTests` and `ClaudeCodeAccountsTests` (the refactor touches their code). Expected: PASS.
- [ ] **Step 5: Commit** `feat(autostart): run the ping through the Claude Code CLI`.

### Task 5: Rewire AutoStartSessionService

**Files:**
- Modify: `Claude Usage/Shared/Services/AutoStartSessionService.swift`
- Create: `Claude Usage/Shared/Services/AutoStartStatusStore.swift`
- Test: `Claude UsageTests/AutoStartStatusStoreTests.swift`, `Claude UsageTests/AutoStartSessionServiceTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2 to 4; `ClaudeCodeSyncService.shared.readKeychainCredentials(serviceName:)`, `readSystemCredentials()`, `readOAuthAccount()`, `isTokenExpired(_:)`, `extractAccessToken(from:)`.
- Produces:
  - `struct AutoStartResult: Codable, Equatable { var date: Date; var success: Bool; var message: String? }`
  - `struct AutoStartStatusStore { init(defaults: UserDefaults = .standard); func lastResult(for: UUID) -> AutoStartResult?; func saveResult(_:, for: UUID); mutating func shouldLog(_ reason: AutoStartSkipReason, for: UUID, now: Date, calendar: Calendar) -> Bool }`. `shouldLog` returns true the first time a given reason (compared by case, ignoring associated values) is seen for a profile on a calendar day; persisted under `autoStartLastResult` / `autoStartLoggedReasons` keys.
  - `AutoStartSessionService` gains an injectable `init(runner: ClaudeProcessRunning, locator: ClaudeBinaryLocator, now: () -> Date)` for tests; `shared` uses production values.
  - `Notification.Name.autoStartResultChanged` posted after `saveResult`, for the settings view.

Changes:
- Remove `sendInitializationMessage`, `deleteConversation`, `applyBrowserHeaders`, `parseCompletionResponseForResetTime`, `lastCapturedResetTime`, and the `profile.hasClaudeAI` guard.
- Usage reading per profile, in order: cookie (existing `fetchUsageData`); else the access token from `readKeychainCredentials(serviceName:)` (linked) or `readSystemCredentials()` (default login). Do not use `ClaudeAPIService.fetchUsageData(oauthAccessToken:)`, whose parser fills a missing `resets_at`. Call `https://api.anthropic.com/api/oauth/usage` from the service with the same headers (`Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`) and parse with the service's own static `parseUsageResponse`, which keeps `hasOpenWindow`. An expired token or a 401/403 → `.tokenExpired`. Any other error → `.failed`. Never refresh tokens; never use `profile.claudeUsage`.
- Only fetch usage for profiles that are enabled and in schedule.
- Per-profile in-flight `Set<UUID>`: a profile already being checked is skipped by any overlapping trigger.
- One-shot timers: after every check, schedule one timer at the earliest of (each enabled profile's `nextStart`, each in-schedule profile's known `resets_at` + 30 s). Re-arm on wake.
- On ping: count the attempt (`AutoStartAttemptStore`) just before launching; on `exitCode == -1` call `locator.invalidate()`; save `AutoStartResult`; send the existing notification; on a binary-not-found skip, notify at most once per profile per day via `shouldLog`.
- Skip logging: `.outOfSchedule` at debug; other reasons at info through `shouldLog`.

- [ ] **Step 1: Write failing tests:** status store (`testShouldLogOncePerDay`, `testShouldLogAgainNextDay`, `testDifferentReasonsLogSeparately`, `testResultRoundTrip`) using a throwaway `UserDefaults(suiteName:)`; service with a fake runner (`testOverlappingChecksPingOnce`: two concurrent checks for one profile → runner called once).
- [ ] **Step 2: Run**, expect failure. **Step 3: Implement.** **Step 4: Run** the full test suite. Expected: all PASS.
- [ ] **Step 5: Commit** `feat(autostart): schedule starts and drop the claude.ai chat path`.

### Task 6: Settings UI and strings

**Files:**
- Modify: `Claude Usage/Views/Settings/Profile/GeneralSettingsView.swift` (auto-start card)
- Modify: all 14 `Claude Usage/Resources/*.lproj/Localizable.strings`

Under the toggle, when it is on: a "Weekdays" row and a "Weekends" row, each with start and stop `DatePicker(displayedComponents: .hourAndMinute)` bound through `effectiveAutoStartSchedule`; a stop at or before the start is rejected by clamping the stop to start + 1 minute (max 1440). A last-result line from `AutoStartStatusStore`, refreshed on `.autoStartResultChanged`. Replace `general.autostart_description` and `general.autostart_requirement` values; add keys `general.autostart_weekdays`, `general.autostart_weekends`, `general.autostart_start`, `general.autostart_stop`, `general.autostart_last_success` (`"Last started %@"`), `general.autostart_last_failure` (`"Last attempt failed %@: %@"`), `general.autostart_never`. English copy:

- description: `"Keeps a 5-hour session window open during your schedule by sending a one-word message through Claude Code."`
- requirement: `"• Claude Code logged in to this account (a linked config dir, or the default login)"`

Other languages: translate.

- [ ] **Step 1:** Implement the card and strings.
- [ ] **Step 2: Run** `scripts/validate_localizations.sh`. Expected: passes. Run the Debug build. Expected: succeeds.
- [ ] **Step 3:** Run the app, open Settings > General for a profile, toggle auto-start, set times, quit and relaunch, confirm the times persisted. Screenshot for the PR.
- [ ] **Step 4: Commit** `feat(autostart): schedule controls in profile settings`.

### Task 7: Live check, docs, PR

- [ ] **Step 1:** Update `CHANGELOG.md` (Unreleased) and the Status section of `docs/plans/2026-11-01-upstream-triage.md` (monthly spend merged as #10; auto-start schedules in review).
- [ ] **Step 2:** Ask Devon first. Quit `/Applications/Claude Usage.app`, run the Debug build from this branch (it shares the same settings), and enable auto-start on Lumena with a schedule that starts within the next 10 minutes, and watch the app log for a ping and a following check that finds the window open. Confirm no second ping in the next 15 minutes. Quit the Debug copy and relaunch `/Applications/Claude Usage.app` (`install-local.sh` runs from `main` after merge).
- [ ] **Step 3:** Push and open the PR with `gh pr create`, including Task 1's recorded usage objects and Task 6's screenshot. No attribution lines.
