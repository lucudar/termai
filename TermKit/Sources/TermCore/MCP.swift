import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A remote MCP server ("connector") whose tools the agent can use.
public struct Connector: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// The Streamable HTTP endpoint, e.g. `https://mcp.deepwiki.com/mcp`.
    public var url: String
    public var headers: [HTTPHeader]?
    /// nil means on.
    public var enabled: Bool?

    public init(id: UUID = UUID(), name: String, url: String, headers: [HTTPHeader]? = nil, enabled: Bool? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.headers = headers
        self.enabled = enabled
    }

    /// The bearer token lives in the secret store.
    public var secretKey: String { "connector.\(id.uuidString).token" }
    public var isEnabled: Bool { enabled ?? true }
}

/// A tool a connector offers.
public struct MCPTool: Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String
    /// JSON Schema of the arguments, as JSON text.
    public var inputSchemaJSON: String
    /// The server marks the tool as read-only (`readOnlyHint`), so it runs without asking.
    public var readOnly: Bool

    public init(name: String, title: String? = nil, description: String = "",
                inputSchemaJSON: String = #"{"type":"object"}"#, readOnly: Bool = false) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
        self.readOnly = readOnly
    }
}

public enum MCPError: LocalizedError, Equatable {
    case invalidURL(String)
    case http(status: Int, message: String)
    case needsSignIn
    case rpc(code: Int, message: String)
    case badResponse(String)
    case legacyTransport

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value): return "invalid connector URL: \(value)"
        case .http(let status, let message): return "HTTP \(status): \(message)"
        case .needsSignIn:
            return "this server wants an OAuth sign-in, which TermAI does not do yet. Add a token if the server accepts one"
        case .rpc(let code, let message): return "server error \(code): \(message)"
        case .badResponse(let detail): return "unexpected reply: \(detail)"
        case .legacyTransport:
            return "this URL speaks the old HTTP+SSE transport; use the server's Streamable HTTP URL (usually ending in /mcp)"
        }
    }
}

