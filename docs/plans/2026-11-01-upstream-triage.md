# Upstream triage and fix plan (2026-11-01)

Source: `hamed-elfayome/Claude-Usage-Tracker` as of 2026-11-01. Upstream `main` is at `588775e` (August 31, 2026), the same commit as this fork. There are 46 open issues and 22 open PRs. No upstream PR has a review, and most have no CI run. The maintainer's last issue reply was in late August.

Several issue comments cite fixes in `duncanleung/claude-account-switcher` (`7dc7ff0`, `a308423`, `edf8432`). That repo is not public, so those commits can't be pulled. The upstream PRs listed below are the usable sources.

## Decisions and order for this fork

Devon uses multiple profiles and auto-start. Decided on 2026-11-01:

- Bundle ID `com.devondragon.ClaudeUsage`, with a one-time import of profiles and settings from the upstream `HamedElfayome.Claude-Usage` defaults on first launch.
- Sparkle auto-update turned off for now. Own signed releases may come later.
- Auto-start gets new controls: active hours/schedule, respect the weekly limit, start through the Claude Code CLI instead of a claude.ai chat, and a configurable model and message.

Work order:

1. Phase 0 (fork identity).
2. Multi-profile fixes: #337 (PR #338), #331 (PR #345) together with #355, #335, PR #276.
3. Auto-start: fix #334 first, then the new controls. Write a short design doc before coding, since PR #349 overlaps.
4. The rest of phase 2, then phase 3.

## Status (updated 2026-11-02)

Done and merged into this fork's `main` (fork PRs #1 to #7 and #9):

