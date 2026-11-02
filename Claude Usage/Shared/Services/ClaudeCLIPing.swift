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
        guard let profileIdentity = accountIdentity(profileAccountJSON),
              let defaultIdentity = accountIdentity(defaultAccountJSON),
              profileIdentity == defaultIdentity else {
            return .failure(.accountMismatch)
        }
        return .success(.defaultLogin)
    }

    /// `accountUuid` of an `oauthAccount` JSON object, falling back to `emailAddress`.
    private static func accountIdentity(_ json: String?) -> String? {
        guard let data = json?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let uuid = obj["accountUuid"] as? String, !uuid.isEmpty { return uuid }
        if let email = obj["emailAddress"] as? String, !email.isEmpty { return email }
        return nil
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

    /// `base` with `CLAUDE_CONFIG_DIR` set for a config-dir login and removed for
    /// the default login, so an inherited value never picks the wrong account.
    static func environment(for login: AutoStartLogin, base: [String: String]) -> [String: String] {
        var env = base
        switch login {
        case .defaultLogin:
            env.removeValue(forKey: configDirVariable)
        case .configDir(let path, _):
            env[configDirVariable] = path
        }
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
/// login shell's `command -v claude`. A found path is cached until `invalidate()`;
/// a miss is not cached, so a later install is picked up on the next check.
nonisolated struct ClaudeBinaryLocator {

    static let defaultCandidates: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
    }()

    static let shellLookupTimeout: TimeInterval = 10

    private let candidates: [String]
    private let isExecutable: (String) -> Bool
    private let shellLookup: () -> String?
    private var cachedPath: String?

    init(candidates: [String], isExecutable: @escaping (String) -> Bool, shellLookup: @escaping () -> String?) {
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.shellLookup = shellLookup
    }

    /// The production locator: default candidates, real file checks, login-shell lookup.
    static func live() -> ClaudeBinaryLocator {
        ClaudeBinaryLocator(
            candidates: defaultCandidates,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
            shellLookup: loginShellLookup
        )
    }

    mutating func locate() -> String? {
        if let cachedPath { return cachedPath }
        let found = candidates.first(where: isExecutable)
            ?? shellLookup().flatMap { isExecutable($0) ? $0 : nil }
        cachedPath = found
        return found
    }

    mutating func invalidate() {
        cachedPath = nil
    }

    /// Runs `$SHELL -lc 'command -v claude'` so a PATH set in the user's login
    /// profile is honored. Takes the last output line that is an absolute path,
    /// since login profiles can print banners first.
    static func loginShellLookup() -> String? {
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

protocol ClaudeProcessRunning {
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
