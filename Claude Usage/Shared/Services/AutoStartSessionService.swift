//
//  AutoStartSessionService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-11.
//

import Foundation
import Cocoa

/// Background service that opens a Claude 5-hour session window for each
/// profile with auto-start enabled, within the profile's weekday or weekend
/// schedule, by running `claude -p` under the profile's own Claude Code login.
@MainActor
final class AutoStartSessionService {
    static let shared = AutoStartSessionService()

    /// Longest a ping may run before it is terminated and counted as failed.
    static let pingTimeout: TimeInterval = 60
    /// A one-shot check for an open window runs this long after its `resets_at`.
    static let resetSlack: TimeInterval = 30
    /// A one-shot check is never scheduled sooner than this, so a bad schedule
    /// or a reset time already past cannot make the timer fire in a loop.
    static let minimumTimerDelay: TimeInterval = 60

    static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // Repeating 5-minute check
    private var checkTimer: Timer?
    // Check at the next schedule start or window reset, re-armed after every check
    private var oneShotTimer: Timer?

    // Track last check time to prevent duplicate checks on wake
    private var lastCheckTime: Date = .distantPast

    // Observers for sleep/wake notifications
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    private let profileManager: ProfileManager
    private let notificationManager: NotificationManager
    private let runner: ClaudeProcessRunning
    private let now: () -> Date
    private let calendar: Calendar

    // Persistent per-profile attempt count and backoff (upstream #334)
    private let attemptStore: AutoStartAttemptStore
    // Last result per profile and once-per-day skip logging
    private var statusStore: AutoStartStatusStore

    private let injectedLoginResolver: ((Profile) -> Result<AutoStartLogin, AutoStartSkipReason>)?
    private let injectedUsageReader: ((Profile, AutoStartLogin) async -> AutoStartUsageReading)?
    private let injectedProfiles: (() -> [Profile])?

    /// True between `start()` and `stop()`. Checks and the one-shot timer do nothing otherwise.
    private(set) var isRunning = false

    /// Profiles with a check running. A trigger that overlaps a running check
    /// for the same profile skips it, so one window is never pinged twice.
    private var inFlight: Set<UUID> = []

    /// `resets_at` of the open window last seen per profile, for the one-shot timer.
    private var knownResetTimes: [UUID: Date] = [:]

    // `locate()` is mutating and async. It runs on a copy so no access to the
    // stored property spans a suspension, and concurrent callers share one lookup.
    private var locator: ClaudeBinaryLocator
    private var locatorLookup: Task<String?, Never>?
    private var locatorGeneration = 0

    init(
        runner: ClaudeProcessRunning = ClaudeProcessRunner(),
        locator: ClaudeBinaryLocator? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent,
        defaults: UserDefaults = .standard,
        loginResolver: ((Profile) -> Result<AutoStartLogin, AutoStartSkipReason>)? = nil,
        usageReader: ((Profile, AutoStartLogin) async -> AutoStartUsageReading)? = nil,
        profiles: (() -> [Profile])? = nil
    ) {
        self.profileManager = ProfileManager.shared
        self.notificationManager = NotificationManager.shared
        self.runner = runner
        self.locator = locator ?? .live()
        self.now = now
        self.calendar = calendar
        self.attemptStore = AutoStartAttemptStore(defaults: defaults)
        self.statusStore = AutoStartStatusStore(defaults: defaults)
        self.injectedLoginResolver = loginResolver
        self.injectedUsageReader = usageReader
        self.injectedProfiles = profiles
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        // Start 5-minute check timer with tolerance for energy efficiency
        let timer = Timer.scheduledTimer(
            withTimeInterval: 300, // 5 minutes
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.performCheckIfNeeded(source: "timer")
            }
        }
        timer.tolerance = 30 // Allow up to 30 seconds of drift for energy efficiency
        checkTimer = timer

        // Register for wake/sleep notifications
        let workspace = NSWorkspace.shared

        wakeObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                LoggingService.shared.logInfo("Mac woke from sleep - checking auto-start profiles")
                // Timers do not fire during sleep; re-arm before the check in
                // case the check is debounced.
                self.armOneShotTimer()
                await self.performCheckIfNeeded(source: "wake")
            }
        }

        sleepObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            LoggingService.shared.logDebug("Mac going to sleep")
        }

        LoggingService.shared.logInfo("AutoStartSessionService started (5-minute cycle, schedule timer, wake detection)")

        // Perform immediate initial check to populate state
        Task { @MainActor in
            await self.performCheckIfNeeded(source: "startup")
        }
    }

    func stop() {
        isRunning = false
        checkTimer?.invalidate()
        checkTimer = nil
        oneShotTimer?.invalidate()
        oneShotTimer = nil

        // Remove observers
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let sleepObserver = sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }

        LoggingService.shared.logInfo("AutoStartSessionService stopped")
    }

    // MARK: - Profile Checking

    /// Performs check with debouncing to prevent duplicate checks
    func performCheckIfNeeded(source: String) async {
        guard isRunning else { return }
        // Re-arm even when debounced: the trigger may have been the one-shot timer.
        // A check still running when `stop()` is called does not re-arm (see `armOneShotTimer`).
        defer { armOneShotTimer() }

        // Debounce: Don't check if we checked less than 10 seconds ago
        let timeSinceLastCheck = now().timeIntervalSince(lastCheckTime)
        if timeSinceLastCheck < 10 {
            LoggingService.shared.logDebug("Skipping check from \(source) - checked \(Int(timeSinceLastCheck))s ago")
            return
        }

        lastCheckTime = now()
        await checkAllProfiles(source: source)
    }

    private func checkAllProfiles(source: String) async {
        LoggingService.shared.logDebug("AutoStartSessionService: Checking all profiles for auto-start (source: \(source))")

        let profiles = currentProfiles().filter(isEligible)
        guard !profiles.isEmpty else {
            LoggingService.shared.logDebug("No profiles with auto-start enabled")
            return
        }

        for profile in profiles {
            await checkProfile(profile)
        }
    }

    private func currentProfiles() -> [Profile] {
        injectedProfiles?() ?? profileManager.profiles
    }

    private func isEligible(_ profile: Profile) -> Bool {
        profile.autoStartSessionEnabled && profile.provider.descriptor.capabilities.autoStartSession
    }

    /// Checks one profile and pings when it is in schedule and has no open window.
    /// Internal so tests can run overlapping checks.
    func checkProfile(_ profile: Profile) async {
        // Explicit capability gate: auto-start spends tokens on the account,
        // so providers without it are skipped by design.
        guard profile.provider.descriptor.capabilities.autoStartSession else {
            LoggingService.shared.logDebug("Skipping profile '\(profile.name)' - provider does not support auto-start")
            knownResetTimes.removeValue(forKey: profile.id)
            return
        }
        guard profile.autoStartSessionEnabled else {
            knownResetTimes.removeValue(forKey: profile.id)
            return
        }

        // Claim the profile before the first suspension point.
        guard !inFlight.contains(profile.id) else {
            LoggingService.shared.logDebug("Skipping profile '\(profile.name)' - a check is already running")
            return
        }
        inFlight.insert(profile.id)
        defer { inFlight.remove(profile.id) }

        let checkStart = now()
        guard AutoStartSchedulePolicy.isInSchedule(profile.effectiveAutoStartSchedule, at: checkStart, calendar: calendar) else {
            knownResetTimes.removeValue(forKey: profile.id)
            logSkip(.outOfSchedule, for: profile, at: checkStart)
            return
        }

        let login: AutoStartLogin
        let (resolution, defaultCredentials) = resolveLogin(for: profile)
        switch resolution {
        case .success(let resolved):
            login = resolved
        case .failure(let reason):
            knownResetTimes.removeValue(forKey: profile.id)
            logSkip(reason, for: profile, at: checkStart)
            return
        }

        let reading = await readUsage(for: profile, login: login, defaultCredentials: defaultCredentials)
        let checkTime = now()

        // Only a live reading says whether a window is open. Any other reading
        // drops the remembered reset time, so a stale one cannot drive the
        // one-shot timer.
        knownResetTimes.removeValue(forKey: profile.id)
        if case .live(let usage, let hasOpenWindow) = reading {
            if hasOpenWindow {
                knownResetTimes[profile.id] = usage.sessionResetTime
            }
            // A window seen open, or an account with no windows, ends the
            // current run of attempts.
            if hasOpenWindow || usage.hasNoUsageWindows {
                attemptStore.clear(for: profile.id)
            }
        }

        let attempt = AutoStartAttemptPolicy.decide(state: attemptStore.state(for: profile.id), now: checkTime)
        switch AutoStartDecision.decide(inSchedule: true, reading: reading, attempt: attempt) {
        case .skip(let reason):
            logSkip(reason, for: profile, at: checkTime)
        case .ping:
            await ping(profile, login: login)
        }
    }

    /// No 5-hour block and no weekly limit: nothing to auto-start. A null
    /// five_hour block alone is not enough, since idle Max and Pro accounts
    /// report it too.
    static func shouldSkipAutoStart(_ usage: ClaudeUsage) -> Bool {
        usage.hasNoUsageWindows
    }

    // MARK: - Ping

    private func ping(_ profile: Profile, login: AutoStartLogin) async {
        guard let executable = await locateBinary() else {
            let at = now()
            if statusStore.shouldLog(.binaryNotFound, for: profile.id, now: at, calendar: calendar) {
                let message = Self.describe(.binaryNotFound)
                LoggingService.shared.logError("Auto-start for '\(profile.name)' failed: \(message)")
                recordResult(AutoStartResult(date: at, success: false, message: message), for: profile)
            }
            return
        }

        // Count the attempt before launching, so a crash or quit mid-run still counts.
        let launchTime = now()
        let counted = AutoStartAttemptPolicy.stateAfterAttempt(attemptStore.state(for: profile.id), now: launchTime)
        attemptStore.save(counted, for: profile.id)
        LoggingService.shared.logInfo("Auto-start: running claude for '\(profile.name)' (attempt \(counted.attempts))")

        let output = await runner.run(
            executable: executable,
            arguments: ClaudeCLIPing.arguments,
            environment: ClaudeCLIPing.environment(for: login, base: ProcessInfo.processInfo.environment),
            workingDirectory: Self.pingWorkingDirectory(),
            timeout: Self.pingTimeout
        )
        if output.exitCode == -1 {
            // Launch failed: the binary may have moved (self-update, Homebrew upgrade).
            invalidateBinary()
        }

        switch ClaudeCLIPing.parseResult(exitCode: output.exitCode, stdout: output.stdout, timedOut: output.timedOut) {
        case .success:
            LoggingService.shared.logInfo("Auto-start opened a session window for '\(profile.name)'")
            recordResult(AutoStartResult(date: launchTime, success: true, message: nil), for: profile)
        case .failure(let failure):
            LoggingService.shared.logError("Auto-start for '\(profile.name)' failed: \(failure.message)")
            recordResult(AutoStartResult(date: launchTime, success: false, message: failure.message), for: profile)
            if counted.attempts >= AutoStartAttemptPolicy.maxAttempts {
                let hours = Int(AutoStartAttemptPolicy.pauseAfterMaxAttempts / 3600)
                LoggingService.shared.logWarning("Profile '\(profile.name)': \(counted.attempts) auto-start attempts without an open session window - pausing auto-start for \(hours)h")
            }
        }
    }

    /// Saves the result for the settings view and sends the existing notification.
    private func recordResult(_ result: AutoStartResult, for profile: Profile) {
        statusStore.saveResult(result, for: profile.id)
        notificationManager.sendAutoStartNotification(
            profileName: profile.name,
            success: result.success,
            error: result.message,
            settings: profile.notificationSettings
        )
    }

    /// An empty directory, so the CLI picks up no project `CLAUDE.md` or settings.
    private static func pingWorkingDirectory() -> URL {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        let directory = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.devondragon.ClaudeUsage", isDirectory: true)
            .appendingPathComponent("AutoStartPing", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Binary Lookup

    private func locateBinary() async -> String? {
        if let running = locatorLookup {
            return await running.value
        }
        let generation = locatorGeneration
        let lookup = Task { @MainActor () -> String? in
            var copy = self.locator
            let path = await copy.locate()
            // Keep the copy's cache only if nothing invalidated the locator meanwhile.
            if generation == self.locatorGeneration {
                self.locator = copy
            }
            return path
        }
        locatorLookup = lookup
        let path = await lookup.value
        locatorLookup = nil
        return path
    }

    private func invalidateBinary() {
        locatorGeneration += 1
        locator.invalidate()
    }

    // MARK: - Login and Usage

    /// The profile's login, plus the default login's credentials JSON when it
    /// was read, so the usage read does not run `security` a second time.
    private func resolveLogin(for profile: Profile) -> (Result<AutoStartLogin, AutoStartSkipReason>, defaultCredentials: String?) {
        if let injectedLoginResolver { return (injectedLoginResolver(profile), nil) }

        let sync = ClaudeCodeSyncService.shared
        // The default login's credentials and account matter only for a profile
        // that is not linked to its own config dir; skip the reads otherwise.
        let linked = sync.pinnedConfigDirService(of: profile) != nil
        let defaultCredentials: String? = linked ? nil : ((try? sync.readSystemCredentials()) ?? nil)
        let result = ClaudeCLIPing.resolveLogin(
            customKeychainService: profile.customKeychainServiceName,
            profileAccountJSON: profile.oauthAccountJSON,
            defaultAccountJSON: linked ? nil : sync.readOAuthAccount(),
            hasCliCredentials: defaultCredentials != nil,
            configDirPath: { sync.configDirPath(forKeychainService: $0) }
        )
        return (result, defaultCredentials)
    }

    private func readUsage(for profile: Profile, login: AutoStartLogin, defaultCredentials: String?) async -> AutoStartUsageReading {
        if let injectedUsageReader { return await injectedUsageReader(profile, login) }

        if profile.hasClaudeAI {
            do {
                let (usage, hasOpenWindow) = try await fetchUsageWithCookie(for: profile)
                // Accounts without usage windows are not saved: claude.ai's
                // response carries no spend, and saving it would drop the spend
                // the main refresh stored.
                if !usage.hasNoUsageWindows {
                    profileManager.saveClaudeUsage(
                        usage.respectingOverageOptOut(enabled: profile.checkOverageLimitEnabled),
                        for: profile.id
                    )
                }
                return .live(usage, hasOpenWindow: hasOpenWindow)
            } catch {
                LoggingService.shared.logDebug("Auto-start: claude.ai usage read failed for '\(profile.name)' (\(error.localizedDescription)); trying the Claude Code token")
            }
        }

        return await readUsageWithClaudeCodeToken(login: login, defaultCredentials: defaultCredentials)
    }

    /// Reads usage with the login's current access token. Never refreshes the
    /// token: the CLI owns it and refreshes it when the ping runs.
    private func readUsageWithClaudeCodeToken(login: AutoStartLogin, defaultCredentials: String?) async -> AutoStartUsageReading {
        let sync = ClaudeCodeSyncService.shared
        let credentials: String?
        switch login {
        case .defaultLogin:
            // Read once during login resolution; the default login is chosen only when it was found.
            credentials = defaultCredentials
        case .configDir(_, let keychainService):
            credentials = sync.readKeychainCredentials(serviceName: keychainService)
        }
        guard let credentials else {
            return .failed("could not read Claude Code credentials")
        }
        if sync.isTokenExpired(credentials) { return .tokenExpired }
        guard let token = sync.extractAccessToken(from: credentials) else { return .tokenExpired }

        var request = URLRequest(url: Self.oauthUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("invalid response from the usage endpoint")
            }
            switch http.statusCode {
            case 200:
                let (usage, hasOpenWindow) = try Self.parseUsageResponse(data, now: now())
                return .live(usage, hasOpenWindow: hasOpenWindow)
            case 401, 403:
                return .tokenExpired
            default:
                return .failed("usage endpoint returned status \(http.statusCode)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func fetchUsageWithCookie(for profile: Profile) async throws -> (usage: ClaudeUsage, hasOpenWindow: Bool) {
        // Get credentials from the specific profile
        guard let sessionKey = profile.claudeSessionKey,
              let orgId = profile.organizationId else {
            throw AppError(
                code: .sessionKeyNotFound,
                message: "Missing credentials for profile '\(profile.name)'",
                isRecoverable: false
            )
        }

        // Build URL
        let url = try URLBuilder(baseURL: Constants.APIEndpoints.claudeBase)
            .appendingPath("/organizations/\(orgId)/usage")
            .build()

        var request = URLRequest(url: url)
        request.setValue(ClaudeAPIService.sessionCookieHeader(sessionKey: sessionKey, url: url), forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(code: .apiInvalidResponse, message: "Invalid response", isRecoverable: true)
        }

        guard httpResponse.statusCode == 200 else {
            throw AppError(
                code: .apiGenericError,
                message: "API returned status \(httpResponse.statusCode)",
                isRecoverable: true
            )
        }

        return try Self.parseUsageResponse(data, now: now())
    }

    // MARK: - Usage Parsing

    static func parseUsageResponse(_ data: Data, now: Date = Date()) throws -> (usage: ClaudeUsage, hasOpenWindow: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(code: .apiParsingFailed, message: "Failed to parse usage data", isRecoverable: false)
        }

        // Extract session usage (five_hour)
        var sessionPercentage = 0.0
        var sessionResetTime = Date().addingTimeInterval(5 * 3600)

        // Whether a window is currently open, as opposed to merely unused. The
        // API omits `resets_at` (or sends null) when no window is running; when
        // one is running it is present and in the future. Percentage alone
        // cannot tell these apart, since an open window reads 0% until usage
        // accrues past rounding. `sessionResetTime` above is synthesized when
        // absent, so it cannot carry this signal, hence a separate flag.
        var hasOpenWindow = false

        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let utilization = fiveHour["utilization"] {
                sessionPercentage = parseUtilization(utilization)
            }
            if let resetsAt = fiveHour["resets_at"] as? String {
                if let parsed = parseResetDate(resetsAt) {
                    sessionResetTime = parsed
                    hasOpenWindow = parsed > now
                } else {
                    // Present but in an unknown format: assume a window is open
                    // rather than risk starting a second one.
                    hasOpenWindow = true
                }
            }
        }

        // Extract weekly usage (seven_day)
        var weeklyPercentage = 0.0
        var weeklyResetTime = Date().nextMonday1259pm()

        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let utilization = sevenDay["utilization"] {
                weeklyPercentage = parseUtilization(utilization)
            }
            if let resetsAt = sevenDay["resets_at"] as? String, let parsed = parseResetDate(resetsAt) {
                weeklyResetTime = parsed
            }
        }

        // Extract Opus weekly usage (seven_day_opus)
        var opusPercentage = 0.0
        if let sevenDayOpus = json["seven_day_opus"] as? [String: Any] {
            if let utilization = sevenDayOpus["utilization"] {
                opusPercentage = parseUtilization(utilization)
            }
        }

        // Extract Sonnet weekly usage (seven_day_sonnet)
        var sonnetPercentage = 0.0
        var sonnetResetTime: Date? = nil
        if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
            if let utilization = sevenDaySonnet["utilization"] {
                sonnetPercentage = parseUtilization(utilization)
            }
            if let resetsAt = sevenDaySonnet["resets_at"] as? String {
                sonnetResetTime = parseResetDate(resetsAt)
            }
        }

        let weeklyLimit = Constants.weeklyLimit
        let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))
        let opusTokens = Int(Double(weeklyLimit) * (opusPercentage / 100.0))
        let sonnetTokens = Int(Double(weeklyLimit) * (sonnetPercentage / 100.0))

        var usage = ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyTokensUsed: weeklyTokens,
            weeklyLimit: weeklyLimit,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: weeklyResetTime,
            opusWeeklyTokensUsed: opusTokens,
            opusWeeklyPercentage: opusPercentage,
            sonnetWeeklyTokensUsed: sonnetTokens,
            sonnetWeeklyPercentage: sonnetPercentage,
            sonnetWeeklyResetTime: sonnetResetTime,
            designWeeklyTokensUsed: 0,
            designWeeklyPercentage: 0,
            designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
        // No five_hour block: the account has no session window to open.
        // The window flags and spend are filled like the shared parser's,
        // because this usage is saved to the profile.
        usage.hasSessionWindow = json["five_hour"] is [String: Any]
        usage.hasWeeklyWindow = json["seven_day"] is [String: Any]
            || ((json["limits"] as? [Any])?.isEmpty == false)
        if let spend = ClaudeAPIService.parseSpend(from: json) {
            usage.costUsed = spend.usedCents
            usage.costLimit = spend.limitCents
            usage.costCurrency = spend.currency
            usage.spendLimitReached = spend.limitReached
            usage.spendUpdatedAt = Date()
        }
        return (usage, hasOpenWindow)
    }

    /// ISO 8601 `resets_at`. The OAuth endpoint sends some with fractional
    /// seconds ("2026-11-03T02:10:00.133519+00:00") and some without
    /// ("2026-11-09T10:00:00+00:00"), so both are accepted.
    static func parseResetDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func parseUtilization(_ value: Any) -> Double {
        if let intValue = value as? Int {
            return Double(intValue)
        }
        if let doubleValue = value as? Double {
            return doubleValue
        }
        if let stringValue = value as? String {
            let cleaned = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            if let parsed = Double(cleaned) {
                return parsed
            }
        }
        return 0.0
    }

    // MARK: - One-Shot Timer

    /// Schedules a check at the next schedule start or open-window reset, so a
    /// start lands on time instead of up to 5 minutes late.
    private func armOneShotTimer() {
        oneShotTimer?.invalidate()
        oneShotTimer = nil
        guard isRunning, let fireDate = nextOneShotDate() else { return }

        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performCheckIfNeeded(source: "scheduled")
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        oneShotTimer = timer
        LoggingService.shared.logDebug("Auto-start: next scheduled check at \(fireDate)")
    }

    /// When the one-shot timer should fire for the current profiles. Reset times
    /// already past are ignored; the repeating check covers those.
    func nextOneShotDate() -> Date? {
        let current = now()
        let profiles = currentProfiles().filter(isEligible)
        let resets = profiles
            .filter { AutoStartSchedulePolicy.isInSchedule($0.effectiveAutoStartSchedule, at: current, calendar: calendar) }
            .compactMap { knownResetTimes[$0.id] }
            .filter { $0 > current }
        return Self.nextCheckDate(
            now: current,
            schedules: profiles.map(\.effectiveAutoStartSchedule),
            openWindowResets: resets,
            calendar: calendar
        )
    }

    /// Whether a one-shot check is scheduled. For tests.
    var hasPendingOneShot: Bool { oneShotTimer != nil }

    /// Earliest of each schedule's next start and each open window's reset plus
    /// `resetSlack`, but never sooner than `minimumTimerDelay` from now. Nil when
    /// there is nothing to wait for.
    static func nextCheckDate(
        now: Date,
        schedules: [AutoStartSchedule],
        openWindowResets: [Date],
        calendar: Calendar
    ) -> Date? {
        let starts = schedules.map { AutoStartSchedulePolicy.nextStart(after: now, schedule: $0, calendar: calendar) }
        let resets = openWindowResets.map { $0.addingTimeInterval(resetSlack) }
        guard let earliest = (starts + resets).min() else { return nil }
        return max(earliest, now.addingTimeInterval(minimumTimerDelay))
    }

    // MARK: - Logging

    /// Out of schedule logs at debug. Other reasons log at info the first time
    /// they are seen for the profile each day, and at debug after that.
    private func logSkip(_ reason: AutoStartSkipReason, for profile: Profile, at date: Date) {
        let message = "Auto-start skipped for '\(profile.name)': \(Self.describe(reason))"
        if case .outOfSchedule = reason {
            LoggingService.shared.logDebug(message)
        } else if statusStore.shouldLog(reason, for: profile.id, now: date, calendar: calendar) {
            LoggingService.shared.logInfo(message)
        } else {
            LoggingService.shared.logDebug(message)
        }
    }

    static func describe(_ reason: AutoStartSkipReason) -> String {
        switch reason {
        case .outOfSchedule:
            return "outside the auto-start schedule"
        case .noUsageWindows:
            return "the account has no session or weekly window"
        case .windowOpen(let until):
            return until.map { "a session window is already open until \($0)" } ?? "a session window is already open"
        case .weeklyLimitReached:
            return "the weekly limit is used up"
        case .backingOff(let until):
            return "earlier attempts did not open a window; next try after \(until)"
        case .usageFetchFailed(let message):
            return "could not read usage (\(message))"
        case .noClaudeCodeLogin:
            return "no Claude Code login for this profile"
        case .accountMismatch:
            return "the default Claude Code login is a different account"
        case .binaryNotFound:
            return "the claude command was not found"
        }
    }
}