- Phase 0, fork identity (#2). Bundle ID, settings import, own Keychain names, Release signing with team `NLLX25D2J2`, Sparkle off, upstream pings and prompts removed.
- #337 history disk writes (#3). Upstream PR #338 plus two more fake-reset causes: the `now + 5h` placeholder for an idle session, and the billing `resets_at` parse falling back to `Date()`.
- #335 follow-up (#4). Cached usage of a non-active profile no longer feeds reset detection or history. #335 itself (a non-active Codex profile on the shared `auth.json` is not polled) is by design.
- #331 and #355 (#5). Upstream PR #345 plus pinned-entry handling, a stale-copy save in `activateProfile`, and auto-switch trying the next candidate.
- PR #276 (#6). CLI OAuth profiles use the OAuth usage endpoint for per-model quotas.
- Linking profiles to logged-in Claude Code config dirs (#7). Design: `2026-11-01-claude-code-accounts.md`. Pinned profiles are read-only.
- #334 empty auto-start chats (#9). The temporary conversation is deleted on failure too, chat requests send browser headers, and attempts are limited per profile (3 attempts 5 and 10 minutes apart, then a 5 hour pause, stored in UserDefaults). Chosen over upstream PR #349; its weekly-limit gate moves into the controls design. Not tested against a live claude.ai account.

Next: write the design for the four auto-start controls (active hours/schedule, respect the weekly limit, start through the Claude Code CLI, configurable model and message) before coding.

Open loose ends:

- CI runs on the fork now (first runs on PR #9, 2026-11-02).
- Hosted tests launch the real app with real settings, including auto-start. Upstream PR #349 has a one-line `XCTestCase` guard in `AppDelegate` that would stop this.
- Not exercised by hand yet: switching between profiles (#5), and linking, unlinking and switching linked profiles (#7).
- Devon's Tribe and Lumena profiles have no credentials in the fork. Link them in Settings > CLI Account > Claude Code accounts.
- History files (12 to 27 MB) are pruned the first time a snapshot is recorded, not at launch. Backups were taken on 2026-11-01 in that session's scratchpad.
- The login keychain holds about 5,229 `Claude Code-credentials-<hash>` entries left by temporary config dirs. Cleanup deletes Claude Code's items, so it needs Devon's go-ahead.
- Devon's running copy launches from the `~/git/Claude-Usage-Tracker-local` worktree (branch `local/integration`, same tree as `main`). Remove it after switching to a build from `main`, and quit the app before any rebuild over its bundle.

## How to take upstream PRs

Fetch each with `git fetch upstream pull/<N>/head:<branch>` (after adding the `upstream` remote), rebase onto our `main`, review it as if it were new code, run the build and tests, and open it as a PR on this fork with the original author credited in the description. One fix per branch and PR.

## Phase 0: fork identity (before running our build day to day)

A build of this fork currently shares the bundle ID, UserDefaults, Keychain items, Sparkle feed, and heartbeat endpoint with the upstream app. Sparkle will offer upstream releases over our build.

1. Change `PRODUCT_BUNDLE_IDENTIFIER` (app and tests) and import settings from the upstream bundle's defaults once.
2. Disable Sparkle (own feed later).
3. Remove or repoint `HeartbeatService`.
4. Set `DEVELOPMENT_TEAM` and decide on signing. Unsigned builds keep profile secrets in the plaintext `profiles_v3` plist, so a stably signed local build matters if credentials should live in the Keychain.
5. Disable or rewrite the release, appcast, and Homebrew workflows (they target upstream's secrets, gh-pages, and tap).

## Phase 1: bugs that cause damage outside the app

| Issue | Problem | Source of fix |
|---|---|---|
| #337 | Usage history detects a "reset" on nearly every poll and rewrites the whole history file each refresh. Reported 10 to 17 GB/hour of disk writes and a 47 MB file. | Done: fork PR #3. |
| #331 | On profile switch, a failed `invalid_grant` refresh still writes the dead CLI snapshot into the `Claude Code-credentials` Keychain entry, logging out every running Claude Code session. | Done: fork PR #5. |
| #355 | Switching to a profile pinned to a custom `CLAUDE_CONFIG_DIR` Keychain entry overwrites the default entry. Re-sync on a pinned profile reads the default entry instead of the pinned one. | Done: fork PR #5. |
| #334 | Auto-start creates an empty Haiku chat on claude.ai every ~5 minutes when the init message fails. | Done: fork PR #9. |
| #321 | Every launch overwrites `~/.claude/statusline-command.sh` and `fetch-claude-usage.swift` with no diff check or backup, losing user edits. | No PR. Write fix: only rewrite when content differs, and keep a backup of a modified script. |

## Phase 2: wrong numbers on current plans and setups

| Issue | Problem | Source of fix |
|---|---|---|
| #356 | Ultra plan has no 5-hour limit (`five_hour: null`). The app shows a 0% session bar with a reset that never arrives, and the statusline fetch script throws. Same parsing in `ClaudeAPIService` (~L800), `AutoStartSessionService` (~L248), `StatuslineService` (~L59). | No PR. Write fix: represent "no session limit" explicitly and hide session UI. |
| (Codex) | Codex Pro also has no 5-hour limit. | PR #342 (+360/-72). Solve #356 and this with one "has session limit" concept instead of two provider-specific paths. |
| #335 | Multi-profile display never polls non-active profiles, so their numbers freeze. | Cached-value part done: fork PR #4. Not polling a non-active profile without its own credentials is by design (#290). |
| #276 (PR) | Per-model weekly bars (Fable/Opus/Sonnet) stay at 0% for CLI OAuth profiles because that path reads rate-limit headers only. | Done: fork PR #6. Possibly explains #317. |
| #319 | Cloudflare `cf_clearance` is a partitioned cookie that `HTTPCookieStorage.cookies(for:)` doesn't return, giving E3006 on every refresh behind VPNs. | PR #320 (+144/-5, CI passing, has tests). |
| #322 | Statusline drops the usage segment when the cache is older than 300 s, which happens in normal use. | No PR yet (Ghost-9 offered to write one; ymendel has a patch in a config repo). Write fix alongside #321. |
| #333 | Stack-overflow crash on macOS 26 in SwiftUI material rendering (detached popover and settings windows). | PR #279 opts out of Liquid Glass app-wide via `UIDesignRequiresCompatibility`. The alternative is extending the existing layout reentrancy guard to those windows. Decide which. |
| #325 | Team plans: "Extra Usage" shows the org total, not the member's own credits. | PR #288 adds a member month-to-date spend row (+517/-1). Partly a feature; at minimum relabel the row as org-wide. |

## Phase 3: small, low-risk PRs

- PR #344: quit if another copy is already running (+24). Useful while both upstream and fork builds are installed.
- PR #343: install the notch `SessionStart` hook as a `command` hook, since Claude Code ignores `http` hooks on `SessionStart`.
- PR #284: notch HUD session naming and display fixes.
- PR #315: recolor menu bar digits when the menu bar tint changes.

## Reports too thin to act on now

#340, #341, #348, #351 (blank templates or "doesn't track"), #317, #312, #266, #274, #230, #226. Several may be explained by #337, #276, #356, or #319. Revisit after phases 1 and 2. #346 (icon removed by Cmd-drag on macOS 26.4): the code already forces `isVisible = true`, so this is likely the macOS 26 System Settings > Menu Bar toggle; consider reopening Settings when the app is relaunched with no visible status item.

## Feature requests (for the customization phase)

Fable weekly usage in menu bar and statusline (#318, #323), exclude weekends from pace (#326, PR #327), API credits in menu bar (#352), multi-profile font size and labels (#347), local read-only usage endpoint (#314), WidgetKit widgets (PR #304), reset countdown segment (#311), ahead-of-budget display (#306).