/// A Model Context Protocol client over Streamable HTTP. It opens a 2025-style session (`initialize`,
/// then `Mcp-Session-Id` on every request) and falls back to the stateless 2026 form when a server has no
/// `initialize`.
public actor MCPClient {
    public static let sessionVersion = "2025-11-25"
    public static let statelessVersion = "2026-07-28"
    static var clientInfo: [String: Any] { ["name": "TermAI", "version": "0.4"] }

    let endpoint: URL
    let token: String
    let headers: [HTTPHeader]
    var sessionID: String?
    var negotiatedVersion: String?
    var stateless = false
    var ready = false
    var nextID = 1

    public init(url: String, token: String = "", headers: [HTTPHeader] = []) throws {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmed), let scheme = endpoint.scheme?.lowercased(),
              scheme == "https" || scheme == "http", endpoint.host != nil else {
            throw MCPError.invalidURL(url)
        }
        self.endpoint = endpoint
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.headers = headers
    }

    /// Every tool the server lists, following `nextCursor`.
    public func listTools() async throws -> [MCPTool] {
        try await prepare()
        var tools: [MCPTool] = []
        var cursor: String?
        var pages = 0
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request("tools/list", params: params)
            tools += ((result["tools"] as? [[String: Any]]) ?? []).compactMap(Self.tool)
            cursor = result["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < 20
        return tools
    }

    public func callTool(_ name: String, argumentsJSON: String) async throws -> ToolResult {
        try await prepare()
        let parsed = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))
        let arguments = (parsed as? [String: Any]) ?? [:]
        let result = try await request("tools/call", params: ["name": name, "arguments": arguments], toolName: name)
        return Self.toolResult(result)
    }

    /// Opens a session unless one is open, or learns that the server is stateless.
    func prepare() async throws {
        guard !ready else { return }
        do {
            let result = try await request("initialize", params: [
                "protocolVersion": Self.sessionVersion,
                "capabilities": [String: Any](),
                "clientInfo": Self.clientInfo,
            ])
            negotiatedVersion = result["protocolVersion"] as? String ?? Self.sessionVersion
            ready = true
            try? await notify("notifications/initialized")
        } catch MCPError.http(let status, _) where status == 400 || status == 404 || status == 405 {
            if endpoint.path.lowercased().hasSuffix("/sse") { throw MCPError.legacyTransport }
            // A stateless (2026) server has no initialize; every request carries its own metadata.
            stateless = true
            sessionID = nil
            ready = true
        } catch MCPError.rpc(let code, _) where code == -32601 || code == -32602 {
            stateless = true
            sessionID = nil
            ready = true
        }
    }

    func request(_ method: String, params: [String: Any], toolName: String? = nil,
                 retried: Bool = false) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var fullParams = params
        if stateless { fullParams["_meta"] = Self.statelessMeta }
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": fullParams]
        let (response, data) = try await post(body, method: method, toolName: toolName)
        // An expired session answers 404: open a new one and try once more.
        if response.statusCode == 404, sessionID != nil, method != "initialize", !retried {
            sessionID = nil
            ready = false
            try await prepare()
            return try await request(method, params: params, toolName: toolName, retried: true)
        }
        try check(response, data)
        if method == "initialize", let session = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !session.isEmpty {
            sessionID = session
        }
        let message = try Self.response(id: id, data: data,
                                        contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "")
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc(code: (error["code"] as? NSNumber)?.intValue ?? 0,
                               message: error["message"] as? String ?? "error")
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    func notify(_ method: String) async throws {
        let body: [String: Any] = ["jsonrpc": "2.0", "method": method]
        _ = try await post(body, method: method, toolName: nil)
    }

    func post(_ body: [String: Any], method: String, toolName: String?) async throws -> (HTTPURLResponse, Data) {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if stateless {
            urlRequest.setValue(Self.statelessVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            urlRequest.setValue(method, forHTTPHeaderField: "Mcp-Method")
            if let toolName { urlRequest.setValue(toolName, forHTTPHeaderField: "Mcp-Name") }
        } else if let negotiatedVersion {
            urlRequest.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionID { urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        OpenAIClient.authorize(&urlRequest, apiKey: token, scheme: .bearer, headers: headers)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await MCPTransport.send(urlRequest)
    }

    func check(_ response: HTTPURLResponse, _ data: Data) throws {
        let status = response.statusCode
        if status == 401 {
            if token.isEmpty { throw MCPError.needsSignIn }
            throw MCPError.http(status: 401, message: "the server did not accept the token")
        }
        guard (200..<300).contains(status) else {
            throw MCPError.http(status: status, message: APIError.from(status: status, body: data).message)
        }
    }

    static var statelessMeta: [String: Any] {
        ["io.modelcontextprotocol/protocolVersion": statelessVersion,
         "io.modelcontextprotocol/clientCapabilities": [String: Any](),
         "io.modelcontextprotocol/clientInfo": clientInfo]
    }

    /// The JSON-RPC response with `id`, from a JSON body or from an SSE stream of messages.
    static func response(id: Int, data: Data, contentType: String) throws -> [String: Any] {
        var candidates: [Any] = []
        if contentType.lowercased().contains("text/event-stream") {
            var parser = SSEParser()
            for payload in parser.feed(data + Data("\n".utf8)) {
                if let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) { candidates.append(object) }
            }
        } else if let object = try? JSONSerialization.jsonObject(with: data) {
            candidates.append(object)
        }
        var messages: [[String: Any]] = []
        for candidate in candidates {
            if let batch = candidate as? [[String: Any]] {
                messages += batch
            } else if let single = candidate as? [String: Any] {
                messages.append(single)
            }
        }
        let match = messages.first { message in
            (message["id"] as? NSNumber)?.intValue == id || (message["id"] as? String) == String(id)
        }
        if let match { return match }
        let preview = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw MCPError.badResponse(preview.isEmpty ? "empty reply" : preview)
    }

    static func tool(_ object: [String: Any]) -> MCPTool? {
        guard let name = object["name"] as? String, !name.isEmpty else { return nil }
        let schema = object["inputSchema"] as? [String: Any] ?? ["type": "object"]
        let data = (try? JSONSerialization.data(withJSONObject: schema)) ?? Data(#"{"type":"object"}"#.utf8)
        let annotations = object["annotations"] as? [String: Any]
        return MCPTool(name: name,
                       title: (object["title"] as? String) ?? (annotations?["title"] as? String),
                       description: object["description"] as? String ?? "",
                       inputSchemaJSON: String(decoding: data, as: UTF8.self),
                       readOnly: (annotations?["readOnlyHint"] as? Bool) ?? false)
    }

    /// A `tools/call` result as text for the model: text blocks as they are, other blocks described.
    static func toolResult(_ result: [String: Any]) -> ToolResult {
        var parts: [String] = []
        for block in (result["content"] as? [[String: Any]]) ?? [] {
            let type = block["type"] as? String ?? ""
            switch type {
            case "text":
                if let text = block["text"] as? String { parts.append(text) }
            case "image", "audio":
                let size = ((block["data"] as? String)?.count ?? 0) * 3 / 4
                parts.append("[\(type) \(block["mimeType"] as? String ?? type), \(size) bytes]")
            case "resource_link":
                parts.append("[link] \(block["name"] as? String ?? "") \(block["uri"] as? String ?? "")")
            case "resource":
                let resource = block["resource"] as? [String: Any]
                if let text = resource?["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append("[resource \(resource?["uri"] as? String ?? "")]")
                }
            default:
                break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"], JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        let text = parts.joined(separator: "\n")
        return ToolResult(text: Truncate.middle(text.isEmpty ? "(no output)" : text),
                          isError: (result["isError"] as? Bool) ?? false)
    }
}

/// One HTTP exchange that keeps the response headers (`Mcp-Session-Id`, `Content-Type`) and can be cancelled.
enum MCPTransport {
    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        /// False when the request was cancelled before it started.
        func set(_ task: URLSessionDataTask) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.task = task
            return !cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    static func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>) in
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (http, data ?? Data()))
                    } else {
                        continuation.resume(throwing: MCPError.badResponse("no HTTP response"))
                    }
                }
                if box.set(task) { task.resume() } else { task.cancel() }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
