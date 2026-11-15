import XCTest
@testable import TermCore

final class PlanTests: XCTestCase {
    func testReadsPlansLeniently() {
        let json = #"{"plan":[{"step":"Read the code","status":"completed"},{"step":"Fix the bug","status":"in-progress"},{"content":"Run the tests","status":"todo"},"Ship it"]}"#
        XCTAssertEqual(Plan.steps(fromArguments: json), [
            PlanStep("Read the code", .completed),
            PlanStep("Fix the bug", .inProgress),
            PlanStep("Run the tests", .pending),
            PlanStep("Ship it", .pending),
        ])
        XCTAssertNil(Plan.steps(fromArguments: "{}"))
        XCTAssertNil(Plan.steps(fromArguments: "not json"))
        XCTAssertNil(Plan.steps(fromArguments: #"{"plan":[]}"#))
    }

    func testRenderAndParseRoundTrip() {
        let steps = [PlanStep("one", .completed), PlanStep("two", .inProgress), PlanStep("three")]
        let text = Plan.render(steps)
        XCTAssertEqual(text, "[x] one\n[>] two\n[ ] three")
        XCTAssertEqual(Plan.parse(text), steps)
        XCTAssertEqual(Plan.summary(steps), "plan 1/3")
    }

    func testSpecIsAValidSchema() throws {
        let object = try JSONSerialization.jsonObject(with: Data(Plan.spec.parametersJSON.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "object")
        XCTAssertNotNil((object?["properties"] as? [String: Any])?["plan"])
    }

    func testBadPlanIsAnError() {
        let result = Plan.run(ToolCall(id: "p", name: Plan.toolName, arguments: #"{"plan":"soon"}"#))
        XCTAssertTrue(result.isError)
    }

    func testAgentKeepsThePlanWithoutAsking() async throws {
        let arguments = #"{"plan":[{"step":"Look around","status":"in_progress"},{"step":"Change it","status":"pending"}]}"#
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "p1", name: Plan.toolName, arguments: arguments)],
            [.text("done")],
        ])
        let recorder = Recorder()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)")
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m",
                                 messages: [ChatMessage(role: .user, content: "a big job")]),
            approve: { _, _ in
                XCTFail("a plan update must not ask for approval")
                return .deny
            },
            emit: { await recorder.record($0) })

        XCTAssertTrue(client.requests[0].tools.contains { $0.name == Plan.toolName })
        XCTAssertEqual(client.requests[0].tools.filter { $0.name == Plan.toolName }.count, 1)
        let finished = await recorder.finished
        XCTAssertEqual(finished.count, 1)
        XCTAssertFalse(finished[0].result.isError)
        XCTAssertEqual(finished[0].result.text, "[>] Look around\n[ ] Change it")
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
    }
}
