//
//  ClaudeCLIPing.swift
//  Claude Usage
//
//  Opens a Claude 5-hour window by running `claude -p` under a profile's own
//  Claude Code login. Pure pieces (which login, arguments, environment, result
//  parsing, binary lookup) plus a thin Process runner.
//

import Foundation

/// The Claude Code login a ping runs under.
enum AutoStartLogin: Equatable {
    /// The default `~/.claude` login (no `CLAUDE_CONFIG_DIR`).
    case defaultLogin
    /// A non-default config dir, selected with `CLAUDE_CONFIG_DIR`.
    case configDir(path: String, keychainService: String)
}

/// Lets `AutoStartSkipReason` be the failure of a `Result`.
extension AutoStartSkipReason: Error {}

/// Why a ping run failed, worded for the user. A wrapper because `Result`
/// needs an `Error` failure type and `String` is not one.
struct ClaudeCLIPingFailure: Error, Equatable {
    let message: String
}

nonisolated enum ClaudeCLIPing {

    // MARK: - Login Resolution

    /// Picks the Claude Code login for a profile.
    ///
    /// A profile linked to a non-default keychain entry runs under that entry's
    /// config dir. Any other profile runs under the default login, but only when
    /// that login holds CLI credentials and is the same account as the profile;
    /// otherwise the ping would open a window on someone else's account.
    static func resolveLogin(
        customKeychainService: String?,
        profileAccountJSON: String?,
        defaultAccountJSON: String?,
        hasCliCredentials: Bool,
        configDirPath: (String) -> String?
    ) -> Result<AutoStartLogin, AutoStartSkipReason> {
        if let service = customKeychainService, service != ClaudeCodeSyncService.legacyServiceName {
            guard let path = configDirPath(service) else {
                return .failure(.noClaudeCodeLogin)
            }
            return .success(.configDir(path: path, keychainService: service))
        }
        guard hasCliCredentials else {
            return .failure(.noClaudeCodeLogin)
        }
        guard sameAccount(profileAccountJSON, defaultAccountJSON) else {
            return .failure(.accountMismatch)
        }
        return .success(.defaultLogin)
    }

    /// Whether two `oauthAccount` JSON objects name the same account: by
    /// `accountUuid` when both have one, else by `emailAddress` (case-insensitive)
    /// when both have one. Anything less is treated as a mismatch.
    private static func sameAccount(_ lhs: String?, _ rhs: String?) -> Bool {
        let a = accountFields(lhs)
        let b = accountFields(rhs)
        if let uuidA = a.uuid, let uuidB = b.uuid {
            return uuidA == uuidB
        }
        if let emailA = a.email, let emailB = b.email {
            return emailA.caseInsensitiveCompare(emailB) == .orderedSame
        }
        return false
    }

    private static func accountFields(_ json: String?) -> (uuid: String?, email: String?) {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let uuid = (obj["accountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = (obj["emailAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (uuid, email)
    }

    // MARK: - Command

    /// Smallest request that counts as usage: Haiku, no tools, no MCP servers, no
    /// user or project settings, nothing saved to session history. The two empty
    /// strings are real empty arguments (`--tools ""`, `--setting-sources ""`).
    static let arguments: [String] = [
        "-p", "ping",
        "--model", "haiku",
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "",
        "--no-session-persistence",
        "--system-prompt", "Reply with the single word ok.",
        "--output-format", "json"
    ]

    static let configDirVariable = "CLAUDE_CONFIG_DIR"

    /// Directories put at the front of the child's PATH, after the executable's
    /// own directory. A GUI app inherits only `/usr/bin:/bin:/usr/sbin:/sbin`, so a
    /// script install of `claude` (`#!/usr/bin/env node`) would not find `node`.
    static let preferredPathDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// `base` with `CLAUDE_CONFIG_DIR` set for a config-dir login and removed for
    /// the default login, so an inherited value never picks the wrong account.
    /// PATH starts with the executable's directory and `preferredPathDirectories`,
    /// followed by the rest of the inherited PATH, without duplicates.
    static func environment(for login: AutoStartLogin, executable: String, base: [String: String]) -> [String: String] {
        var env = base
        switch login {
        case .defaultLogin:
            env.removeValue(forKey: configDirVariable)
        case .configDir(let path, _):
            env[configDirVariable] = path
        }
        let executableDirectory = (executable as NSString).deletingLastPathComponent
        let inherited = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let path = ([executableDirectory] + preferredPathDirectories + inherited)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        env["PATH"] = path.joined(separator: ":")
        return env
    }

    // MARK: - Result

    static let maxResultTextLength = 200

    /// Success only when the CLI exited 0 and its JSON reports `is_error: false`.
    /// The failure message names the timeout, the exit code, or the CLI's own
    /// `result` text (truncated).
    static func parseResult(exitCode: Int32, stdout: Data, timedOut: Bool) -> Result<Void, ClaudeCLIPingFailure> {
        if timedOut {
            return .failure(ClaudeCLIPingFailure(message: "claude timed out"))
        }
        let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any]
        let resultText = (json?["result"] as? String).map { String($0.prefix(maxResultTextLength)) }

        guard exitCode == 0 else {
            if let text = resultText, !text.isEmpty {
                return .failure(ClaudeCLIPingFailure(message: "claude exited with code \(exitCode): \(text)"))
            }
            return .failure(ClaudeCLIPingFailure(message: "claude exited with code \(exitCode)"))
        }
        guard let json else {
            return .failure(ClaudeCLIPingFailure(message: "claude returned output that is not JSON"))
        }
        guard let isError = json["is_error"] as? Bool else {
            return .failure(ClaudeCLIPingFailure(message: "claude returned JSON without is_error"))
        }
        if isError {
            return .failure(ClaudeCLIPingFailure(message: "claude reported an error: \(resultText ?? "no message")"))
        }
        return .success(())
    }
}

// MARK: - Binary Locator

/// Finds the `claude` executable. Known install paths are checked first, then a
/// login shell's `command -v claude`. A found path is cached until `invalidate()`.
/// After a miss the shell lookup is not repeated for `missRetryInterval`, so a Mac
/// without `claude` does not start a login shell on every check; the install paths
/// are still checked each time.
///
/// Main-actor isolated (the app default) so a service can keep it in a stored
/// property and call the mutating `locate()` on it. The live shell lookup hops off
/// the main actor itself.
struct ClaudeBinaryLocator {

    static let defaultCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
    }()

    nonisolated static let shellLookupTimeout: TimeInterval = 10
    static let missRetryInterval: TimeInterval = 10 * 60

    private let candidates: [String]
    private let isExecutable: (String) -> Bool
    private let shellLookup: () async -> String?
    private let now: () -> Date
    private var cachedPath: String?
    private var lastShellMiss: Date?

    init(
        candidates: [String],
        isExecutable: @escaping (String) -> Bool,
        shellLookup: @escaping () async -> String?,
        now: @escaping () -> Date = Date.init
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.shellLookup = shellLookup
        self.now = now
    }

    /// The production locator: default candidates, real file checks, login-shell lookup.
    static func live() -> ClaudeBinaryLocator {
        ClaudeBinaryLocator(
            candidates: defaultCandidates,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            shellLookup: { await loginShellLookup() }
        )
    }

    mutating func locate() async -> String? {
        if let cachedPath { return cachedPath }
        if let found = candidates.first(where: isExecutable) {
            cachedPath = found
            return found
        }
        if let lastShellMiss, now().timeIntervalSince(lastShellMiss) < Self.missRetryInterval {
            return nil
        }
        if let found = await shellLookup(), isExecutable(found) {
            cachedPath = found
            lastShellMiss = nil
            return found
        }
        lastShellMiss = now()
        return nil
    }

    /// Forgets the cached path and any recent miss, so the next `locate()` searches again.
    mutating func invalidate() {
        cachedPath = nil
        lastShellMiss = nil
    }

    /// Runs `$SHELL -lc 'command -v claude'` on a global queue so a PATH set in the
    /// user's login profile is honored without blocking the caller's actor. Takes the
    /// last output line that is an absolute path, since login profiles can print
    /// banners first.
    nonisolated static func loginShellLookup() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: loginShellLookupBlocking())
            }
        }
    }

    nonisolated private static func loginShellLookupBlocking() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let result = ClaudeProcessRunner.runBlocking(
            executable: shell,
            arguments: ["-lc", "command -v claude"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            timeout: shellLookupTimeout
        )
        guard result.exitCode == 0, !result.timedOut,
              let output = String(data: result.stdout, encoding: .utf8) else {
            return nil
        }
        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { $0.hasPrefix("/") })
    }
}

