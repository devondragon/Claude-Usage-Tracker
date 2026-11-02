import XCTest
@testable import Claude_Usage

/// Counts runs and records the last request; never launches a process.
private final class FakeRunner: ClaudeProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _lastEnvironment: [String: String]?
    let exitCode: Int32
    let stdout: Data

    init(exitCode: Int32 = 0, stdout: Data = Data(#"{"is_error": false, "result": "ok"}"#.utf8)) {
        self.exitCode = exitCode
        self.stdout = stdout
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var lastEnvironment: [String: String]? { lock.lock(); defer { lock.unlock() }; return _lastEnvironment }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) async -> (exitCode: Int32, stdout: Data, timedOut: Bool) {
        lock.withLock {
            _calls += 1
            _lastEnvironment = environment
        }
        await Task.yield()
        return (exitCode, stdout, false)
    }
}

@MainActor
final class AutoStartSessionServiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        suiteName = "AutoStartSessionServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Monday 2026-11-02 at the given local time, inside the default weekday window when 7 <= hour < 20.
    private func monday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: hour, minute: minute))!
    }

    private func profile() -> Profile {
        var p = Profile(name: "Test")
        p.autoStartSessionEnabled = true
        p.notificationSettings.enabled = false
        return p
    }

    private func closedWindowUsage() -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.weeklyPercentage = 10
        return usage
    }

    private func locator(found: Bool = true) -> ClaudeBinaryLocator {
        ClaudeBinaryLocator(
            candidates: ["/fake/bin/claude"],
            isExecutable: { _ in found },
            shellLookup: { nil }
        )
    }

    private final class Counter { var value = 0 }

    private func makeService(
        runner: FakeRunner,
        locator: ClaudeBinaryLocator? = nil,
        now: Date,
        login: Result<AutoStartLogin, AutoStartSkipReason> = .success(.defaultLogin),
        reads: Counter = Counter(),
        reading: @escaping () -> AutoStartUsageReading
    ) -> AutoStartSessionService {
        AutoStartSessionService(
            runner: runner,
            locator: locator ?? self.locator(),
            now: { now },
            calendar: calendar,
            defaults: defaults,
            loginResolver: { _ in login },
            usageReader: { _, _ in
                reads.value += 1
                await Task.yield()
                return reading()
            }
        )
    }

    // MARK: - Checks

    func testOverlappingChecksPingOnce() async {
        let runner = FakeRunner()
        let usage = closedWindowUsage()
        let service = makeService(runner: runner, now: monday(10)) { .live(usage, hasOpenWindow: false) }
        let p = profile()

        async let first: Void = service.checkProfile(p)
        async let second: Void = service.checkProfile(p)
        _ = await (first, second)

        XCTAssertEqual(runner.calls, 1)
        XCTAssertEqual(AutoStartAttemptStore(defaults: defaults).state(for: p.id)?.attempts, 1)
    }

    func testOutOfScheduleDoesNotReadUsage() async {
        let runner = FakeRunner()
        let reads = Counter()
        let usage = closedWindowUsage()
        let service = makeService(runner: runner, now: monday(6), reads: reads) { .live(usage, hasOpenWindow: false) }

        await service.checkProfile(profile())

        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(runner.calls, 0)
    }

    func testDisabledProfileIsNotChecked() async {
        let runner = FakeRunner()
        let reads = Counter()
        let usage = closedWindowUsage()
        let service = makeService(runner: runner, now: monday(10), reads: reads) { .live(usage, hasOpenWindow: false) }
        var p = profile()
        p.autoStartSessionEnabled = false

        await service.checkProfile(p)

        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(runner.calls, 0)
    }

    func testNoLoginSkipsWithoutReadingUsage() async {
        let runner = FakeRunner()
        let reads = Counter()
        let usage = closedWindowUsage()
        let service = makeService(runner: runner, now: monday(10), login: .failure(.accountMismatch), reads: reads) {
            .live(usage, hasOpenWindow: false)
        }

        await service.checkProfile(profile())

        XCTAssertEqual(reads.value, 0)
        XCTAssertEqual(runner.calls, 0)
    }

    func testUsageFetchFailureDoesNotPingOrCountAttempt() async {
        let runner = FakeRunner()
        let service = makeService(runner: runner, now: monday(10)) { .failed("status 429") }
        let p = profile()

        await service.checkProfile(p)

        XCTAssertEqual(runner.calls, 0)
        XCTAssertNil(AutoStartAttemptStore(defaults: defaults).state(for: p.id))
    }

    func testOpenWindowDoesNotPing() async {
        let runner = FakeRunner()
        let usage = closedWindowUsage()
        let service = makeService(runner: runner, now: monday(10)) { .live(usage, hasOpenWindow: true) }

        await service.checkProfile(profile())

        XCTAssertEqual(runner.calls, 0)
    }

    func testTokenExpiredPings() async {
        let runner = FakeRunner()
        let service = makeService(runner: runner, now: monday(10)) { .tokenExpired }

        await service.checkProfile(profile())

        XCTAssertEqual(runner.calls, 1)
    }

    func testSuccessfulPingSavesResult() async {
        let runner = FakeRunner()
        let usage = closedWindowUsage()
        let now = monday(10)
        let service = makeService(runner: runner, now: now) { .live(usage, hasOpenWindow: false) }
        let p = profile()

        await service.checkProfile(p)

        XCTAssertEqual(AutoStartStatusStore(defaults: defaults).lastResult(for: p.id),
                       AutoStartResult(date: now, success: true, message: nil))
    }

    func testFailedPingSavesMessage() async {
        let runner = FakeRunner(exitCode: 1, stdout: Data())
        let usage = closedWindowUsage()
        let service = makeService(runner: runner, now: monday(10)) { .live(usage, hasOpenWindow: false) }
        let p = profile()

        await service.checkProfile(p)

        let result = AutoStartStatusStore(defaults: defaults).lastResult(for: p.id)
        XCTAssertEqual(result?.success, false)
        XCTAssertEqual(result?.message, "claude exited with code 1")
    }

    func testConfigDirLoginSetsEnvironment() async {
        let runner = FakeRunner()
        let service = makeService(
            runner: runner,
            now: monday(10),
            login: .success(.configDir(path: "/Users/x/.claude-work", keychainService: "Claude Code-credentials-abcd1234"))
        ) { .tokenExpired }

        await service.checkProfile(profile())

        XCTAssertEqual(runner.lastEnvironment?[ClaudeCLIPing.configDirVariable], "/Users/x/.claude-work")
    }

    func testBinaryNotFoundSkipsAndRecordsOncePerDay() async {
        let runner = FakeRunner()
        let service = makeService(runner: runner, locator: locator(found: false), now: monday(10)) { .tokenExpired }
        let p = profile()

        await service.checkProfile(p)

        XCTAssertEqual(runner.calls, 0)
        XCTAssertNil(AutoStartAttemptStore(defaults: defaults).state(for: p.id))
        let result = AutoStartStatusStore(defaults: defaults).lastResult(for: p.id)
        XCTAssertEqual(result?.success, false)
    }

    func testLaunchFailureInvalidatesLocator() async {
        var checks = 0
        let counting = ClaudeBinaryLocator(
            candidates: ["/fake/bin/claude"],
            isExecutable: { _ in checks += 1; return true },
            shellLookup: { nil }
        )
        let runner = FakeRunner(exitCode: -1, stdout: Data())
        let service = makeService(runner: runner, locator: counting, now: monday(10)) { .tokenExpired }
        let p = profile()

        await service.checkProfile(p)
        XCTAssertEqual(checks, 1)

        // The attempt policy waits after a failure, so check a second profile.
        await service.checkProfile(profile())
        XCTAssertEqual(checks, 2, "a launch failure must clear the cached path")
    }

    // MARK: - One-Shot Timer

    func testNextCheckDatePicksEarliest() {
        let now = monday(10)
        let reset = monday(11, 30)
        let date = AutoStartSessionService.nextCheckDate(
            now: now,
            schedules: [.default],
            openWindowResets: [reset],
            calendar: calendar
        )
        XCTAssertEqual(date, reset.addingTimeInterval(30))
    }

    func testNextCheckDateUsesNextStartWhenNoWindowOpen() {
        let date = AutoStartSessionService.nextCheckDate(
            now: monday(10),
            schedules: [.default],
            openWindowResets: [],
            calendar: calendar
        )
        let tuesdaySeven = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 7))!
        XCTAssertEqual(date, tuesdaySeven)
    }

    func testNextCheckDateIsNeverSoonerThanAMinute() {
        let now = monday(10)
        let date = AutoStartSessionService.nextCheckDate(
            now: now,
            schedules: [],
            openWindowResets: [now.addingTimeInterval(-10)],
            calendar: calendar
        )
        XCTAssertEqual(date, now.addingTimeInterval(60))
    }

    func testNextCheckDateNilWithNothingToWaitFor() {
        XCTAssertNil(AutoStartSessionService.nextCheckDate(now: monday(10), schedules: [], openWindowResets: [], calendar: calendar))
    }

    // MARK: - Usage Parsing

    func testParsesResetsAtWithoutFractionalSeconds() throws {
        let json = """
        {"five_hour": {"utilization": 3.0, "resets_at": "2099-11-03T02:10:00+00:00"},
         "seven_day": {"utilization": 12.0, "resets_at": "2099-11-09T10:00:00+00:00"},
         "seven_day_sonnet": {"utilization": 1.0, "resets_at": "2099-11-09T10:00:00+00:00"}}
        """
        let (usage, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(json.utf8))
        XCTAssertTrue(hasOpenWindow)
        XCTAssertEqual(usage.sessionResetTime, ISO8601DateFormatter().date(from: "2099-11-03T02:10:00Z"))
        XCTAssertEqual(usage.weeklyResetTime, ISO8601DateFormatter().date(from: "2099-11-09T10:00:00Z"))
        XCTAssertEqual(usage.sonnetWeeklyResetTime, ISO8601DateFormatter().date(from: "2099-11-09T10:00:00Z"))
    }

    func testParsesResetsAtWithFractionalSeconds() throws {
        let json = """
        {"five_hour": {"utilization": 0.0, "resets_at": "2099-11-03T02:10:00.133519+00:00"},
         "seven_day": {"utilization": 0.0, "resets_at": "2099-11-09T10:00:00.5+00:00"},
         "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2099-11-09T10:00:00.25+00:00"}}
        """
        let (usage, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(json.utf8))
        XCTAssertTrue(hasOpenWindow)
        let expected = ISO8601DateFormatter().date(from: "2099-11-03T02:10:00Z")!
        XCTAssertEqual(usage.sessionResetTime.timeIntervalSince(expected), 0.133519, accuracy: 0.001)
        XCTAssertEqual(usage.weeklyResetTime.timeIntervalSince(ISO8601DateFormatter().date(from: "2099-11-09T10:00:00Z")!), 0.5, accuracy: 0.001)
        XCTAssertNotNil(usage.sonnetWeeklyResetTime)
    }

    func testNullFiveHourResetsAtMeansNoOpenWindow() throws {
        let json = """
        {"five_hour": {"utilization": 0.0, "resets_at": null},
         "seven_day": {"utilization": 0.0, "resets_at": "2099-11-09T10:00:00+00:00"}}
        """
        let (usage, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(json.utf8))
        XCTAssertFalse(hasOpenWindow)
        XCTAssertFalse(usage.hasNoUsageWindows)
    }

    func testUnreadableResetsAtCountsAsOpen() throws {
        let json = #"{"five_hour": {"utilization": 0.0, "resets_at": "next tuesday"}}"#
        let (_, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(json.utf8))
        XCTAssertTrue(hasOpenWindow)
    }

    func testPastResetsAtWithoutFractionsIsNotOpen() throws {
        let json = #"{"five_hour": {"utilization": 0.0, "resets_at": "2020-01-01T00:00:00+00:00"}}"#
        let (_, hasOpenWindow) = try AutoStartSessionService.parseUsageResponse(Data(json.utf8))
        XCTAssertFalse(hasOpenWindow)
    }
}
