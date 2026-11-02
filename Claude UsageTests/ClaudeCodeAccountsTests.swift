import XCTest
@testable import Claude_Usage

final class ClaudeCodeAccountsTests: XCTestCase {

    private var home: URL!
    private let service = ClaudeCodeSyncService.shared

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeAccountsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func oauthJSON(_ email: String, org: String? = nil) -> String {
        let orgPart = org.map { #","organizationName":"\#($0)""# } ?? ""
        return #"{"oauthAccount":{"accountUuid":"uuid-\#(email)","emailAddress":"\#(email)"\#(orgPart)}}"#
    }

    /// Creates `~/.claude-<suffix>/.claude.json` and returns the keychain service Claude Code uses for it.
    @discardableResult
    private func makeDir(_ name: String, email: String?, org: String? = nil) throws -> String {
        let dir = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let email {
            try oauthJSON(email, org: org).write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        }
        return "Claude Code-credentials-\(service.sha256HexPrefix(dir.path, length: 8))"
    }

    // MARK: - Discovery

    func testDiscoversDefaultAndNamedDirsThatHaveKeychainEntries() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try oauthJSON("me@example.com").write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let tribe = try makeDir(".claude-tribe", email: "me@tribe.example", org: "Tribe")
        let lumena = try makeDir(".claude-lumena", email: "me@lumena.example")

        let accounts = service.discoverConfigDirAccounts(
            homePath: home.path,
            existingServices: ["Claude Code-credentials", tribe, lumena]
        )

        XCTAssertEqual(accounts.map(\.directoryName), [".claude", ".claude-lumena", ".claude-tribe"])
        XCTAssertEqual(accounts.first?.serviceName, "Claude Code-credentials")
        let tribeAccount = try XCTUnwrap(accounts.first { $0.serviceName == tribe })
        XCTAssertEqual(tribeAccount.emailAddress, "me@tribe.example")
        XCTAssertEqual(tribeAccount.organizationName, "Tribe")
        XCTAssertEqual(tribeAccount.slug, "tribe")
    }

    func testSkipsDirsWithoutKeychainEntryOrAccount() throws {
        try makeDir(".claude-loggedout", email: "gone@example.com")
        try makeDir(".claude-noaccount", email: nil)
        let noAccountService = "Claude Code-credentials-\(service.sha256HexPrefix(home.appendingPathComponent(".claude-noaccount").path, length: 8))"

        let accounts = service.discoverConfigDirAccounts(homePath: home.path, existingServices: [noAccountService])

        XCTAssertTrue(accounts.isEmpty)
    }

    func testPinnedProfileCountsAsHavingUsageCredentials() {
        var profile = Profile(name: "Tribe")
        XCTAssertFalse(profile.hasUsageCredentials)
        profile.customKeychainServiceName = "Claude Code-credentials-20386361"
        XCTAssertTrue(profile.hasUsageCredentials)
    }

    // MARK: - Matching

    private func account(_ dir: String, email: String) -> ClaudeCodeSyncService.ConfigDirAccount {
        ClaudeCodeSyncService.ConfigDirAccount(
            directoryPath: "/home/\(dir)",
            serviceName: "svc-\(dir)",
            emailAddress: email,
            organizationName: nil,
            accountUuid: nil,
            oauthAccountJSON: "{}"
        )
    }

    func testMatchesByEmailThenBySlug() {
        let tribe = account(".claude-tribe", email: "me@tribe.example")
        let lumena = account(".claude-lumena", email: "me@lumena.example")
        let byEmail = Profile(name: "Work", oauthAccountJSON: #"{"emailAddress":"ME@tribe.example"}"#)
        let bySlug = Profile(name: "Lumena")

        let matches = ClaudeCodeSyncService.matchProfiles([byEmail, bySlug], to: [tribe, lumena])

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.first { $0.profileId == byEmail.id }?.account, tribe)
        XCTAssertEqual(matches.first { $0.profileId == bySlug.id }?.account, lumena)
    }

    func testSkipsAmbiguousEmailAndAlreadyLinkedDirs() {
        let main = account(".claude", email: "me@example.com")
        let mcf = account(".claude-mcf", email: "me@example.com")
        let tribe = account(".claude-tribe", email: "me@tribe.example")
        let ambiguous = Profile(name: "Personal", oauthAccountJSON: #"{"emailAddress":"me@example.com"}"#)
        var alreadyLinked = Profile(name: "Other")
        alreadyLinked.customKeychainServiceName = tribe.serviceName
        let wantsTribe = Profile(name: "Tribe")

        let matches = ClaudeCodeSyncService.matchProfiles([ambiguous, alreadyLinked, wantsTribe], to: [main, mcf, tribe])

        XCTAssertTrue(matches.isEmpty)
    }
}
