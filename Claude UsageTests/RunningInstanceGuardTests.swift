import XCTest
@testable import Claude_Usage

/// One copy of the app runs at a time, and the upstream app is recognized so
/// the user can be warned about it.
final class RunningInstanceGuardTests: XCTestCase {

    private let ownID = "com.devondragon.ClaudeUsage"

    func testFindsAnotherCopyOfThisApp() {
        let apps: [(bundleID: String?, pid: pid_t)] = [
            (bundleID: "com.apple.finder", pid: 10),
            (bundleID: ownID, pid: 20),
            (bundleID: ownID, pid: 30),
        ]
        XCTAssertEqual(RunningInstanceGuard.otherCopy(in: apps, ownBundleID: ownID, ownPID: 30), 20)
    }

    func testOwnProcessAloneIsNotAnotherCopy() {
        let apps: [(bundleID: String?, pid: pid_t)] = [(bundleID: ownID, pid: 30), (bundleID: nil, pid: 40)]
        XCTAssertNil(RunningInstanceGuard.otherCopy(in: apps, ownBundleID: ownID, ownPID: 30))
    }

    func testUpstreamAppIsNotAnotherCopyButIsRecognized() {
        let apps: [(bundleID: String?, pid: pid_t)] = [
            (bundleID: "HamedElfayome.Claude-Usage", pid: 50),
            (bundleID: ownID, pid: 30),
        ]
        XCTAssertNil(RunningInstanceGuard.otherCopy(in: apps, ownBundleID: ownID, ownPID: 30))
        XCTAssertTrue(RunningInstanceGuard.isUpstreamApp(bundleID: "HamedElfayome.Claude-Usage"))
        XCTAssertFalse(RunningInstanceGuard.isUpstreamApp(bundleID: ownID))
        XCTAssertFalse(RunningInstanceGuard.isUpstreamApp(bundleID: nil))
    }
}
