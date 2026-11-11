import XCTest
@testable import Claude_Usage

final class UsageCostResponseTests: XCTestCase {

    // MARK: - Org-level usage_cost decoding

    /// Shape returned by the org-level `usage_cost` endpoint: entries from several
    /// workspaces, plus top-level keys the app does not model.
    func testDecodesOrgLevelResponseAcrossWorkspaces() throws {
        let json = """
        {
          "workspace_labels": {"wrkspc_1": {"name": "Other", "archived": false}},
          "costs": {
            "2026-11-11": [
              {"workspace_id": "default", "key_id": "apikey_a", "key_name": "Alpha",
               "model_name": "Claude Sonnet 5.5", "total": 20.5, "token_type": "input_no_cache",
               "usage_type": "message"},
              {"workspace_id": "wrkspc_1", "key_id": "apikey_b", "key_name": "Beta",
               "model_name": "Claude Haiku 4.5", "total": 4.0}
            ]
          },
          "web_search_costs": {},
          "code_execution_costs": {},
          "session_usage_costs": {},
          "claude_code_savings": {}
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(ClaudeAPIService.UsageCostResponse.self, from: json)
        let entries = try XCTUnwrap(response.costs?["2026-11-11"])

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.workspaceId)), ["default", "wrkspc_1"])
        XCTAssertEqual(entries.map(\.keyName), ["Alpha", "Beta"])
        XCTAssertEqual(entries.reduce(0) { $0 + $1.safeTotal }, 24.5, accuracy: 0.0001)
    }

    func testKeyNameIsOptional() throws {
        let json = #"{"costs": {"2026-11-01": [{"key_id": "apikey_a", "total": 1.0}]}}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(ClaudeAPIService.UsageCostResponse.self, from: json)
        XCTAssertNil(response.costs?["2026-11-01"]?.first?.keyName)
    }
}
