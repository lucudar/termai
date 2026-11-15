import XCTest
@testable import TermCore

/// Replays scripted streams, one per model call, and records the requests it received.
final class ScriptedClient: ChatStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[StreamEvent]]
    private(set) var requests: [ChatRequest] = []

    init(_ scripts: [[StreamEvent]]) {
        self.scripts = scripts
    }

    func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = scripts.isEmpty ? [] : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            events.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

struct FakeShell: RemoteShell {
    var label = "box"
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        onOutput("ran: \(command)\n")
        return command.contains("fail") ? 3 : 0
    }
}

#if os(macOS) || os(Linux)
/// Hands commands to the local /bin/sh the way sshd hands them to the login shell, so the remote
/// file scripts run for real against whatever sh, base64, find and grep the test machine has.
struct LocalShell: RemoteShell {
    var label = "local"
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if !data.isEmpty { onOutput(String(decoding: data, as: UTF8.self)) }
        return Int(process.terminationStatus)
    }
}
#endif

actor Recorder {
    var messages: [ChatMessage] = []
    var finished: [(id: String, result: ToolResult, denied: Bool)] = []
    var text = ""
    var reasoning = ""

    func record(_ event: AgentEvent) {
        switch event {
        case .message(let message): messages.append(message)
        case .toolFinished(let id, let result, let denied): finished.append((id, result, denied))
        case .assistantDelta(let delta): text += delta
        case .reasoningDelta(let delta): reasoning += delta
        default: break
        }
    }
}

