//
//  AutoStartSessionService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-11.
//

import Foundation
import Cocoa

/// Background service that monitors all profiles and auto-starts sessions when they reset
@MainActor
final class AutoStartSessionService {
    static let shared = AutoStartSessionService()

    // Timer for 5-minute check cycle
    private var checkTimer: Timer?

    // Track last check time to prevent duplicate checks on wake
    private var lastCheckTime: Date = .distantPast

    // Observers for sleep/wake notifications
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?

    private let apiService: ClaudeAPIService
    private let profileManager: ProfileManager
    private let notificationManager: NotificationManager

    // Track last captured reset time per profile to prevent duplicate auto-starts
    private var lastCapturedResetTime: [UUID: Date] = [:]

    // Persistent per-profile attempt count and backoff (upstream #334)
    private let attemptStore = AutoStartAttemptStore()

    private init() {
        self.apiService = ClaudeAPIService()
        self.profileManager = ProfileManager.shared
        self.notificationManager = NotificationManager.shared
    }

    // MARK: - Lifecycle

    func start() {
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
                LoggingService.shared.logInfo("Mac woke from sleep - checking for session resets")
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

        LoggingService.shared.logInfo("AutoStartSessionService started (5-minute cycle + wake detection)")

        // Perform immediate initial check to populate state
        Task { @MainActor in
            await self.performCheckIfNeeded(source: "startup")
        }
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil

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
    private func performCheckIfNeeded(source: String) async {
        // Debounce: Don't check if we checked less than 10 seconds ago
        let timeSinceLastCheck = Date().timeIntervalSince(lastCheckTime)
        if timeSinceLastCheck < 10 {
            LoggingService.shared.logDebug("Skipping check from \(source) - checked \(Int(timeSinceLastCheck))s ago")
            return
        }

        lastCheckTime = Date()
        await checkAllProfiles(source: source)
    }

    private func checkAllProfiles(source: String) async {
        LoggingService.shared.logDebug("AutoStartSessionService: Checking all profiles for auto-start (source: \(source))")

        // Get all profiles with auto-start enabled
        let profilesWithAutoStart = profileManager.profiles.filter { $0.autoStartSessionEnabled }

        guard !profilesWithAutoStart.isEmpty else {
            LoggingService.shared.logDebug("No profiles with auto-start enabled")
            return
        }

        LoggingService.shared.logInfo("Checking \(profilesWithAutoStart.count) profile(s) with auto-start enabled")

        // Check each profile
        for profile in profilesWithAutoStart {
            await checkProfile(profile)
        }
    }

    private func checkProfile(_ profile: Profile) async {
        // Explicit capability gate: auto-start burns tokens via the claude.ai
        // conversation API — providers without it must be skipped by design,
        // not just incidentally via the credentials check below.
        guard profile.provider.descriptor.capabilities.autoStartSession else {
            LoggingService.shared.logDebug("Skipping profile '\(profile.name)' - provider does not support auto-start")
            return
        }

        // Skip if profile doesn't have Claude.ai credentials
        guard profile.hasClaudeAI else {
            LoggingService.shared.logDebug("Skipping profile '\(profile.name)' - no Claude.ai credentials")
            return
        }

        do {
            // Fetch current usage for this profile
            let (usage, hasOpenWindow) = try await fetchUsageForProfile(profile)

            let currentPercentage = usage.effectiveSessionPercentage

            // A session window that is open but unused reads 0% — often for
            // hours, because the initialization message (and light real usage)
            // rounds down to zero. Starting one then spends a request, and
            // leaves an empty conversation behind, to open something already
            // running. The in-memory `lastCapturedResetTime` guard below covers
            // the same run, but is lost across app restarts and never set for
            // windows the user opened themselves. Gating on the live reset time
            // from the API closes both gaps: only a window with no current
            // `resets_at` is genuinely waiting to be opened.
            if currentPercentage == 0.0 && !hasOpenWindow {
                // Check if we recently auto-started and should wait for reset
                if let lastResetTime = lastCapturedResetTime[profile.id],
                   Date() < lastResetTime {
                    let minutesRemaining = Int(lastResetTime.timeIntervalSinceNow / 60)
                    LoggingService.shared.logDebug("Profile '\(profile.name)': skipping auto-start - \(minutesRemaining)m until session reset")
                    return
                }

                // Bound retries when attempts keep failing, or succeed without
                // opening a window (upstream #334). Only attempts that created a
                // conversation count, so a network or server error before that
                // point cannot trigger the pause. The count is saved as soon as
                // the conversation exists, so a crash or quit mid-attempt still
                // counts.
                let now = Date()
                let previous = attemptStore.state(for: profile.id)
                if case .wait(let until) = AutoStartAttemptPolicy.decide(state: previous, now: now) {
                    let minutes = Int(until.timeIntervalSince(now) / 60)
                    LoggingService.shared.logDebug("Profile '\(profile.name)': auto-start backing off after \(previous?.attempts ?? 0) attempt(s) - next try in \(minutes)m")
                    return
                }

                LoggingService.shared.logInfo("Session at 0% for profile '\(profile.name)' - triggering auto-start")

                var counted: AutoStartAttemptState?
                let started = await autoStartSession(for: profile) {
                    let state = AutoStartAttemptPolicy.stateAfterAttempt(previous, now: now)
                    attemptStore.save(state, for: profile.id)
                    counted = state
                }

                if !started, let counted, counted.attempts >= AutoStartAttemptPolicy.maxAttempts {
                    let hours = Int(AutoStartAttemptPolicy.pauseAfterMaxAttempts / 3600)
                    LoggingService.shared.logWarning("Profile '\(profile.name)': \(counted.attempts) auto-start attempts without an open session window - pausing auto-start for \(hours)h")
                }
            } else {
                // Session is active, clear any tracked reset time since usage endpoint is now showing correct data
                lastCapturedResetTime.removeValue(forKey: profile.id)
                attemptStore.clear(for: profile.id)
                LoggingService.shared.logDebug("Profile '\(profile.name)': session at \(currentPercentage)% (window \(hasOpenWindow ? "open" : "closed"))")
            }

        } catch {
            LoggingService.shared.logError("Failed to check profile '\(profile.name)': \(error.localizedDescription)")
        }
    }

    private func fetchUsageForProfile(_ profile: Profile) async throws -> (usage: ClaudeUsage, hasOpenWindow: Bool) {
        // Fetch usage data using the profile's specific credentials
        let (usage, hasOpenWindow) = try await fetchUsageData(for: profile)

        // Save usage to profile
        await MainActor.run {
            profileManager.saveClaudeUsage(usage, for: profile.id)
        }

        return (usage, hasOpenWindow)
    }

    private func fetchUsageData(for profile: Profile) async throws -> (usage: ClaudeUsage, hasOpenWindow: Bool) {
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

        // Parse usage response
        return try parseUsageResponse(data)  // (usage, hasOpenWindow)
    }

    private func parseUsageResponse(_ data: Data) throws -> (usage: ClaudeUsage, hasOpenWindow: Bool) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError(code: .apiParsingFailed, message: "Failed to parse usage data", isRecoverable: false)
        }

