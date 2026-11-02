import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeCLIPingTests: XCTestCase {

    private let accountA = #"{"accountUuid":"uuid-a","emailAddress":"a@example.com","organizationName":"A"}"#
    private let accountB = #"{"accountUuid":"uuid-b","emailAddress":"b@example.com","organizationName":"B"}"#

    private func resolve(
        custom: String? = nil,
        profile: String? = nil,
        defaultAccount: String? = nil,
        hasCli: Bool = true,
        configDirPath: @escaping (String) -> String? = { _ in nil }
    ) -> Result<AutoStartLogin, AutoStartSkipReason> {
        ClaudeCLIPing.resolveLogin(
            customKeychainService: custom,
            profileAccountJSON: profile,
            defaultAccountJSON: defaultAccount,
            hasCliCredentials: hasCli,
            configDirPath: configDirPath
        )
    }

    // MARK: - Login resolution

    func testLinkedProfileUsesConfigDir() {
        let result = resolve(custom: "Claude Code-credentials-1a2b3c4d", hasCli: false) { service in
            service == "Claude Code-credentials-1a2b3c4d" ? "/Users/x/.claude-work" : nil
        }
        XCTAssertEqual(result, .success(.configDir(path: "/Users/x/.claude-work", keychainService: "Claude Code-credentials-1a2b3c4d")))
    }

    func testLinkedProfileWithUnknownHashIsSkipped() {
        let result = resolve(custom: "Claude Code-credentials-00000000", profile: accountA, defaultAccount: accountA)
        XCTAssertEqual(result, .failure(.noClaudeCodeLogin))
    }

    func testUnlinkedMatchingAccountUsesDefaultLogin() {
        XCTAssertEqual(resolve(profile: accountA, defaultAccount: accountA), .success(.defaultLogin))
    }

    func testUnlinkedFallsBackToEmail() {
        let profile = #"{"emailAddress":"a@example.com"}"#
        let system = #"{"emailAddress":"a@example.com","organizationName":"A"}"#
        XCTAssertEqual(resolve(profile: profile, defaultAccount: system), .success(.defaultLogin))
    }

    func testUnlinkedMismatchIsSkipped() {
        XCTAssertEqual(resolve(profile: accountA, defaultAccount: accountB), .failure(.accountMismatch))
        XCTAssertEqual(resolve(profile: nil, defaultAccount: accountB), .failure(.accountMismatch))
        XCTAssertEqual(resolve(profile: accountA, defaultAccount: nil), .failure(.accountMismatch))
    }

    func testNoCliCredentialsIsSkipped() {
        XCTAssertEqual(resolve(profile: accountA, defaultAccount: accountA, hasCli: false), .failure(.noClaudeCodeLogin))
    }

    func testLegacyServiceNameCountsAsUnlinked() {
        var asked = false
        let result = resolve(custom: "Claude Code-credentials", profile: accountA, defaultAccount: accountA) { _ in
            asked = true
            return "/should/not/be/used"
        }
        XCTAssertEqual(result, .success(.defaultLogin))
        XCTAssertFalse(asked)
    }

    // MARK: - Arguments and environment

    func testArgumentsMatchSpec() {
        XCTAssertEqual(ClaudeCLIPing.arguments, [
            "-p", "ping", "--model", "haiku", "--tools", "", "--strict-mcp-config",
            "--setting-sources", "", "--no-session-persistence",
            "--system-prompt", "Reply with the single word ok.", "--output-format", "json"
        ])
        XCTAssertEqual(ClaudeCLIPing.arguments.filter { $0.isEmpty }.count, 2)
    }

    func testDefaultLoginRemovesConfigDirVariable() {
        let env = ClaudeCLIPing.environment(for: .defaultLogin, base: ["CLAUDE_CONFIG_DIR": "/x", "PATH": "/usr/bin"])
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    func testConfigDirLoginSetsVariable() {
        let login = AutoStartLogin.configDir(path: "/Users/x/.claude-work", keychainService: "Claude Code-credentials-1a2b3c4d")
        let env = ClaudeCLIPing.environment(for: login, base: ["CLAUDE_CONFIG_DIR": "/x", "HOME": "/Users/x"])
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/Users/x/.claude-work")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    // MARK: - Result parsing

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testParseSuccess() {
        let out = data(#"{"type":"result","subtype":"success","is_error":false,"result":"ok"}"#)
        XCTAssertNoThrow(try ClaudeCLIPing.parseResult(exitCode: 0, stdout: out, timedOut: false).get())
    }

    func testParseIsErrorTrue() {
        let longText = String(repeating: "x", count: 500)
        let out = data(#"{"is_error":true,"result":"Invalid API key \#(longText)"}"#)
        guard case .failure(let failure) = ClaudeCLIPing.parseResult(exitCode: 0, stdout: out, timedOut: false) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(failure.message.contains("Invalid API key"))
        XCTAssertLessThanOrEqual(failure.message.count, 260)
    }

    func testParseNonZeroExit() {
        let out = data(#"{"is_error":false,"result":"ok"}"#)
        guard case .failure(let failure) = ClaudeCLIPing.parseResult(exitCode: 1, stdout: out, timedOut: false) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(failure.message.contains("1"))
    }

    func testParseTimeout() {
        guard case .failure(let failure) = ClaudeCLIPing.parseResult(exitCode: 15, stdout: Data(), timedOut: true) else {
            return XCTFail("expected failure")
        }
        XCTAssertTrue(failure.message.contains("timed out"))
    }

    func testParseGarbageStdout() {
        guard case .failure = ClaudeCLIPing.parseResult(exitCode: 0, stdout: data("not json"), timedOut: false) else {
            return XCTFail("expected failure")
        }
    }

    // MARK: - Binary locator

    func testLocatorPicksFirstExecutableCandidate() {
        var shellCalls = 0
        var locator = ClaudeBinaryLocator(
            candidates: ["/a/claude", "/b/claude", "/c/claude"],
            isExecutable: { $0 == "/b/claude" || $0 == "/c/claude" },
            shellLookup: { shellCalls += 1; return "/shell/claude" }
        )
        XCTAssertEqual(locator.locate(), "/b/claude")
        XCTAssertEqual(shellCalls, 0)
    }

    func testLocatorFallsBackToShell() {
        var locator = ClaudeBinaryLocator(
            candidates: ["/a/claude"],
            isExecutable: { $0 == "/shell/claude" },
            shellLookup: { "/shell/claude" }
        )
        XCTAssertEqual(locator.locate(), "/shell/claude")
    }

    func testLocatorCachesResult() {
        var shellCalls = 0
        var locator = ClaudeBinaryLocator(
            candidates: [],
            isExecutable: { _ in true },
            shellLookup: { shellCalls += 1; return "/shell/claude" }
        )
        XCTAssertEqual(locator.locate(), "/shell/claude")
        XCTAssertEqual(locator.locate(), "/shell/claude")
        XCTAssertEqual(shellCalls, 1)
    }

    func testLocatorRetriesAfterInvalidate() {
        var shellCalls = 0
        var answer: String? = nil
        var locator = ClaudeBinaryLocator(
            candidates: [],
            isExecutable: { _ in true },
            shellLookup: { shellCalls += 1; return answer }
        )
        XCTAssertNil(locator.locate())
        answer = "/shell/claude"
        locator.invalidate()
        XCTAssertEqual(locator.locate(), "/shell/claude")
        XCTAssertEqual(shellCalls, 2)
    }

    func testDefaultCandidatesExpandTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClaudeBinaryLocator.defaultCandidates, [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ])
    }

    // MARK: - Config dir lookup

    func testConfigDirPathForHashedService() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCLIPingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude-test")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sync = ClaudeCodeSyncService.shared
        let service = "\(ClaudeCodeSyncService.legacyServiceName)-\(sync.sha256HexPrefix(dir.path, length: 8))"

        XCTAssertEqual(sync.configDirPath(forKeychainService: service, homePath: home.path), dir.path)
        XCTAssertNil(sync.configDirPath(forKeychainService: "Claude Code-credentials-00000000", homePath: home.path))
    }

    // MARK: - Process runner (uses /bin/echo and /bin/sleep only)

    func testRunnerCapturesStdout() async {
        let result = await ClaudeProcessRunner().run(
            executable: "/bin/echo", arguments: ["hello"], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, timeout: 5
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "hello\n")
    }

    func testRunnerReadsOutputLargerThanThePipeBuffer() async {
        let big = String(repeating: "y", count: 200_000)
        let result = await ClaudeProcessRunner().run(
            executable: "/bin/echo", arguments: [big], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, timeout: 5
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout.count, 200_001)
    }

    func testRunnerTimesOut() async {
        let start = Date()
        let result = await ClaudeProcessRunner().run(
            executable: "/bin/sleep", arguments: ["10"], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, timeout: 0.5
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunnerLaunchFailureReturnsMinusOne() async {
        let result = await ClaudeProcessRunner().run(
            executable: "/nonexistent/claude", arguments: [], environment: [:],
            workingDirectory: FileManager.default.temporaryDirectory, timeout: 5
        )
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertFalse(result.timedOut)
    }
}