// MARK: - Process Runner

nonisolated protocol ClaudeProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: Data, timedOut: Bool)
}

nonisolated struct ClaudeProcessRunner: ClaudeProcessRunning {

    /// How long to wait after `terminate()` before sending SIGKILL, and for the
    /// stdout pipe to reach end of file after the process exits.
    static let gracePeriod: TimeInterval = 2

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: Data, timedOut: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runBlocking(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    timeout: timeout
                ))
            }
        }
    }

    /// Runs the process on the calling thread. Stdout is drained by a readability
    /// handler while the process runs, so a large output cannot fill the pipe and
    /// block the child. Stdin and stderr are the null device. On timeout the
    /// process gets `terminate()`, then SIGKILL after `gracePeriod`. A launch
    /// failure returns exit code -1.
    static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) -> (exitCode: Int32, stdout: Data, timedOut: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.finish()
            } else {
                collector.append(chunk)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, Data(), false)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + gracePeriod) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + gracePeriod)
            }
        }

        // A child the CLI spawned can keep the pipe open past exit; do not wait on it forever.
        collector.waitForEnd(timeout: gracePeriod)
        pipe.fileHandleForReading.readabilityHandler = nil

        let exitCode: Int32 = process.isRunning ? -1 : process.terminationStatus
        return (exitCode, collector.data, timedOut)
    }
}

/// Thread-safe stdout buffer filled from the pipe's readability handler.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let ended = DispatchSemaphore(value: 0)

    nonisolated func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    nonisolated func finish() {
        ended.signal()
    }

    nonisolated func waitForEnd(timeout: TimeInterval) {
        _ = ended.wait(timeout: .now() + timeout)
    }

    nonisolated var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
