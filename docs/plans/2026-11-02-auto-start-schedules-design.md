# Auto-start schedules: design

Date: 2026-11-02. Branch: `feat/auto-start-schedules`.

## Why

Auto-start opens a Claude 5-hour session window ahead of time, so a workday lines up with window boundaries instead of the first prompt of the day. Devon starts work around 9:00 on weekdays. A window opened at 7:00 gives three windows across the workday (7 to 12, 12 to 17, 17 to 22) instead of two.

Today it is unreliable in both directions:

- It sometimes never runs. `AutoStartSessionService.checkProfile` skips any profile without a claude.ai `sessionKey` cookie, and only logs that at debug level. Devon's profiles authenticate through Claude Code CLI credentials (two of the three are linked to config dirs through fork PR #7), so they are skipped.
- It sometimes runs over and over. Before fork PR #9, an open window at 0% looked closed and was restarted every 5 minutes. PR #9 fixed that with a `resets_at` check and capped failed attempts. Separately, the service runs around the clock, so it restarts a window the moment the previous one ends, including overnight.
- It sends a chat through claude.ai, which needs the cookie, passes Cloudflare checks, and creates a conversation that must be deleted afterward (upstream #334).

## Goals

1. Per-profile schedules with separate weekday and weekend settings: a start time and a stop time for each.
2. Within the schedule, keep a session window open: start one at the start time, and start another whenever none is open, until the stop time.
3. Open windows by running the Claude Code CLI (`claude -p`) under the profile's own config dir, with no claude.ai conversation.
4. Use the cheapest current model and a fixed one-word message.
5. Skip the start when the account's weekly limit is used up (nice-to-have; low cost, so included).
6. Make failures visible: a skipped or failed profile logs why at info level or above.

## Non-goals

- Waking the Mac to run a start. If the Mac is asleep at the start time, the start happens when it wakes (see below). `pmset` wake schedules need admin rights and are out of scope.
- User-selectable model or message.
- Per-weekday schedules beyond the weekday/weekend split.
- Auto-start for Codex profiles (the capability flag stays off).

## Anti-goals

These would make the feature a failure even if it technically works:

- Starting a window when one is already open, or retrying in a loop.
- Pinging with the wrong account. An unlinked profile must never run the CLI under a config dir logged into a different account.
- Running Devon's Claude Code hooks, MCP servers, or plugins as a side effect (the notch HUD hooks would show a fake session).
- Leaving anything in the account's history (claude.ai chats, resumable Claude Code sessions).

## Behavior

### Schedule

Each profile has `autoStartSessionEnabled` (existing) and a schedule with two parts:

- Weekdays (Monday to Friday): start time, stop time.
- Weekends (Saturday and Sunday): start time, stop time.

Times are wall-clock local time, minute precision, in the Mac's current time zone. The stop time is later than the start time on the same day; a schedule does not cross midnight. The UI enforces that.

A profile is "in schedule" when today's part applies and `start <= now < stop`. Outside the schedule nothing is started. A window that is still running at the stop time just runs out.

Each day begins fresh at that day's start time, so Friday's late windows cannot shift Saturday's schedule.

### When to start

On each check, for each enabled profile that is in schedule:

1. If the account has no usage windows at all (`ClaudeUsage.hasNoUsageWindows`, Enterprise or spend-billed seats), skip. This is the existing check, kept.
2. If a session window is open (the usage response has a future `five_hour.resets_at`), do nothing.
3. If the weekly limit is at 100% (`seven_day` utilization >= 100), skip and log it.
4. If the PR #9 attempt policy says wait, wait.
5. Otherwise run the CLI ping.

Starts follow the actual window, not a fixed 5-hour grid. If Devon opens a window by hand at 6:30, the next start is at 11:30 when it ends. If the Mac wakes at 8:15 with no window open, a window starts at 8:15. (Devon chose "start right then" for the wake case; following the actual window everywhere is the same rule and my call.)

### Check timing

Keep the 5-minute timer and the wake check. Add two more triggers so starts land on time instead of up to 5 minutes late:

- A one-shot timer for the next start time across all profiles.
- A one-shot timer for the earliest known `resets_at` of an open window among in-schedule profiles.

Both are re-armed after each check. Wake from sleep re-arms them, because timers do not fire during sleep.

### The CLI ping

Run, with `CLAUDE_CONFIG_DIR` set to the profile's config dir:

```
claude -p "ping" --model haiku --tools "" --strict-mcp-config --setting-sources "" \
  --no-session-persistence --system-prompt "Reply with the single word ok." --output-format json
```

Measured on 2026-11-02 against Devon's `~/.claude` login: 1.9 s, about 600 input and 4 output tokens, model `claude-haiku-5-5`. The `haiku` alias tracks the current Haiku, so the app does not hard-code a model ID. `--bare` is not usable: it refuses OAuth logins.

Flags and why:

- `--tools ""` and `--strict-mcp-config`: no tools or MCP servers load.
- `--setting-sources ""`: user and project settings (hooks, plugins) are not read. Auth still works because it comes from the Keychain entry derived from `CLAUDE_CONFIG_DIR`.
- `--no-session-persistence`: no resumable session is written.
- Working directory: an empty directory under the app's caches folder, so no project `CLAUDE.md` or settings are picked up.

Success is exit status 0 and `is_error: false` in the JSON. The run has a 60-second timeout; on timeout the process is terminated and the attempt counts as failed.

Unverified: that a `claude -p` call opens the 5-hour window on the usage endpoint. Claude Code use on a subscription counts toward the same limits, so it is expected to. Verify this first in the implementation plan (ping an idle account, then read its usage). If it does not, stop and come back to Devon.

### Finding the `claude` binary

A GUI app does not inherit the shell `PATH`. Look in this order and use the first executable found: `~/.local/bin/claude`, `~/.claude/local/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, then `command -v claude` run through the user's login shell (`$SHELL -lc`). Cache the path for the app's lifetime. Run it directly with `Process`, never through a shell, so Devon's `claude` alias does not apply. If none is found, log an error and send the existing failure notification, at most once per profile per day.

### Which config dir a profile uses

- Linked profile (`customKeychainServiceName` is a hashed `Claude Code-credentials-<hash>` entry): the `~/.claude*` dir whose path hashes to that suffix. `ClaudeCodeSyncService.readOAuthAccount(forKeychainService:)` already finds it; factor out a function that returns the dir path.
- Unlinked profile: the default login, but only if the account logged in there matches the profile. Compare `accountUuid` (fall back to `emailAddress`) in `~/.claude.json`'s `oauthAccount` with the profile's stored `oauthAccountJSON`. If they differ or either is missing, skip with an info log ("default Claude Code login is a different account").
- No CLI credentials at all: skip with an info log. The claude.ai chat path is removed (see below).

For the default login, leave `CLAUDE_CONFIG_DIR` unset. Setting it, even to `~/.claude`, makes Claude Code use the hashed Keychain entry `Claude Code-credentials-<hash of ~/.claude>` and `~/.claude/.claude.json` instead of the unsuffixed entry and `~/.claude.json` (see `ClaudeCodeSyncService.defaultDirHashedServiceName`). The 2026-11-02 measurement ran with it unset. For a linked profile, set it to the dir's path.

Consequence: an unlinked profile auto-starts only while the default login is its account. Since pinned profiles never write the default entry (#355), the default login changes only when Devon switches to another unlinked profile or logs in with `claude` by hand. Devon's Personal profile is unlinked and matches the default login (checked 2026-11-02, same `accountUuid`), so it works. When the ping refreshes the default login's token, the profile's stored `cliCredentialsJSON` goes stale exactly as it does when Devon uses `claude` directly; the existing refresh-aware reads already handle that, so nothing new is needed.

### Reading usage

The check needs `five_hour.resets_at` and `seven_day.utilization` for the profile, live. The shared path through `ProviderRegistry` cannot supply that today: `ClaudeAPIService.parseUsageResponse` fills a missing `resets_at` with now + 5h (every response looks like an open window), and `AnthropicUsageProvider` returns the last saved usage without an error when no credential works (upstream #290), so a failed fetch looks like a live one.

So auto-start keeps its own fetch in `AutoStartSessionService` and leaves `ClaudeUsage`, the shared parser, and the provider contract alone (my call: smaller change, no effect on the menu bar). The fetch tries, in order:

1. The claude.ai cookie, if the profile has one (the current `fetchUsageData`).
2. The OAuth usage endpoint with the profile's CLI access token, read the same way the provider reads it (live Keychain entry for a linked profile, default entry for an unlinked profile whose account matches). The service must not refresh tokens itself.

Both responses go through the service's existing static `parseUsageResponse`, which already returns a separate `hasOpenWindow` flag. An expired access token is the usual state at 7:00 after an idle night, and the service must not refresh it. So a 401 from the OAuth endpoint for a profile that has a CLI login is handled differently: run the ping anyway. Claude Code refreshes its own token as part of the run (it owns that Keychain entry), and the next check reads usage with the fresh token. A ping while a window happens to be open costs about 600 tokens and does nothing else; the attempt policy bounds repeats. Any other error, including a missing credential, means skip this profile for this check. Never fall back to saved usage. Save the live result to the profile as now.

The OAuth usage endpoint returns 429 under heavy polling. The scheduler only fetches for profiles that are enabled and in schedule, at most once per check. If a fetch fails, skip that profile for this check and log it; do not count it as an attempt.

Unknown: whether the OAuth usage endpoint returns `resets_at` the same way as the claude.ai one. Check during implementation.

### Removing the claude.ai path

`sendInitializationMessage`, `deleteConversation`, `applyBrowserHeaders`, and `parseCompletionResponseForResetTime` are removed. A profile with only a claude.ai cookie and no Claude Code login can no longer auto-start. The settings section says so. (My call: one start path is simpler to keep reliable, and none of Devon's profiles needs the cookie path.)

The in-memory `lastCapturedResetTime` goes with it; the live `resets_at` check covers the same case.

### Attempt limit

Keep `AutoStartAttemptPolicy` and its store from PR #9 unchanged. An attempt counts once the CLI process has been launched.

### Visibility

- Each skip reason logs at info level once per profile per day, not every 5 minutes: not in schedule is debug, everything else (no CLI login, account mismatch, binary not found, weekly limit reached, usage fetch failed) is info or warning.
- Success and failure notifications stay as they are.
- The settings section shows the last auto-start result per profile (time and success or the error), stored in UserDefaults next to the attempt state.

## Data model

Add to `Profile`:

```swift
struct AutoStartSchedule: Codable, Equatable {
    struct Window: Codable, Equatable {
        var startMinute: Int  // minutes after local midnight, 0..<1440
        var stopMinute: Int   // > startMinute, <= 1440
    }
    var weekdays: Window
    var weekends: Window
}

var autoStartSchedule: AutoStartSchedule?
```

Decoding must accept profiles saved without the field (`decodeIfPresent`). A nil schedule means the default below.

Default for a profile with no saved schedule (my call): weekdays 7:00 to 20:00, weekends 9:00 to 22:00. Devon's Personal profile has auto-start enabled already, so this changes its behavior from around the clock to the default schedule. That is intended.

Pure, testable functions in a new `AutoStartSchedulePolicy` (same style as `AutoStartAttemptPolicy`):

- `isInSchedule(_ schedule:, at:, calendar:) -> Bool`
- `nextStart(after:, schedule:, calendar:) -> Date`

Weekday/weekend is decided from the `Calendar`'s weekday component (Saturday and Sunday are weekend regardless of locale). DST transitions use `Calendar` date math, not fixed seconds.

## Settings UI

In `GeneralSettingsView`'s auto-start card, under the toggle and only when it is on:

- Weekdays: start time picker, stop time picker.
- Weekends: start time picker, stop time picker.
- The requirement text changes to: needs a Claude Code login for this account (linked config dir, or the default `~/.claude` logged into this account).
- Last result line.

New strings go into every lproj (`scripts/validate_localizations.sh`). Exact layout is left to the builder, following `Views/Settings/DesignSystem/`.

## Tests

- `AutoStartSchedulePolicy`: weekday vs weekend, boundaries (exactly at start, exactly at stop), DST days, next start across a weekend.
- Config dir resolution: linked hash lookup, unlinked match and mismatch.
- The decision in "When to start" as a pure function over (in schedule, window open, weekly %, attempt decision).
- CLI runner: argument list and environment built correctly; result parsing of success, `is_error: true`, non-zero exit, timeout. Do not run the real binary in tests.
- Profile decoding without `autoStartSchedule`.

## Left to the builder

- How the check, one-shot timers, and wake observer are structured inside `AutoStartSessionService`.
- Whether the CLI runner is its own type (it should be testable without launching a process).
- Settings layout details.
- Log wording.
