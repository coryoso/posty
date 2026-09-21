import Foundation
import Testing
@testable import Posty

struct CodexBridgeTests {
    @Test func turnStartUsesCodexThreadIDKey() throws {
        let params = TurnStartParams(
            effort: "low",
            input: [CodexInput(type: "text", text: "select 1")],
            model: "gpt-5.6-luna",
            outputSchema: .object(["type": .string("object")]),
            threadID: "thread-test"
        )
        let data = try JSONEncoder().encode(params)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["threadId"] as? String == "thread-test")
        #expect(object["threadID"] == nil)
    }

    @Test func liveAzureAppServerSmokeTest() async throws {
        guard ProcessInfo.processInfo.environment["POSTY_CODEX_SMOKE"] == "1" else { return }
        let bridge = CodexBridge()
        do {
            let proposal = try await bridge.proposeSQL(
                instruction: "Return a query that selects the answer 42 as answer.",
                sql: "SELECT 1;",
                schemaContext: "No database objects are needed for this query.",
                selectedValues: nil,
                model: .luna
            )
            await bridge.stop()
            #expect(proposal.sql.localizedCaseInsensitiveContains("select"))
            #expect(proposal.sql.contains("42"))
        } catch {
            await bridge.stop()
            throw error
        }
    }
}