        // Extract session usage (five_hour)
        var sessionPercentage = 0.0
        var sessionResetTime = Date().addingTimeInterval(5 * 3600)

        // Whether a window is currently open, as opposed to merely unused. The
        // API omits `resets_at` when no window is running; when one is running
        // it is present and in the future. Percentage alone cannot tell these
        // apart, since an open window reads 0% until usage accrues past
        // rounding. `sessionResetTime` above is synthesised when absent, so it
        // cannot carry this signal — hence a separate flag.
        var hasOpenWindow = false

        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let utilization = fiveHour["utilization"] {
                sessionPercentage = parseUtilization(utilization)
            }
            if let resetsAt = fiveHour["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                sessionResetTime = formatter.date(from: resetsAt) ?? sessionResetTime
                hasOpenWindow = sessionResetTime > Date()
            }
        }

        // Extract weekly usage (seven_day)
        var weeklyPercentage = 0.0
        var weeklyResetTime = Date().nextMonday1259pm()

        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let utilization = sevenDay["utilization"] {
                weeklyPercentage = parseUtilization(utilization)
            }
            if let resetsAt = sevenDay["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                weeklyResetTime = formatter.date(from: resetsAt) ?? weeklyResetTime
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
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                sonnetResetTime = formatter.date(from: resetsAt)
            }
        }

        let weeklyLimit = Constants.weeklyLimit
        let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))
        let opusTokens = Int(Double(weeklyLimit) * (opusPercentage / 100.0))
        let sonnetTokens = Int(Double(weeklyLimit) * (sonnetPercentage / 100.0))

        let usage = ClaudeUsage(
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
        return (usage, hasOpenWindow)
    }

    private func parseUtilization(_ value: Any) -> Double {
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

    /// Parse the completion response (SSE format) to extract session reset time from messageLimit.windows.5h
    private func parseCompletionResponseForResetTime(_ data: Data) -> Date? {
        guard let responseString = String(data: data, encoding: .utf8) else { return nil }

        // The response is SSE format - find the last completion event with messageLimit data
        let lines = responseString.components(separatedBy: "\n")
        for line in lines.reversed() {
            if line.hasPrefix("data: "),
               let jsonStart = line.index(line.startIndex, offsetBy: 6, limitedBy: line.endIndex),
               let jsonData = String(line[jsonStart...]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let messageLimit = json["messageLimit"] as? [String: Any],
               let windows = messageLimit["windows"] as? [String: Any],
               let fiveH = windows["5h"] as? [String: Any],
               let resetsAt = fiveH["resets_at"] as? Double {
                return Date(timeIntervalSince1970: resetsAt)
            }
        }
        return nil
    }

    // MARK: - Auto-Start Session

    /// Returns true when the initialization message was sent successfully.
    /// `onConversationCreated` runs once the temporary conversation exists.
    @discardableResult
    private func autoStartSession(for profile: Profile, onConversationCreated: () -> Void = {}) async -> Bool {
        do {
            // Call the initialization API for this profile and get response data
            let responseData = try await sendInitializationMessage(for: profile, onConversationCreated: onConversationCreated)

            // Capture reset time from response to prevent duplicate auto-starts
            if let resetTime = parseCompletionResponseForResetTime(responseData) {
                lastCapturedResetTime[profile.id] = resetTime
                LoggingService.shared.logInfo("Captured session reset time for '\(profile.name)': \(resetTime)")
            }

            LoggingService.shared.logInfo("Successfully auto-started session for profile '\(profile.name)'")

            // Send success notification
            await MainActor.run {
                notificationManager.sendAutoStartNotification(
                    profileName: profile.name,
                    success: true,
                    error: nil,
                    settings: profile.notificationSettings
                )
            }
            return true

        } catch {
            LoggingService.shared.logError("Failed to auto-start session for profile '\(profile.name)': \(error.localizedDescription)")

            // Send failure notification
            await MainActor.run {
                notificationManager.sendAutoStartNotification(
                    profileName: profile.name,
                    success: false,
                    error: error.localizedDescription,
                    settings: profile.notificationSettings
                )
            }
            return false
        }
    }

    /// Headers claude.ai expects on chat requests, matching a Safari session.
    /// Without them Cloudflare or CSRF checks can reject the request.
    private static func applyBrowserHeaders(to request: inout URLRequest, sessionKey: String) {
        if let url = request.url {
            request.setValue(ClaudeAPIService.sessionCookieHeader(sessionKey: sessionKey, url: url), forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
    }

    private func sendInitializationMessage(for profile: Profile, onConversationCreated: () -> Void) async throws -> Data {
        guard let sessionKey = profile.claudeSessionKey,
              let orgId = profile.organizationId else {
            throw AppError(
                code: .sessionKeyNotFound,
                message: "Missing credentials",
                isRecoverable: false
            )
        }

        // Create a new conversation
        let conversationURL = try URLBuilder(baseURL: Constants.APIEndpoints.claudeBase)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations"])
            .build()

        var conversationRequest = URLRequest(url: conversationURL)
        Self.applyBrowserHeaders(to: &conversationRequest, sessionKey: sessionKey)
        conversationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        conversationRequest.httpMethod = "POST"

        let requestedUUID = UUID().uuidString.lowercased()
        let conversationBody: [String: Any] = [
            "uuid": requestedUUID,
            "name": ""
        ]
        conversationRequest.httpBody = try JSONSerialization.data(withJSONObject: conversationBody)

        let (conversationData, conversationResponse) = try await URLSession.shared.data(for: conversationRequest)

        guard let httpResponse = conversationResponse as? HTTPURLResponse,
              (httpResponse.statusCode == 200 || httpResponse.statusCode == 201) else {
            throw AppError(code: .apiGenericError, message: "Failed to create conversation", isRecoverable: true)
        }

        onConversationCreated()

        // The conversation exists now. If the response cannot be parsed, fall
        // back to the UUID we asked for, so it can still be used and deleted.
        let json = try? JSONSerialization.jsonObject(with: conversationData) as? [String: Any]
        let conversationUUID: String
        if let parsed = json?["uuid"] as? String {
            conversationUUID = parsed
        } else {
            LoggingService.shared.logWarning("Auto-start could not parse the conversation response; using the requested UUID")
            conversationUUID = requestedUUID
        }

        // Send a minimal "Hi" message to initialize the session
        let messageURL = try URLBuilder(baseURL: Constants.APIEndpoints.claudeBase)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations", conversationUUID, "/completion"])
            .build()

        var messageRequest = URLRequest(url: messageURL)
        Self.applyBrowserHeaders(to: &messageRequest, sessionKey: sessionKey)
        messageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        messageRequest.httpMethod = "POST"

        let messageBody: [String: Any] = [
            "prompt": "Hi",
            "model": "claude-haiku-4-5-20251001",  // Ensures non-zero usage to prevent duplicate auto-starts
            "timezone": "UTC"
        ]
        messageRequest.httpBody = try JSONSerialization.data(withJSONObject: messageBody)

        // From here on the conversation exists. Delete it whether or not the
        // message goes through, so a failed send does not leave an empty chat
        // in the account's history (upstream #334).
        let messageData: Data
        do {
            let (data, messageResponse) = try await URLSession.shared.data(for: messageRequest)

            guard let messageHTTPResponse = messageResponse as? HTTPURLResponse,
                  messageHTTPResponse.statusCode == 200 else {
                let status = (messageResponse as? HTTPURLResponse)?.statusCode ?? -1
                let snippet = String(decoding: data.prefix(300), as: UTF8.self)
                LoggingService.shared.logError("Auto-start initialization message failed with status \(status): \(snippet)")
                throw AppError(code: .apiGenericError, message: "Failed to send initialization message (status \(status))", isRecoverable: true)
            }
            messageData = data
        } catch {
            await deleteConversation(conversationUUID, orgId: orgId, sessionKey: sessionKey)
            throw error
        }

        // Delete the conversation to keep it out of chat history (incognito mode)
        await deleteConversation(conversationUUID, orgId: orgId, sessionKey: sessionKey)

        return messageData
    }

    /// Deletes a temporary conversation. Failure is logged, not thrown: the
    /// caller's result (session started or not) does not depend on it.
    private func deleteConversation(_ conversationUUID: String, orgId: String, sessionKey: String) async {
        do {
            let deleteURL = try URLBuilder(baseURL: Constants.APIEndpoints.claudeBase)
                .appendingPathComponents(["/organizations", orgId, "/chat_conversations", conversationUUID])
                .build()

            var deleteRequest = URLRequest(url: deleteURL)
            Self.applyBrowserHeaders(to: &deleteRequest, sessionKey: sessionKey)
            deleteRequest.httpMethod = "DELETE"

            let (_, response) = try await URLSession.shared.data(for: deleteRequest)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                LoggingService.shared.logWarning("Auto-start could not delete temporary conversation \(conversationUUID): status \(status)")
            }
        } catch {
            LoggingService.shared.logWarning("Auto-start could not delete temporary conversation \(conversationUUID): \(error.localizedDescription)")
        }
    }
}
