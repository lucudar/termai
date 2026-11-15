import XCTest
@testable import TermCore

final class AnthropicTests: XCTestCase {
    func testRequestShape() throws {
        let history = [
            ChatMessage(role: .system, content: "be brief"),
            ChatMessage(role: .user, content: "look", images: ["data:image/png;base64,AAAA"]),
            ChatMessage(role: .assistant, content: "checking",
                        toolCalls: [ToolCall(id: "t1", name: "read_file", arguments: #"{"path":"a"}"#)],
                        reasoning: [ReasoningBlock(text: "hmm", signature: "sig")]),
            ChatMessage(role: .tool, content: "file text", toolCallID: "t1"),
        ]
        let request = ChatRequest(
            baseURL: "https://api.anthropic.com/v1", apiKey: "k", model: "claude-x", messages: history,
            tools: [ToolSpec(name: "read_file", description: "read", parametersJSON: #"{"type":"object"}"#)],
            authScheme: .xAPIKey, effort: .xhigh, format: .anthropic, maxTokens: 4_000)
        let urlRequest = try AnthropicClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "be brief")
        XCTAssertEqual((body["max_tokens"] as? NSNumber)?.intValue, 4_000)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "xhigh")
        XCTAssertNil(body["reasoning_effort"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "read_file")
        XCTAssertEqual((tools.first?["input_schema"] as? [String: Any])?["type"] as? String, "object")

        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let prompt = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(prompt.map { $0["type"] as? String }, ["image", "text"])
        XCTAssertEqual((prompt[0]["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        let reply = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(reply.map { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(reply[0]["signature"] as? String, "sig")
        XCTAssertEqual((reply[2]["input"] as? [String: Any])?["path"] as? String, "a")
        let result = try XCTUnwrap(messages[2]["content"] as? [[String: Any]])
        XCTAssertEqual(result.first?["type"] as? String, "tool_result")
        XCTAssertEqual(result.first?["tool_use_id"] as? String, "t1")

        // Auto effort sends nothing, so the model's default applies.
        var auto = request
        auto.effort = nil
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: try AnthropicClient.body(for: auto)) as? [String: Any])
        XCTAssertNil(plain["output_config"])
    }

    func testEarlierThinkingStaysOutAndTurnsMerge() throws {
        let history = [
            ChatMessage(role: .assistant, content: "earlier", reasoning: [ReasoningBlock(text: "old", signature: "s0")]),
            ChatMessage(role: .user, content: "next"),
            ChatMessage(role: .user, content: "and more"),
            ChatMessage(role: .assistant, content: ""),
        ]
        let messages = AnthropicClient.messages(from: history)
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let reply = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(reply.map { $0["type"] as? String }, ["text"])
        XCTAssertEqual((messages[2]["content"] as? [[String: Any]])?.count, 2)
    }

    func testStreamDecoding() throws {
        var state = AnthropicClient.StreamState()
        func feed(_ json: String) throws -> [StreamEvent] { try AnthropicClient.decode(json, state: &state) }

        XCTAssertEqual(try feed(#"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":5,"output_tokens":1}}}"#),
                       [.usage(input: 15, output: 1)])
        XCTAssertEqual(try feed(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#), [])
        XCTAssertEqual(try feed(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me see"}}"#),
                       [.reasoning("let me see")])
        XCTAssertEqual(try feed(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#), [])
        XCTAssertEqual(try feed(#"{"type":"content_block_stop","index":0}"#),
                       [.reasoningBlock(ReasoningBlock(text: "let me see", signature: "abc"))])
        XCTAssertEqual(try feed(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#), [])
        XCTAssertEqual(try feed(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}"#), [.text("Hi")])
        XCTAssertEqual(try feed(#"{"type":"content_block_stop","index":1}"#), [])
        XCTAssertEqual(try feed(#"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"t1","name":"grep","input":{}}}"#),
                       [.toolCallDelta(index: 2, id: "t1", name: "grep", arguments: nil)])
        XCTAssertEqual(try feed(#"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"pattern\":"}}"#),
                       [.toolCallDelta(index: 2, id: nil, name: nil, arguments: #"{"pattern":"#)])
        XCTAssertEqual(try feed(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}"#),
                       [.usage(input: 15, output: 42)])
        XCTAssertEqual(try feed(#"{"type":"ping"}"#), [])
        XCTAssertEqual(try feed("not json"), [])
        XCTAssertThrowsError(try feed(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)) { error in
            XCTAssertEqual(error as? StreamError, StreamError(message: "overloaded_error: Overloaded"))
        }
    }

    func testAgentKeepsThinkingBlocksOnTheAssistantMessage() async throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("anthropic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let block = ReasoningBlock(text: "plan", signature: "sig")
        let client = ScriptedClient([
            [.reasoning("plan"), .reasoningBlock(block), .toolCallDelta(index: 1, id: "t1", name: "list_files", arguments: "{}")],
            [.text("done")],
        ])
        let recorder = Recorder()
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil)).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.first?.reasoning, [block])
        XCTAssertEqual(messages.last, ChatMessage(role: .assistant, content: "done"))
        XCTAssertEqual(client.requests[1].messages[1].reasoning, [block])
    }

    func testProfileFormatDefaults() {
        let direct = Profile(name: "a", baseURL: "https://api.anthropic.com/v1")
        XCTAssertEqual(direct.format, .anthropic)
        XCTAssertEqual(direct.auth, .xAPIKey)
        let gateway = Profile(name: "g", baseURL: "https://gw.example.com/v1", authScheme: .bearer, apiFormat: .anthropic)
        XCTAssertEqual(gateway.auth, .bearer)
        let request = gateway.chatRequest(apiKey: "k", model: "m", messages: [])
        XCTAssertEqual(request.format, .anthropic)
        XCTAssertEqual(request.maxTokens, 32_000)
        XCTAssertEqual(Profile(name: "o", baseURL: "https://openrouter.ai/api/v1").format, .openAI)
        XCTAssertEqual(Profile(name: "o", baseURL: "https://openrouter.ai/api/v1").auth, .bearer)
        XCTAssertEqual(AnthropicClient.versioned([HTTPHeader(name: "Anthropic-Version", value: "2026-10-21")]).count, 1)
        XCTAssertEqual(AnthropicClient.versioned([]).first?.value, "2023-06-01")
        // The OpenAI format never sends thinking blocks back.
        let message = ChatMessage(role: .assistant, content: "x", reasoning: [ReasoningBlock(text: "t", signature: "s")])
        XCTAssertNil(OpenAIClient.encodeMessage(message)["reasoning"])
    }
}