final class TermCoreTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("termcore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    // MARK: Streaming

    func testSSEParserHandlesSplitChunksAndCRLF() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed(Data("data: {\"a\"".utf8)), [])
        XCTAssertEqual(parser.feed(Data(":1}\r\n\r\ndata:[DONE]\n: comment\nevent: x\n".utf8)), ["{\"a\":1}", "[DONE]"])
    }

    func testSSEParserKeepsMultibyteCharactersSplitAcrossChunks() {
        var parser = SSEParser()
        let bytes = Array("data: héllo ✓\n".utf8)
        XCTAssertEqual(parser.feed(Data(bytes[..<8])), [])
        XCTAssertEqual(parser.feed(Data(bytes[8...])), ["héllo ✓"])
    }

    func testDecodeTextToolCallsAndUsage() {
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"content":"hi"}}]}"#), [.text("hi")])
        XCTAssertEqual(
            OpenAIClient.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"ssh_exec","arguments":"{\"co"}}]}}]}"#),
            [.toolCallDelta(index: 1, id: "c1", name: "ssh_exec", arguments: "{\"co")])
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#),
                       [.usage(input: 12, output: 3)])
        XCTAssertEqual(OpenAIClient.decode("not json"), [])
        // Reasoning comes as reasoning_content or reasoning, ahead of the answer text.
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"reasoning_content":"hmm","content":""}}]}"#), [.reasoning("hmm")])
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"reasoning":"a","content":"b"}}]}"#), [.reasoning("a"), .text("b")])
        XCTAssertEqual(OpenAIClient.decode(#"{"choices":[{"delta":{"reasoning_content":null,"content":"c"}}]}"#), [.text("c")])
    }

    func testRequestBodyAndEndpoint() throws {
        let request = ChatRequest(
            baseURL: "https://example.com/v1/", apiKey: "k", model: "m",
            messages: [
                ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "ssh_exec", arguments: "")]),
                ChatMessage(role: .tool, content: "out", toolCallID: "c1"),
            ],
            tools: ToolBox(workspace: workspace, shell: FakeShell()).specs)
        let urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let call = try XCTUnwrap((messages[0]["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual((call["function"] as? [String: Any])?["arguments"] as? String, "{}")
        XCTAssertEqual(messages[1]["tool_call_id"] as? String, "c1")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 8)
        let schema = (tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")

        XCTAssertThrowsError(try OpenAIClient.endpoint("ftp://x", "/models"))
        XCTAssertThrowsError(try OpenAIClient.endpoint("not a url", "/models"))
    }

    func testAPIErrorExtractsMessage() {
        let error = APIError.from(status: 401, body: Data(#"{"error":{"message":"bad key"}}"#.utf8))
        XCTAssertEqual(error, APIError(status: 401, message: "bad key"))
        XCTAssertEqual(APIError.from(status: 502, body: Data("Bad Gateway".utf8)).message, "Bad Gateway")
    }

    // MARK: Agent

    func testAgentRunsToolThenAnswers() async throws {
        let client = ScriptedClient([
            [.text("checking"),
             .toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":"),
             .toolCallDelta(index: 0, id: nil, name: nil, arguments: "\"uptime\"}")],
            [.text("all good")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "status?")]),
            approve: { _, summary in
                XCTAssertEqual(summary, "ssh box $ uptime")
                return .allow
            },
            emit: { await recorder.record($0) })

        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].toolCalls?.first?.arguments, "{\"command\":\"uptime\"}")
        XCTAssertEqual(messages[1].toolCallID, "c1")
        XCTAssertEqual(messages[1].content, "ran: uptime\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "all good")

        // The second model call must see the tool result.
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertEqual(client.requests[1].messages.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(client.requests[0].tools.first?.name, "ssh_exec")
    }

    func testDeniedToolIsReportedToTheModelAndNotRun() async throws {
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "c1", name: "write_file", arguments: "{\"path\":\"a.txt\",\"content\":\"x\"}")],
            [.text("ok, skipped")],
        ])
        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "write")]),
            approve: { _, _ in .deny },
            emit: { await recorder.record($0) })

        let finished = await recorder.finished
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(finished[0].denied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("a.txt").path))
        let messages = await recorder.messages
        XCTAssertEqual(messages[1].role, .tool)
        XCTAssertTrue(messages[1].content.contains("declined"))
    }

    func testReadOnlyToolsSkipApprovalAndFailedCommandsAreErrors() async throws {
        try Data("hello".utf8).write(to: workspace.appendingPathComponent("note.txt"))
        let client = ScriptedClient([
            [.toolCallDelta(index: 0, id: "", name: "read_file", arguments: "{\"path\":\"note.txt\"}"),
             .toolCallDelta(index: 1, id: "c2", name: "ssh_exec", arguments: "{\"command\":\"fail\"}")],
            [.text("done")],
        ])
        let recorder = Recorder()
        let asked = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { call, _ in
                await asked.record(.assistantDelta(call.name))
                return .allow
            },
            emit: { await recorder.record($0) })

        let askedFor = await asked.text
        XCTAssertEqual(askedFor, "ssh_exec")
        let finished = await recorder.finished
        XCTAssertEqual(finished[0].result, ToolResult(text: "hello"))
        XCTAssertTrue(finished[1].result.isError)
        XCTAssertTrue(finished[1].result.text.hasSuffix("[exit 3]"))
        // A call that arrived without an id still gets one, so its result can be matched.
        let messages = await recorder.messages
        XCTAssertFalse(try XCTUnwrap(messages[0].toolCalls?[0].id).isEmpty)
        XCTAssertEqual(messages[1].toolCallID, messages[0].toolCalls?[0].id)
    }

    func testAgentStopsAfterMaxSteps() async {
        let loop: [StreamEvent] = [.toolCallDelta(index: 0, id: "c", name: "list_files", arguments: "{}")]
        let agent = Agent(client: ScriptedClient([loop, loop, loop]), tools: ToolBox(workspace: workspace, shell: nil), maxSteps: 2)
        do {
            try await agent.run(
                request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
                approve: { _, _ in .allow }, emit: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AgentError, .tooManySteps(2))
        }
    }

    // MARK: Tools

    func testWorkspaceToolsStayInsideWorkspace() async throws {
        let tools = ToolBox(workspace: workspace, shell: nil)
        let write = await tools.run(ToolCall(id: "1", name: "write_file", arguments: #"{"path":"dir/a.txt","content":"abc"}"#)) { _ in }
        XCTAssertEqual(write, ToolResult(text: "wrote 3 bytes"))
        let list = await tools.run(ToolCall(id: "2", name: "list_files", arguments: #"{"path":"dir"}"#)) { _ in }
        XCTAssertEqual(list.text, "a.txt  3")
        let root = await tools.run(ToolCall(id: "3", name: "list_files", arguments: "{}")) { _ in }
        XCTAssertEqual(root.text, "dir/")

        for path in ["../outside.txt", "dir/../../outside.txt", "/../../etc/passwd"] {
            let escaped = await tools.run(ToolCall(id: "4", name: "read_file", arguments: "{\"path\":\"\(path)\"}")) { _ in }
            XCTAssertTrue(escaped.isError, path)
            XCTAssertTrue(escaped.text.contains("outside the workspace"), escaped.text)
        }
        // An absolute-looking path is treated as relative to the workspace root.
        let absolute = await tools.run(ToolCall(id: "5", name: "read_file", arguments: #"{"path":"/dir/a.txt"}"#)) { _ in }
        XCTAssertEqual(absolute.text, "abc")

        let noShell = await tools.run(ToolCall(id: "6", name: "ssh_exec", arguments: #"{"command":"ls"}"#)) { _ in }
        XCTAssertTrue(noShell.isError)
        XCTAssertFalse(tools.specs.contains { $0.name == "ssh_exec" })
    }

    func testSymlinkCannotEscapeWorkspace() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("s.txt"))
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("link"), withDestinationURL: outside)

        let result = await ToolBox(workspace: workspace, shell: nil)
            .run(ToolCall(id: "1", name: "read_file", arguments: #"{"path":"link/s.txt"}"#)) { _ in }
        XCTAssertTrue(result.isError, result.text)
    }

    func testTruncateAndStripHTML() {
        let long = String(repeating: "a", count: 50) + String(repeating: "b", count: 50)
        let cut = Truncate.middle(long, limit: 20)
        XCTAssertTrue(cut.hasPrefix("aaaaaaaaaa\n"))
        XCTAssertTrue(cut.hasSuffix("\nbbbbbbbbbb"))
        XCTAssertTrue(cut.contains("80 characters omitted"))
        XCTAssertEqual(ToolBox.stripHTML("<html><style>p{}</style><p>Tom &amp; Jerry</p><script>x()</script></html>"), "Tom & Jerry")
    }

    func testMarkdownSegmentsAndExport() {
        XCTAssertEqual(Markdown.segments("intro\n\n```sh\nls -la\n\necho hi\n```\nafter"), [
            .init(isCode: false, text: "intro"),
            .init(isCode: true, text: "ls -la\n\necho hi"),
            .init(isCode: false, text: "after"),
        ])
        // A fence still open while streaming renders as code.
        XCTAssertEqual(Markdown.segments("a\n```\nx = 1"), [.init(isCode: false, text: "a"), .init(isCode: true, text: "x = 1")])
        XCTAssertEqual(Markdown.segments(""), [])

        let session = Session(title: "t", transcript: [
            TranscriptItem(kind: .user, text: "hi"), TranscriptItem(kind: .info, text: "noise"),
            TranscriptItem(kind: .thinking, text: "hmm"),
            TranscriptItem(kind: .tool, text: "up 3 days", title: "ssh box $ uptime"), TranscriptItem(kind: .assistant, text: "fine"),
        ])
        XCTAssertEqual(Markdown.export(session), "# t\n\n**❯ hi**\n\n```\nssh box $ uptime\nup 3 days\n```\n\nfine\n")
    }

    func testToolOutputArrivesInOrderBeforeTheResult() async throws {
        struct Chatty: RemoteShell {
            var label = "box"
            func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int {
                for n in 0..<200 { onOutput("\(n),") }
                return 0
            }
        }
        actor Log {
            var entries: [String] = []
            func add(_ entry: String) { entries.append(entry) }
        }
        let log = Log()
        let client = ScriptedClient([[.toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: "{\"command\":\"x\"}")], [.text("ok")]])
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: Chatty())).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
            approve: { _, _ in .allow },
            emit: { event in
                switch event {
                case .toolOutput(_, let chunk): await log.add(chunk)
                case .toolFinished: await log.add("END")
                default: break
                }
            })
        let entries = await log.entries
        XCTAssertEqual(entries, (0..<200).map { "\($0)," } + ["END"])
    }

    // MARK: Commands, storage

    func testCommandParsing() {
        XCTAssertEqual(Commands.parse("  "), .empty)
        XCTAssertEqual(Commands.parse("hello"), .prompt("hello"))
        XCTAssertEqual(Commands.parse("/model  gpt-x "), .command(name: "model", args: "gpt-x"))
        XCTAssertEqual(Commands.parse("/NEW"), .command(name: "new", args: ""))
        XCTAssertEqual(Commands.parse("/etc/hosts looks odd"), .prompt("/etc/hosts looks odd"))
        XCTAssertEqual(Commands.parse("! ls -la"), .shell("ls -la"))
        XCTAssertEqual(Commands.parse("!"), .empty)
        XCTAssertEqual(Commands.suggestions(for: "/se").map(\.name), ["setup", "sessions"])
        XCTAssertEqual(Commands.suggestions(for: "/model x"), [])
        XCTAssertEqual(Commands.suggestions(for: "hi"), [])
    }

    func testStorageRoundTrip() {
        let storage = Storage(directory: workspace)
        let profile = Profile(name: "p", baseURL: "https://x/v1", models: ["a", "b"])
        storage.saveProfiles([profile])
        storage.saveHosts([SSHHost(name: "h", host: "example.com", port: 2222, username: "u", auth: .privateKey,
                                   workingDirectory: "~/app")])
        var settings = AppSettings()
        settings.themeID = "crt-amber"
        settings.approvalMode = .auto
        storage.saveSettings(settings)

        // Whole-second dates: the store keeps ISO 8601 timestamps without fractions.
        let older = Session(title: "older", createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: 100),
                            messages: [ChatMessage(role: .user, content: "1")])
        let newer = Session(title: "newer", createdAt: Date(timeIntervalSince1970: 60), updatedAt: Date(timeIntervalSince1970: 200), messages: [ChatMessage(role: .user, content: "2")],
                            transcript: [TranscriptItem(kind: .tool, text: "out", title: "ssh $ ls", status: .ok)])
        storage.saveSession(older)
        storage.saveSession(newer)
        storage.saveSession(Session())  // empty sessions are not persisted

        let reloaded = Storage(directory: workspace)
        XCTAssertEqual(reloaded.loadProfiles(), [profile])
        XCTAssertEqual(reloaded.loadHosts().first?.address, "u@example.com:2222")
        XCTAssertEqual(reloaded.loadHosts().first?.workingDirectory, "~/app")
        XCTAssertEqual(reloaded.loadSettings(), settings)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["newer", "older"])
        XCTAssertEqual(reloaded.loadSession(id: newer.id), newer)
        reloaded.deleteSession(id: newer.id)
        XCTAssertEqual(reloaded.sessionSummaries().map(\.title), ["older"])
        XCTAssertEqual(Theme.named("nope"), .desktop)
    }

    func testFilesFromVersion01StillLoad() throws {
        let profiles = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"p","baseURL":"https://x/v1","models":["a"]}]"#
        let hosts = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FE","name":"h","host":"x","port":22,"username":"u","auth":"password"}]"#
        let settings = #"{"activeModel":"a","approvalMode":"auto","fontSize":13,"systemPrompt":"","themeID":"crt-amber"}"#
        try Data(profiles.utf8).write(to: workspace.appendingPathComponent("profiles.json"))
        try Data(hosts.utf8).write(to: workspace.appendingPathComponent("hosts.json"))
        try Data(settings.utf8).write(to: workspace.appendingPathComponent("settings.json"))
        let storage = Storage(directory: workspace)
        XCTAssertEqual(storage.loadProfiles().first?.name, "p")
        XCTAssertNil(storage.loadProfiles().first?.contextWindow)
        XCTAssertEqual(storage.loadProfiles().first?.contextLimit, 128_000)
        XCTAssertEqual(storage.loadHosts().first?.name, "h")
        XCTAssertNil(storage.loadHosts().first?.workingDirectory)

        // Gateway options added in 0.3 fall back to the old behaviour.
        let profile = try XCTUnwrap(storage.loadProfiles().first)
        XCTAssertEqual(profile.auth, .bearer)
        XCTAssertEqual(profile.extraHeaders, [])
        XCTAssertEqual(profile.streamTimeout, 300)
        XCTAssertTrue(profile.discovers)
        XCTAssertNil(profile.defaultEffort)
        XCTAssertEqual(profile.pickerModels, ["a"])
        XCTAssertNil(storage.loadHosts().first?.recentDirectories)
        let loaded = storage.loadSettings()
        XCTAssertEqual(loaded.themeID, "crt-amber")
        XCTAssertEqual(loaded.approvalMode, .auto)
        XCTAssertEqual(loaded.fontSize, 13)
        XCTAssertNil(loaded.effort)
        XCTAssertNil(loaded.alwaysStartWithDefault)
    }

    // MARK: Gateways

    func testGatewayOptionsShapeTheRequest() throws {
        var request = ChatRequest(
            baseURL: "https://gw.example.com/v1", apiKey: "k", model: "m",
            messages: [ChatMessage(role: .user, content: "hi")],
            authScheme: .xAPIKey,
            headers: [HTTPHeader(name: " X-Route ", value: "eu"), HTTPHeader(name: "", value: "skipped")],
            effort: .high, idleTimeout: 120)
        var urlRequest = try OpenAIClient.urlRequest(for: request)
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNil(urlRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Route"), "eu")
        XCTAssertEqual(urlRequest.timeoutInterval, 120)
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
        XCTAssertNil(body["reasoning"])

        // OpenRouter takes a reasoning object instead.
        request.baseURL = "https://openrouter.ai/api/v1"
        request.effort = .max
        urlRequest = try OpenAIClient.urlRequest(for: request)
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(urlRequest.httpBody)) as? [String: Any])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")

        // No effort, no field: models that do not reason reject it.
        request.effort = nil
        body = try XCTUnwrap(JSONSerialization.jsonObject(with: try OpenAIClient.body(for: request)) as? [String: Any])
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["reasoning"])

        // A profile carries its options into every request it makes.
        let profile = Profile(name: "gw", baseURL: "https://gw/v1", authScheme: .xAPIKey,
                              headers: [HTTPHeader(name: "X-Tenant", value: "t1")], idleTimeout: 60)
        let built = profile.chatRequest(apiKey: "k", model: "m", messages: [], effort: .low)
        XCTAssertEqual(built.authScheme, .xAPIKey)
        XCTAssertEqual(built.headers, [HTTPHeader(name: "X-Tenant", value: "t1")])
        XCTAssertEqual(built.idleTimeout, 60)
        XCTAssertEqual(built.effort, .low)
        XCTAssertEqual(Profile(name: "p", baseURL: "x", idleTimeout: 1).streamTimeout, 300)
        XCTAssertTrue(OpenAIClient.isOpenRouter("https://openrouter.ai/api/v1"))
        XCTAssertFalse(OpenAIClient.isOpenRouter("https://notopenrouter.ai/v1"))
    }

    func testImagesGoAsContentParts() throws {
        let message = ChatMessage(role: .user, content: "what is this?", images: ["data:image/jpeg;base64,AAAA"])
        let parts = try XCTUnwrap(OpenAIClient.encodeMessage(message)["content"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["type"] as? String }, ["text", "image_url"])
        XCTAssertEqual((parts[1]["image_url"] as? [String: Any])?["url"] as? String, "data:image/jpeg;base64,AAAA")
        let photoOnly = ChatMessage(role: .user, content: "", images: ["data:image/jpeg;base64,BBBB"])
        XCTAssertEqual((OpenAIClient.encodeMessage(photoOnly)["content"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(OpenAIClient.encodeMessage(ChatMessage(role: .user, content: "plain"))["content"] as? String, "plain")
        let plain = ChatMessage(role: .user, content: "what is this?")
        XCTAssertEqual(ContextBudget.estimate([message]) - ContextBudget.estimate([plain]), 1_000)
        XCTAssertTrue(Compaction.render([message]).contains("[1 image attached]"))
    }

    func testModelListOverridesDiscoveryAndHostsRememberFolders() {
        var profile = Profile(name: "p", baseURL: "x", discoveredModels: ["d1", "d2"])
        XCTAssertEqual(profile.pickerModels, ["d1", "d2"])
        XCTAssertEqual(profile.preferredModel, "d1")
        profile.models = ["m1"]
        XCTAssertEqual(profile.pickerModels, ["m1"])
        XCTAssertEqual(profile.preferredModel, "m1")

        var host = SSHHost(name: "h", host: "x", username: "u")
        for path in ["/a", "/b", "/a"] { host.remember(directory: path) }
        XCTAssertEqual(host.recentDirectories, ["/a", "/b"])
        for index in 0..<10 { host.remember(directory: "/d\(index)") }
        XCTAssertEqual(host.recentDirectories?.count, 8)
        XCTAssertEqual(host.recentDirectories?.first, "/d9")

        XCTAssertEqual(AppSettings().themeID, Theme.desktop.id)
        XCTAssertFalse(Theme.named("desktop").monospacedUI)
        XCTAssertTrue(Theme.named("crt-green").monospacedUI)
        XCTAssertEqual(Theme.all.first, .desktop)
        XCTAssertEqual(Effort.allCases.map(\.title), ["Low", "Medium", "High", "Extra", "Max"])
        XCTAssertEqual(Commands.parse("/effort high"), .command(name: "effort", args: "high"))
    }

    func testContextWindowParsing() {
        XCTAssertEqual(Profile.parseContextWindow("200k"), 200_000)
        XCTAssertEqual(Profile.parseContextWindow(" 1M "), 1_000_000)
        XCTAssertEqual(Profile.parseContextWindow("131,072"), 131_072)
        XCTAssertEqual(Profile.parseContextWindow("1.5m"), 1_500_000)
        XCTAssertNil(Profile.parseContextWindow(""))
        XCTAssertNil(Profile.parseContextWindow("lots"))
        XCTAssertNil(Profile.parseContextWindow("12"))
        XCTAssertEqual(Profile(name: "p", baseURL: "x", contextWindow: 32_000).contextLimit, 32_000)
    }

    // MARK: Coding tools

    func testEditGlobAndGrepInTheWorkspace() async throws {
        let files = FileManager.default
        try files.createDirectory(at: workspace.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try files.createDirectory(at: workspace.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
        try Data("let a = 1\nlet b = 2\nlet a2 = 3\n".utf8).write(to: workspace.appendingPathComponent("src/main.swift"))
        try Data("# notes\nTODO: ship\n".utf8).write(to: workspace.appendingPathComponent("src/deep/README.md"))
        try Data([0, 108, 101, 116]).write(to: workspace.appendingPathComponent("src/blob.bin"))
        try Data("let a = 0\n".utf8).write(to: workspace.appendingPathComponent("node_modules/x/index.swift"))
        let tools = ToolBox(workspace: workspace, shell: nil)
        func run(_ name: String, _ arguments: String, output: TextBuffer = TextBuffer()) async -> ToolResult {
            await tools.run(ToolCall(id: "t", name: name, arguments: arguments)) { output.append($0) }
        }

        let ambiguous = await run("edit_file", #"{"path":"src/main.swift","old_string":"let a","new_string":"var a"}"#)
        XCTAssertTrue(ambiguous.isError)
        XCTAssertTrue(ambiguous.text.contains("matches 2 places"), ambiguous.text)
        let missing = await run("edit_file", #"{"path":"src/main.swift","old_string":"let c","new_string":"x"}"#)
        XCTAssertTrue(missing.text.contains("not found"), missing.text)

        let diff = TextBuffer()
        let edit = await run("edit_file", #"{"path":"src/main.swift","old_string":"let b = 2","new_string":"let b = 20"}"#, output: diff)
        XCTAssertFalse(edit.isError, edit.text)
        XCTAssertTrue(edit.text.hasPrefix("edited src/main.swift: 1 replacement, first at line 2\n     1\tlet a = 1\n     2\tlet b = 20"), edit.text)
        XCTAssertEqual(diff.value, "- let b = 2\n+ let b = 20")

        let all = await run("edit_file", #"{"path":"src/main.swift","old_string":"let a","new_string":"var a","replace_all":true}"#)
        XCTAssertFalse(all.isError, all.text)
        XCTAssertEqual(try String(contentsOf: workspace.appendingPathComponent("src/main.swift"), encoding: .utf8),
                       "var a = 1\nlet b = 20\nvar a2 = 3\n")

        let glob = await run("glob", #"{"pattern":"**/*.{swift,md}"}"#)
        XCTAssertEqual(glob.text, "src/deep/README.md\nsrc/main.swift")
        let named = await run("glob", #"{"pattern":"*.md","path":"src"}"#)
        XCTAssertEqual(named.text, "src/deep/README.md")
        let nothing = await run("glob", #"{"pattern":"*.py"}"#)
        XCTAssertEqual(nothing.text, "no files match *.py")

        let grep = await run("grep", #"{"pattern":"^var a\\d?","glob":"*.swift"}"#)
        XCTAssertEqual(grep.text, "src/main.swift:1:var a = 1\nsrc/main.swift:3:var a2 = 3")
        let caseless = await run("grep", #"{"pattern":"todo","ignore_case":true,"path":"src/deep"}"#)
        XCTAssertEqual(caseless.text, "src/deep/README.md:2:TODO: ship")
        let none = await run("grep", #"{"pattern":"nothing here"}"#)
        XCTAssertEqual(none.text, "no matches")
        let invalid = await run("grep", #"{"pattern":"("}"#)
        XCTAssertTrue(invalid.isError)

        XCTAssertFalse(tools.needsApproval(ToolCall(id: "", name: "grep", arguments: "{}")))
        XCTAssertFalse(tools.needsApproval(ToolCall(id: "", name: "glob", arguments: "{}")))
        XCTAssertTrue(tools.needsApproval(ToolCall(id: "", name: "edit_file", arguments: "{}")))
        XCTAssertEqual(tools.summary(ToolCall(id: "", name: "edit_file", arguments: #"{"path":"a.swift","old_string":"x\ny","new_string":"z"}"#)),
                       "edit a.swift (2 → 1 lines)")
        XCTAssertEqual(ToolBox.preview(ToolCall(id: "", name: "write_file", arguments: #"{"path":"n","content":"one\ntwo"}"#)),
                       "+ one\n+ two")
        XCTAssertNil(ToolBox.preview(ToolCall(id: "", name: "ssh_exec", arguments: #"{"command":"ls"}"#)))
    }

    func testReadFileWithLineNumbers() async throws {
        try Data("one\ntwo\nthree\nfour\n".utf8).write(to: workspace.appendingPathComponent("n.txt"))
        let tools = ToolBox(workspace: workspace, shell: nil)
        let range = await tools.run(ToolCall(id: "1", name: "read_file", arguments: #"{"path":"n.txt","offset":2,"limit":2}"#)) { _ in }
        XCTAssertEqual(range.text, "     2\ttwo\n     3\tthree\n… 1 more line; continue with offset 4")
        let rest = await tools.run(ToolCall(id: "2", name: "read_file", arguments: #"{"path":"n.txt","offset":4}"#)) { _ in }
        XCTAssertEqual(rest.text, "     4\tfour")
        let past = await tools.run(ToolCall(id: "3", name: "read_file", arguments: #"{"path":"n.txt","offset":9}"#)) { _ in }
        XCTAssertEqual(past.text, "(the file has 4 lines)")
        let missing = await tools.run(ToolCall(id: "4", name: "read_file", arguments: #"{"path":"nope.txt"}"#)) { _ in }
        XCTAssertEqual(missing, ToolResult(text: "error: file not found: nope.txt", isError: true))
    }

    func testTextEditRules() throws {
        XCTAssertThrowsError(try TextEdit.apply(to: "abc", old: "", new: "x"))
        XCTAssertThrowsError(try TextEdit.apply(to: "abc", old: "b", new: "b"))
        XCTAssertThrowsError(try TextEdit.apply(to: "abc", old: "z", new: "x"))
        // Windows line endings still match an edit written with \n, and keep their \r\n.
        let crlf = try TextEdit.apply(to: "a\r\nb\r\nc\r\n", old: "b\nc", new: "B\nC")
        XCTAssertEqual(crlf.text, "a\r\nB\r\nC\r\n")
        XCTAssertEqual(crlf.line, 2)
        let unicode = try TextEdit.apply(to: "héllo wörld ✓", old: "wörld", new: "мир")
        XCTAssertEqual(unicode.text, "héllo мир ✓")
        let every = try TextEdit.apply(to: "x-x-x", old: "x", new: "yy", replaceAll: true)
        XCTAssertEqual(every, TextEdit.Outcome(text: "yy-yy-yy", replacements: 3, line: 1))
        XCTAssertEqual(TextEdit.preview(old: "a\nb\nc", new: "a\nB\nc"), "  a\n- b\n+ B\n  c")
        XCTAssertEqual(TextEdit.preview(old: "gone", new: ""), "- gone")
    }

    func testGlobPatterns() {
        XCTAssertTrue(Glob("*.swift").matches("Sources/TermCore/Agent.swift"))
        XCTAssertFalse(Glob("*.swift").matches("Sources/notes.md"))
        XCTAssertTrue(Glob("**/*.swift").matches("Agent.swift"))
        XCTAssertTrue(Glob("Sources/**/*.swift").matches("Sources/TermCore/Agent.swift"))
        XCTAssertFalse(Glob("Sources/*.swift").matches("Sources/TermCore/Agent.swift"))
        XCTAssertTrue(Glob("src/*.{ts,tsx}").matches("src/app.tsx"))
        XCTAssertTrue(Glob("file?.txt").matches("file1.txt"))
        XCTAssertTrue(Glob("[!a]*.c").matches("main.c"))
        XCTAssertFalse(Glob("[!m]*.c").matches("main.c"))
        XCTAssertTrue(Glob("a+b(1).txt").matches("a+b(1).txt"))
        XCTAssertTrue(Glob("./README.md").matches("README.md"))
        XCTAssertFalse(Glob("./README.md").matches("docs/README.md"))
    }

    func testShellQuotingAndPaths() {
        XCTAssertEqual(Shell.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(RemoteFiles.pathExpression("/srv/app", base: nil), "'/srv/app'")
        XCTAssertEqual(RemoteFiles.pathExpression("src/a.py", base: "/srv/app"), "'/srv/app'/'src/a.py'")
        XCTAssertEqual(RemoteFiles.pathExpression("~/x", base: "/srv/app"), #""$HOME"/'x'"#)
        XCTAssertEqual(RemoteFiles.pathExpression(".", base: "~/app"), #""$HOME"/'app'"#)
        XCTAssertEqual(RemoteFiles.pathExpression("notes", base: nil), #""$HOME"/'notes'"#)
        XCTAssertEqual(RemoteFiles.pathExpression("", base: nil), #""$HOME""#)
    }

    func testProjectModeTools() {
        let tools = ToolBox(workspace: workspace, shell: FakeShell(), projectDirectory: "/srv/app")
        XCTAssertEqual(tools.specs.map(\.name), ["ssh_exec", "read_file", "write_file", "edit_file", "list_files", "glob", "grep", "fetch_url"])
        XCTAssertTrue(tools.specs[1].description.contains("on box"))
        XCTAssertEqual(tools.summary(ToolCall(id: "", name: "ssh_exec", arguments: #"{"command":"ls"}"#)), "ssh box:app $ ls")
        XCTAssertEqual(tools.summary(ToolCall(id: "", name: "read_file", arguments: #"{"path":"a.py","offset":10,"limit":5}"#)), "read box:a.py:10+5")
        // Without a shell the project folder is ignored and the workspace is used.
        XCTAssertTrue(ToolBox(workspace: workspace, shell: nil, projectDirectory: "/srv/app").specs[0].description.contains("on-device"))
    }

    func testProjectCommandsStartInTheProjectFolder() async throws {
        let client = ScriptedClient([[.toolCallDelta(index: 0, id: "c1", name: "ssh_exec", arguments: #"{"command":"make test"}"#)], [.text("ok")]])
        let recorder = Recorder()
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell(), projectDirectory: "~/my app")).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: []),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages[1].content, "ran: cd \"$HOME\"/'my app' || exit 97\nmake test\n\n[exit 0]")
    }

    func testReasoningIsShownButNotSentBack() async throws {
        let client = ScriptedClient([[.reasoning("let me "), .reasoning("think"), .text("answer")]])
        let recorder = Recorder()
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil)).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: [ChatMessage(role: .user, content: "q")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let reasoning = await recorder.reasoning
        XCTAssertEqual(reasoning, "let me think")
        let messages = await recorder.messages
        XCTAssertEqual(messages, [ChatMessage(role: .assistant, content: "answer")])
    }

    // MARK: Context

    func testContextTrimKeepsRecentToolResults() async throws {
        let big = String(repeating: "x", count: 5_000)
        var messages = [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: "go")]
        for n in 0..<8 {
            messages.append(ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c\(n)", name: "read_file", arguments: "{}")]))
            messages.append(ChatMessage(role: .tool, content: big, toolCallID: "c\(n)"))
        }
        XCTAssertEqual(ContextBudget.trimToolResults(messages, limit: 1_000_000), messages)
        let trimmed = ContextBudget.trimToolResults(messages, limit: 10_000)
        XCTAssertEqual(trimmed.map(\.role), messages.map(\.role))
        let results = trimmed.filter { $0.role == .tool }
        XCTAssertTrue(results.prefix(2).allSatisfy { $0.content.count < 1_200 && $0.content.contains("trimmed") })
        XCTAssertEqual(results.suffix(6).map(\.content), Array(repeating: big, count: 6))

        // The agent sends the trimmed copy but keeps the full history.
        let client = ScriptedClient([[.text("done")]])
        let recorder = Recorder()
        try await Agent(client: client, tools: ToolBox(workspace: workspace, shell: nil), contextTokens: 10_000).run(
            request: ChatRequest(baseURL: "http://x", apiKey: "", model: "m", messages: messages),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        XCTAssertEqual(client.requests[0].messages, trimmed)
    }

    func testCompactionSendsAFlatTranscript() {
        let history = [
            ChatMessage(role: .user, content: "fix the bug"),
            ChatMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "c1", name: "grep", arguments: #"{"pattern":"bug"}"#)]),
            ChatMessage(role: .tool, content: String(repeating: "y", count: 10_000), toolCallID: "c1"),
            ChatMessage(role: .assistant, content: "fixed"),
        ]
        let request = Compaction.messages(for: history, contextTokens: 128_000)
        XCTAssertEqual(request.map(\.role), [.system, .user])
        XCTAssertTrue(request[1].content.contains("USER: fix the bug"))
        XCTAssertTrue(request[1].content.contains(#"→ grep {"pattern":"bug"}"#))
        XCTAssertTrue(request[1].content.contains("ASSISTANT: fixed"))
        XCTAssertLessThan(request[1].content.count, 4_000)
        XCTAssertEqual(Compaction.replacement(summary: "s").map(\.role), [.user, .assistant])
    }

    func testSystemPromptForAProject() {
        let prompt = SystemPrompt.build(custom: "be brief", hostLabel: "me@web1", projectDirectory: "/srv/app",
                                        projectNotes: "AGENTS.md:\nuse tabs")
        XCTAssertTrue(prompt.contains("project directory /srv/app on me@web1"))
        XCTAssertTrue(prompt.contains("use tabs"))
        XCTAssertTrue(prompt.hasSuffix("be brief"))
        XCTAssertTrue(SystemPrompt.build(custom: "", hostLabel: nil).contains("No SSH host"))
    }

    // MARK: Files on an SSH host, through a real shell

    #if os(macOS) || os(Linux)
    func testRemoteFileToolsThroughARealShell() async throws {
        // A space and a quote in the folder name exercise the shell quoting.
        let project = workspace.appendingPathComponent("it's a project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let tools = ToolBox(workspace: workspace, shell: LocalShell(), projectDirectory: project.path)
        func run(_ name: String, _ arguments: [String: Any]) async throws -> ToolResult {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            return await tools.run(ToolCall(id: "t", name: name, arguments: json)) { _ in }
        }
        func onDisk(_ path: String) throws -> String {
            try String(contentsOf: project.appendingPathComponent(path), encoding: .utf8)
        }

        let write = try await run("write_file", ["path": "src/hello.txt", "content": "héllo\nworld\n"])
        XCTAssertEqual(write, ToolResult(text: "wrote 13 bytes to src/hello.txt"))
        XCTAssertEqual(try onDisk("src/hello.txt"), "héllo\nworld\n")
        let read = try await run("read_file", ["path": "src/hello.txt"])
        XCTAssertEqual(read, ToolResult(text: "héllo\nworld\n"))

        let edit = try await run("edit_file", ["path": "src/hello.txt", "old_string": "world", "new_string": "there"])
        XCTAssertFalse(edit.isError, edit.text)
        XCTAssertEqual(try onDisk("src/hello.txt"), "héllo\nthere\n")
        let numbered = try await run("read_file", ["path": "src/hello.txt", "offset": 2, "limit": 1])
        XCTAssertEqual(numbered.text, "     2\tthere")

        let glob = try await run("glob", ["pattern": "**/*.txt"])
        XCTAssertEqual(glob.text, "src/hello.txt")
        let grep = try await run("grep", ["pattern": "th.re"])
        XCTAssertEqual(grep.text, "src/hello.txt:2:there")
        let scoped = try await run("grep", ["pattern": "HÉLLO", "path": "src", "ignore_case": true, "glob": "*.txt"])
        XCTAssertFalse(scoped.isError, scoped.text)
        let list = try await run("list_files", ["path": "src"])
        XCTAssertEqual(list.text, "hello.txt")

        // Bigger than one upload chunk, and an empty file.
        let big = (0..<1_600).map { "line \($0) " + String(repeating: "x", count: 20) }.joined(separator: "\n")
        let bigWrite = try await run("write_file", ["path": "deep/er/big.txt", "content": big])
        XCTAssertFalse(bigWrite.isError, bigWrite.text)
        XCTAssertEqual(try onDisk("deep/er/big.txt"), big)
        let bigRead = try await run("read_file", ["path": "deep/er/big.txt"])
        XCTAssertEqual(bigRead.text, big)
        let empty = try await run("write_file", ["path": "empty.txt", "content": ""])
        XCTAssertFalse(empty.isError, empty.text)
        XCTAssertEqual(try onDisk("empty.txt"), "")

        let pwd = try await run("ssh_exec", ["command": "pwd"])
        XCTAssertTrue(pwd.text.contains("it's a project\n"), pwd.text)
        let missing = try await run("read_file", ["path": "nope.txt"])
        XCTAssertEqual(missing, ToolResult(text: "error: file not found: nope.txt", isError: true))
        let folder = try await run("read_file", ["path": "src"])
        XCTAssertTrue(folder.text.contains("is a directory"), folder.text)

        let files = RemoteFiles(shell: LocalShell(), root: project.path)
        let resolved = try await files.resolveDirectory("src")
        XCTAssertTrue(resolved.hasSuffix("/it's a project/src"), resolved)
        do {
            _ = try await files.resolveDirectory("no-such-folder")
            XCTFail("expected an error")
        } catch {}
        let noNotes = await files.projectNotes()
        XCTAssertNil(noNotes)
        try Data("Use tabs.\n".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        let notes = await files.projectNotes()
        XCTAssertEqual(notes, "AGENTS.md:\nUse tabs.")
    }
    #endif

    // MARK: Live HTTP (needs a mock server; see Tests/mock_server.py)

    func testLiveStreamingAgainstMockServer() async throws {
        guard let base = ProcessInfo.processInfo.environment["TERMAI_TEST_BASEURL"] else {
            throw XCTSkip("set TERMAI_TEST_BASEURL to run")
        }
        let client = OpenAIClient()
        let models = try await client.listModels(baseURL: base, apiKey: "test-key")
        XCTAssertEqual(models, ["mock-a", "mock-b"])

        let recorder = Recorder()
        let agent = Agent(client: client, tools: ToolBox(workspace: workspace, shell: FakeShell()))
        try await agent.run(
            request: ChatRequest(baseURL: base, apiKey: "test-key", model: "mock-a", messages: [ChatMessage(role: .user, content: "go")]),
            approve: { _, _ in .allow }, emit: { await recorder.record($0) })
        let messages = await recorder.messages
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[1].content, "ran: echo hi\n\n[exit 0]")
        XCTAssertEqual(messages[2].content, "héllo ✓ done")

        do {
            for try await _ in client.streamChat(ChatRequest(baseURL: base, apiKey: "wrong", model: "m", messages: [])) {}
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? APIError, APIError(status: 401, message: "bad key"))
        }
    }
}
