import XCTest
@testable import Claude_Usage

final class UpstreamSettingsImporterTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UpstreamSettingsImporterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCopiesSettingsAndSkipsSparkleAndHeartbeatKeys() {
        let source: [String: Any] = [
            "profiles_v3": Data([1, 2, 3]),
            "activeProfileId": "ABC",
            "notchHUDPathToken": "token",
            "SULastCheckTime": Date(),
            "SUHasLaunchedBefore": true,
            "heartbeat.lastPingDate": Date()
        ]

        let copied = UpstreamSettingsImporter.importIfNeeded(from: source, into: defaults)

        XCTAssertEqual(copied, 3)
        XCTAssertEqual(defaults.data(forKey: "profiles_v3"), Data([1, 2, 3]))
        XCTAssertEqual(defaults.string(forKey: "activeProfileId"), "ABC")
        XCTAssertEqual(defaults.string(forKey: "notchHUDPathToken"), "token")
        XCTAssertNil(defaults.object(forKey: "SULastCheckTime"))
        XCTAssertNil(defaults.object(forKey: "SUHasLaunchedBefore"))
        XCTAssertNil(defaults.object(forKey: "heartbeat.lastPingDate"))
        XCTAssertTrue(defaults.bool(forKey: UpstreamSettingsImporter.importedFlagKey))
    }

    func testRunsOnlyOnce() {
        UpstreamSettingsImporter.importIfNeeded(from: ["activeProfileId": "first"], into: defaults)
        defaults.removeObject(forKey: "activeProfileId")

        let copied = UpstreamSettingsImporter.importIfNeeded(from: ["activeProfileId": "second"], into: defaults)

        XCTAssertEqual(copied, 0)
        XCTAssertNil(defaults.string(forKey: "activeProfileId"))
    }

    func testDoesNotOverwriteExistingProfiles() {
        defaults.set(Data([9]), forKey: "profiles_v3")

        let copied = UpstreamSettingsImporter.importIfNeeded(
            from: ["profiles_v3": Data([1]), "activeProfileId": "ABC"],
            into: defaults
        )

        XCTAssertEqual(copied, 0)
        XCTAssertEqual(defaults.data(forKey: "profiles_v3"), Data([9]))
        XCTAssertNil(defaults.string(forKey: "activeProfileId"))
        XCTAssertTrue(defaults.bool(forKey: UpstreamSettingsImporter.importedFlagKey))
    }

    func testMissingUpstreamDomainMarksImportDone() {
        let copied = UpstreamSettingsImporter.importIfNeeded(from: nil, into: defaults)

        XCTAssertEqual(copied, 0)
        XCTAssertTrue(defaults.bool(forKey: UpstreamSettingsImporter.importedFlagKey))
    }
}
