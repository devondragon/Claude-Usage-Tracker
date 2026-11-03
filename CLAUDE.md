# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## About this fork

This is a fork of `hamed-elfayome/Claude-Usage-Tracker` (origin is `devondragon/Claude-Usage-Tracker`; no `upstream` remote is configured). Upstream went quiet around August 2026. The plan is to fix open upstream issues first, then customize the app. Upstream issue numbers (`#290`, `#267`, etc.) appear throughout code comments and `CHANGELOG.md`; they refer to the upstream tracker.

Fork identity, and how it differs from upstream:

- Bundle ID `com.devondragon.ClaudeUsage`. On first launch `UpstreamSettingsImporter` copies the upstream `HamedElfayome.Claude-Usage` defaults domain once (profiles, display config, notch token). Credentials do not carry over; profiles need a CLI re-sync or sign-in.
- Keychain service names are prefixed `com.devondragon.ClaudeUsage.` so this app never reads upstream's login-keychain items (a different signature would trigger password prompts).
- Release builds sign with Developer ID team `NLLX25D2J2` (stable identity, so per-profile secrets go to the login keychain). Debug builds are ad-hoc and keep secrets in the `profiles_v3` plist.
- Sparkle is off: `UpdateManager.isEnabled` is false without `SUFeedURL` in Info.plist, and the Updates tab hides. Adding a feed URL and EdDSA public key turns it back on.
- Heartbeat, star/feedback prompts, support reminder, sponsor slot, and mobile-app signup were removed. `Constants.GitHub` still points upstream for contributor credits; `Constants.forkRepoURL` is this repo.
- `release.yml` runs on `v*` tags and needs this repo's own signing and notarization secrets. The upstream appcast and Homebrew workflows were removed.
- The test target is hosted in the app, so `xcodebuild test` launches it as `com.devondragon.ClaudeUsage` with the real UserDefaults domain (including the first-launch import). Quit any leftover Debug copy afterward.
- Usage history files stay in `~/Library/Application Support/Claude Usage/history/`, the same folder upstream uses, so imported profiles keep their history.

## Build and test

Xcode 16+ is required (the project uses `PBXFileSystemSynchronizedRootGroup`, so new files dropped into `Claude Usage/` or `Claude UsageTests/` are picked up without editing `project.pbxproj`). CI uses Xcode 26.0.1 on `macos-15`. Deployment target is macOS 14.0. There are no Swift packages beyond Sparkle and DynamicNotchKit (resolved by Xcode), and no linter or formatter config.

```bash
# Build (unsigned, same flags as CI)
xcodebuild build -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# All tests (XCTest; the test target is hosted in the app, so a Debug build must exist)
xcodebuild test -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Debug -derivedDataPath build -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# One test class or method: append to the test command above
  -only-testing:"Claude UsageTests/CodexProviderTests"
  -only-testing:"Claude UsageTests/CodexProviderTests/testSomething"

# Check every lproj has the same keys as en.lproj
scripts/validate_localizations.sh

# Drive the notch HUD hook server by hand (app running, HUD enabled)
bash test_notch.sh [movie|abuse]
```

Daily-use install: `scripts/install-local.sh` builds a signed Release of the current checkout, quits any running copy, and installs it to `/Applications/Claude Usage.app` (`--no-build` reinstalls the last build; `--ad-hoc` signs ad-hoc for a machine without the Developer ID certificate, and profile secrets then stay in the plist). It refuses to overwrite an app with a different bundle ID. Run it from `main` after merging. Launch at login (`SMAppService.mainApp`) is tied to the copy that enabled it, so enable it from the `/Applications` copy.

Unsigned/ad-hoc builds have no reachable data-protection Keychain, so `ProfileStore` keeps profile secrets in the cleartext `profiles_v3` plist instead of the Keychain. This is expected for dev builds (logged once), and it means Keychain-specific behavior can only be verified on a stably signed build.

## Architecture

