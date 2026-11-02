# Claude Code accounts as a credential source

Date: 2026-11-01. Builds on PR #5 (pinned keychain entries, upstream #355).

## Goal

Let a profile get its usage from a Claude Code config dir that is already logged in (`~/.claude`, `~/.claude-tribe`, ...) without a claude.ai web sign-in. The in-app web sign-in cannot offer passkeys or Keychain password autofill: an embedded `WKWebView` gets passkeys only for domains the app owns (or with Apple's browser entitlement), and `ASWebAuthenticationSession`, which supports both, does not return the `sessionKey` cookie. Reading the CLI's own login avoids the web sign-in for usage tracking.

## Current state

- A profile can already be pinned to a keychain entry (`customKeychainServiceName`). Claude Code names the entry `Claude Code-credentials-<sha256(config dir path)[:8]>`, or `Claude Code-credentials` for `~/.claude`.
- The settings picker lists every `Claude Code-credentials*` entry and labels each one by reading it with a `security` subprocess. A machine that has used many temporary config dirs can have thousands of entries (5,229 on the author's machine), so the picker is unusable there.
- When a pinned entry's access token expires, the app refreshes it and writes the rotated tokens back. If Claude Code refreshes at the same time, one side spends a refresh token the other already used, and that config dir is logged out.
- If a pinned profile is active and its token is expired, both usage paths fall back to the default `~/.claude` login, which can be a different account.

## Design

1. Discovery. `ClaudeCodeSyncService.discoverConfigDirAccounts()` scans `~/.claude` and `~/.claude-*`, reads each dir's `.claude.json` `oauthAccount` (email, org, account UUID), computes the entry name from the path, and keeps the dirs whose entry exists. Existence comes from one `SecItemCopyMatching` attribute query (no secrets, no subprocess per entry).
2. Settings UI. The CLI Account tab's "Advanced: Credentials source" picker becomes a "Claude Code accounts" list: one row per logged-in dir with email, org and path, a "Use for this profile" button, and a "Linked" state with "Unlink". Linking sets the pin, copies the dir's `oauthAccount`, and pulls the current token once. A "Link matching profiles" button links every unlinked profile whose stored account email, or whose name, matches exactly one dir.
3. Read-only tokens. For pinned profiles the app uses the entry's access token while it is valid and never refreshes it. An expired token yields the last stored usage until Claude Code refreshes the entry on its next use.
4. No cross-account fallback. A profile pinned to a non-default config dir never falls back to the default `~/.claude` login, in either the multi-profile provider path or the single-profile `getAuthentication()` path.
5. Stale marker. The popover shows "Updated <relative time>" when the active profile's usage is more than 10 minutes old.

## Out of scope

- Config dirs outside the home directory (or not named `.claude*`). The hash scheme needs the path, and scanning the disk for them is not worth it. Such entries can still be pinned by editing the profile store; the picker for them is removed.
- Cleaning up stale keychain entries left by temporary config dirs. That deletes Claude Code's items and needs its own explicit step.
- Using the CLI token for the statusline script and extra-usage spend, which still need a claude.ai session key.
