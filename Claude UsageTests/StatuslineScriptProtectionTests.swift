import XCTest
@testable import Claude_Usage

/// The installed statusline script is rewritten only when it changed, and a
/// hand-edited copy is recognised so it can be backed up first (#321).
final class StatuslineScriptProtectionTests: XCTestCase {

    func testIdenticalScriptIsNotRewritten() {
        XCTAssertFalse(StatuslineService.shouldWriteBashScript(installed: "echo hi\n", new: "echo hi\n"))
    }

    func testChangedOrMissingScriptIsWritten() {
        XCTAssertTrue(StatuslineService.shouldWriteBashScript(installed: "echo old\n", new: "echo new\n"))
        XCTAssertTrue(StatuslineService.shouldWriteBashScript(installed: nil, new: "echo new\n"))
    }

    func testScriptThisAppWroteIsNotTreatedAsEdited() {
        let shipped = "echo shipped\n"
        let fingerprint = StatuslineService.contentFingerprint(shipped)
        XCTAssertFalse(StatuslineService.isUserEdited(installed: shipped, lastWrittenFingerprint: fingerprint))
    }

    func testHandEditedScriptIsDetected() {
        let fingerprint = StatuslineService.contentFingerprint("echo shipped\n")
        XCTAssertTrue(StatuslineService.isUserEdited(installed: "echo shipped\necho mine\n", lastWrittenFingerprint: fingerprint))
    }

    func testUnknownHistoryCountsAsEdited() {
        XCTAssertTrue(StatuslineService.isUserEdited(installed: "echo anything\n", lastWrittenFingerprint: nil))
    }

    // MARK: - A statusline of the user's own at the same path

    @MainActor
    func testShippedScriptIsRecognizedAsTheApps() {
        XCTAssertTrue(StatuslineService.isAppScript(StatuslineService.shared.bashScript))
    }

    func testUsersOwnScriptIsNotTheApps() {
        let own = "#!/bin/bash\n# Powerline-styled status line\ninput=$(cat)\nprintf '%s' \"$input\" | jq -r .model\n"
        XCTAssertFalse(StatuslineService.isAppScript(own))
    }

    func testSettingsCommandDetection() {
        XCTAssertTrue(StatuslineService.statusLineUsesOurScript(
            ["statusLine": ["type": "command", "command": "bash /Users/me/.claude/statusline-command.sh"]]
        ))
        XCTAssertFalse(StatuslineService.statusLineUsesOurScript(
            ["statusLine": ["type": "command", "command": "\"/Users/me/.claude-tribe/hooks/tribe-statusline.sh\""]]
        ))
        XCTAssertFalse(StatuslineService.statusLineUsesOurScript([:]))
    }

    func testBackupNamesAreTimestamped() {
        let first = StatuslineService.backupFileName(for: Date(timeIntervalSince1970: 1_800_000_000))
        let second = StatuslineService.backupFileName(for: Date(timeIntervalSince1970: 1_800_000_001))
        XCTAssertTrue(first.hasPrefix("statusline-command.sh.backup-"))
        XCTAssertNotEqual(first, second)
    }
}
