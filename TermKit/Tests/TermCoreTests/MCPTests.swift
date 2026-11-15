import XCTest
@testable import TermCore

final class MCPTests: XCTestCase {
    private func object(_ json: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
    }

    func testResponsesFromJSONAndSSE() throws {
        let json = Data(#"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#.utf8)
        XCTAssertNotNil(try MCPClient.response(id: 3, data: json, contentType: "application/json")["result"])
        XCTAssertThrowsError(try MCPClient.response(id: 9, data: json, contentType: "application/json"))

        let sse = Data(("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n"
                        + ": keep-alive\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"ok\":true}}\n\n").utf8)
        let streamed = try MCPClient.response(id: 7, data: sse, contentType: "text/event-stream; charset=utf-8")
        XCTAssertEqual((streamed["result"] as? [String: Any])?["ok"] as? Bool, true)

        let failure = try MCPClient.response(id: 2, data: Data(#"{"jsonrpc":"2.0","id":2,"error":{"code":-32602,"message":"bad"}}"#.utf8),
                                             contentType: "application/json")
        XCTAssertEqual((failure["error"] as? [String: Any])?["message"] as? String, "bad")
    }

    func testToolsAndResults() {
        let tool = MCPClient.tool(object(#"{"name":"read_wiki","description":"Reads a wiki","inputSchema":{"type":"object","properties":{"repo":{"type":"string"}}},"annotations":{"readOnlyHint":true}}"#))
        XCTAssertEqual(tool?.name, "read_wiki")
        XCTAssertEqual(tool?.readOnly, true)
        XCTAssertTrue(tool?.inputSchemaJSON.contains("\"repo\"") ?? false)
        XCTAssertEqual(MCPClient.tool(object(#"{"name":"plain"}"#))?.readOnly, false)
        XCTAssertNil(MCPClient.tool(object(#"{"description":"no name"}"#)))

        let result = MCPClient.toolResult(object(#"{"content":[{"type":"text","text":"hello"},{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"resource","resource":{"uri":"file:///a","text":"inside"}}],"isError":true}"#))
        XCTAssertEqual(result.text, "hello\n[image image/png, 3 bytes]\ninside")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(MCPClient.toolResult(object(#"{"structuredContent":{"b":1,"a":2}}"#)).text, #"{"a":2,"b":1}"#)
        XCTAssertEqual(MCPClient.toolResult([:]).text, "(no output)")
        XCTAssertFalse(MCPClient.toolResult([:]).isError)
    }

    func testClientRejectsBadURLs() {
        XCTAssertThrowsError(try MCPClient(url: "not a url"))
        XCTAssertThrowsError(try MCPClient(url: "ftp://example.com/mcp"))
        XCTAssertNoThrow(try MCPClient(url: " https://mcp.deepwiki.com/mcp "))
    }

    func testExposedNames() {
        XCTAssertEqual(RemoteTool.exposedName(connector: "Deep Wiki", tool: "read_wiki.contents", taken: []),
                       "mcp_deep_wiki_read_wiki_contents")
        XCTAssertEqual(RemoteTool.exposedName(connector: "c", tool: String(repeating: "x", count: 100), taken: []).count, 64)
        XCTAssertEqual(RemoteTool.exposedName(connector: "a", tool: "t", taken: ["mcp_a_t"]), "mcp_a_t_2")
    }

    func testToolSetRoutesNamesAndApprovals() throws {
        let client = try MCPClient(url: "https://example.com/mcp")
        let reader = RemoteTool(exposedName: "mcp_wiki_read", connectorName: "wiki",
                                tool: MCPTool(name: "read", description: "Reads", readOnly: true), client: client)
        let writer = RemoteTool(exposedName: "mcp_wiki_write", connectorName: "wiki", tool: MCPTool(name: "write"), client: client)
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("toolset-\(UUID().uuidString)")
        let tools = ToolSet(base: ToolBox(workspace: workspace, shell: nil), remote: [reader, writer])
        XCTAssertTrue(tools.specs.contains { $0.name == "mcp_wiki_read" && $0.description == "[wiki connector] Reads" })
        XCTAssertTrue(tools.specs.contains { $0.name == "read_file" })
        XCTAssertFalse(tools.needsApproval(ToolCall(id: "1", name: "mcp_wiki_read", arguments: "{}")))
        XCTAssertTrue(tools.needsApproval(ToolCall(id: "2", name: "mcp_wiki_write", arguments: "{}")))
        XCTAssertEqual(tools.summary(ToolCall(id: "3", name: "mcp_wiki_read", arguments: #"{"q":1}"#)), "wiki \u{00B7} read {\"q\":1}")
        XCTAssertTrue(ToolSet.argumentsPreview(ToolCall(id: "4", name: "mcp_wiki_write", arguments: #"{"b":1}"#))?.contains("\"b\"") ?? false)
        XCTAssertNil(ToolSet.argumentsPreview(ToolCall(id: "5", name: "read_file", arguments: #"{"path":"a"}"#)))
    }

    func testConnectorsRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("connectors-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Storage(directory: directory)
        XCTAssertEqual(storage.loadConnectors(), [])
        let connector = Connector(name: "wiki", url: "https://mcp.deepwiki.com/mcp", enabled: false)
        storage.saveConnectors([connector])
        XCTAssertEqual(storage.loadConnectors(), [connector])
        XCTAssertFalse(connector.isEnabled)
        XCTAssertTrue(Connector(name: "x", url: "https://x").isEnabled)
    }

    /// Talks to a real server when `TERMAI_MCP_URL` is set; CI points it at DeepWiki.
    func testLiveServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["TERMAI_MCP_URL"] else { throw XCTSkip("set TERMAI_MCP_URL to try a real server") }
        let client = try MCPClient(url: url, token: environment["TERMAI_MCP_TOKEN"] ?? "")
        let tools = try await client.listTools()
        print("MCP tools: " + tools.map(\.name).joined(separator: ", "))
        XCTAssertFalse(tools.isEmpty)
        if let name = environment["TERMAI_MCP_CALL"] {
            let result = try await client.callTool(name, argumentsJSON: environment["TERMAI_MCP_ARGS"] ?? "{}")
            print("MCP call \(name): " + String(result.text.prefix(400)))
            XCTAssertFalse(result.isError)
        }
    }
}
