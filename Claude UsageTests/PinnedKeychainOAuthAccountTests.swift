import XCTest
@testable import Claude_Usage

/// #355: a profile pinned to a hashed keychain entry must capture the
/// `oauthAccount` of the config dir that owns that entry, never the default one.
final class PinnedKeychainOAuthAccountTests: XCTestCase {

    private var home: URL!
    private let service = ClaudeCodeSyncService.shared

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinnedKeychainOAuthAccountTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeConfigDir(_ name: String, email: String) throws -> String {
        let dir = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"accountUuid":"uuid-\#(email)","emailAddress":"\#(email)"},"other":1}"#
        try json.write(to: dir.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        return dir.path
    }

    func testReadsOAuthAccountFromTheDirThatOwnsTheHashedEntry() throws {
        _ = try makeConfigDir(".claude-personal", email: "personal@example.com")
        let workDir = try makeConfigDir(".claude-work", email: "work@example.com")
        let workService = "Claude Code-credentials-\(service.sha256HexPrefix(workDir, length: 8))"

        let account = service.readOAuthAccount(forKeychainService: workService, homePath: home.path)

        XCTAssertEqual(service.accountIdentity(fromOAuthAccountJSON: account), "uuid-work@example.com")
    }

    func testOnlyNonDefaultPinsCountAsConfigDirPins() {
        var profile = Profile(name: "P")
        XCTAssertNil(service.pinnedConfigDirService(of: profile))

        profile.customKeychainServiceName = "Claude Code-credentials"
        XCTAssertNil(service.pinnedConfigDirService(of: profile))

        profile.customKeychainServiceName = "Claude Code-credentials-1a2b3c4d"
        XCTAssertEqual(service.pinnedConfigDirService(of: profile), "Claude Code-credentials-1a2b3c4d")
    }

    func testUnknownHashedEntryReturnsNil() throws {
        _ = try makeConfigDir(".claude-work", email: "work@example.com")

        let account = service.readOAuthAccount(forKeychainService: "Claude Code-credentials-00000000", homePath: home.path)

        XCTAssertNil(account)
    }

    func testDefaultLoginAccountReadsHomeClaudeJSON() throws {
        let json = #"{"oauthAccount":{"accountUuid":"uuid-default","emailAddress":"default@example.com"}}"#
        try json.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        // A config dir elsewhere must not be read for the default login.
        _ = try makeConfigDir(".claude-work", email: "work@example.com")

        let account = service.readDefaultLoginOAuthAccount(homePath: home.path)

        XCTAssertEqual(service.accountIdentity(fromOAuthAccountJSON: account), "uuid-default")
    }

    func testDefaultLoginAccountIsNilWithoutHomeClaudeJSON() throws {
        _ = try makeConfigDir(".claude", email: "nested@example.com")

        XCTAssertNil(service.readDefaultLoginOAuthAccount(homePath: home.path))
    }
}