Native Swift/SwiftUI menu bar app (`NSApp.setActivationPolicy(.accessory)`, no Dock icon). `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set on the app target, so types are main-actor isolated unless marked otherwise. Most services are `static let shared` singletons.

### Startup and refresh

`App/AppDelegate.swift` runs the launch sequence: `ProfileManager.shared.loadProfiles()`, regenerate installed statusline scripts, start `UpdateManager` (Sparkle), create `MenuBarManager`, start the opt-in notch HUD, then either `menuBarManager.setup()` or the setup wizard. `MenuBarManager` is always created before the wizard because the wizard window can fail to show on macOS Tahoe (upstream #197).

`MenuBar/MenuBarManager.swift` (~1,900 lines) owns the status items, popover, refresh timer, wake/screen-change observers, profile switching, auto-switch-on-threshold, and reset detection for usage history. It runs in single-profile or multi-profile display mode; multi-profile mode polls every selected profile. `MenuBar/UsageRefreshCoordinator.swift` is not instantiated anywhere; the live refresh path is `MenuBarManager.refreshUsage()` / `refreshAllSelectedProfiles()`.

### Providers

All usage fetching goes through `Shared/Services/Providers/ProviderRegistry.swift`. Each `Provider` (Anthropic, Codex) has a `ProviderDescriptor` with capability flags and a `UsageProviderService` implementation. UI and core managers must check capability flags, never `provider == .x`. Every provider maps its data onto `ClaudeUsage` (session/weekly percentages and reset times; token fields left at 0 when unavailable). Read `docs/ADDING_A_PROVIDER.md` before adding or changing a provider; it lists which core files should not need edits.

Anthropic auth priority, in `AnthropicUsageProvider` and `ClaudeAPIService.getAuthentication()`:

1. claude.ai `sessionKey` cookie (web endpoint `claude.ai/api/organizations/{org}/usage`).
2. Profile's saved Claude Code CLI OAuth credentials, refreshed via refresh token or pulled from the profile's `customKeychainServiceName` entry.
3. System Keychain CLI OAuth token, used only for the active profile (it reflects whichever account the `claude` CLI is logged into).

If none works for a non-active profile, the last-known usage snapshot is shown instead of an error (upstream #290). Non-active profiles must not refresh CLI tokens independently, since that rotates a token another tool owns.

`ClaudeAPIService+ConsoleAPI.swift` handles the separate API Console billing/cost tracking.

### Profiles and storage

- `ProfileManager` (ObservableObject) holds profiles and the active profile; `ProfileStore` persists them in standard UserDefaults under `profiles_v3`. Credential fields are excluded from plist encoding and written to the Keychain via `KeychainService` (upstream GHSA-mfxh-xpwm-23c7). `Provider` raw values are persisted there: never rename them.
- `SharedDataStore` holds app-wide settings (language, statusline config, prompts). `DataStore` holds older per-app settings and menu bar icon enums.
- `MigrationService`, `ProfileMigrationService`, and `KeychainMigrationService` upgrade data from older versions (including the old app-group suite `group.com.claudeusagetracker.shared`). Changes to stored models need to keep decoding old data; `ClaudeUsage` decoding is deliberately tolerant.
- `ClaudeCodeSyncService` reads and writes Claude Code CLI credentials in the system Keychain via `/usr/bin/security` subprocesses. Every call is bounded by a timeout because `security` can hang on macOS 26.3.x (upstream #179).

### Integrations that write outside the app

- `StatuslineService` embeds a bash script and a Swift fetch script as string literals and installs them into `~/.claude/` (`fetch-claude-usage.swift` plus statusline config). Session key, org ID, and Cloudflare clearance cookies are injected at install time, and installed scripts are regenerated on every launch. Edits to the embedded scripts take effect for users only through that regeneration.
- `TerminalLauncherService` installs per-profile `claude-<profile>` commands that set `CLAUDE_CONFIG_DIR`.
- Notch HUD (`Shared/Services/NotchHUD/`, `MenuBar/NotchHUD/`): `NotchHookInstaller` adds HTTP hooks to `~/.claude/settings.json`; `NotchHookServer` listens on `127.0.0.1:19847` at `/hook/<token>/<event>` (token stored in UserDefaults as `notchHUDPathToken`); `NotchSessionStore` feeds the DynamicNotchKit UI.

### UI

`Views/SettingsView.swift` routes a `SettingsSection` enum to views under `Views/Settings/` (`App/` for app-wide settings, `Profile/` for per-profile settings, `Credentials/` for auth). Shared styling lives in `Views/Settings/DesignSystem/` and `Views/Settings/Components/`. The popover is `MenuBar/PopoverContentView.swift`; icons are drawn in `MenuBar/MenuBarIconRenderer.swift`.

### Localization

User-facing strings use keys in `Resources/<lang>.lproj/Localizable.strings` (14 languages). Any new key must be added to every lproj; run `scripts/validate_localizations.sh` to check.

## Conventions

From `CONTRIBUTING.md`: Conventional Commits (`fix(menubar): ...`), branch prefixes `feat/`, `fix/`, `docs/`, `refactor/`, `chore/`, `// MARK: -` section comments, async/await over completion handlers, business logic in managers/services rather than views.

Releases: bump both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.pbxproj` (Sparkle compares the build number, so it must increase every release), add a `CHANGELOG.md` entry, then push a `vX.Y.Z` tag. See `RELEASING.md`.
