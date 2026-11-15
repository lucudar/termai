import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An error the gateway reported in the middle of a streamed answer.
public struct StreamError: LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }
}

/// Client for Anthropic's `/messages`, used for gateways set to the Anthropic format. It takes the same
/// OpenAI-shaped history as `OpenAIClient` and converts it on the way out.
public struct AnthropicClient: ChatStreaming {
    public static let defaultVersion = "2023-06-01"

    public init() {}

    /// The custom headers plus `anthropic-version`, unless one of them already sets it.
    public static func versioned(_ headers: [HTTPHeader]) -> [HTTPHeader] {
        let set = headers.contains { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "anthropic-version" }
        return set ? headers : headers + [HTTPHeader(name: "anthropic-version", value: defaultVersion)]
    }

    static func urlRequest(for request: ChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: try OpenAIClient.endpoint(request.baseURL, "/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.idleTimeout > 0 ? request.idleTimeout : Profile.defaultIdleTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        OpenAIClient.authorize(&urlRequest, apiKey: request.apiKey, scheme: request.authScheme,
                               headers: versioned(request.headers))
        urlRequest.httpBody = try body(for: request)
        return urlRequest
    }

    static func body(for request: ChatRequest) throws -> Data {
        var object: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens > 0 ? request.maxTokens : Profile.defaultMaxTokens,
            "stream": true,
            "messages": messages(from: request.messages),
        ]
        let system = request.messages.filter { $0.role == .system && !$0.content.isEmpty }.map(\.content)
        if !system.isEmpty { object["system"] = system.joined(separator: "\n\n") }
        // Effort covers the whole answer, thinking included; without it the model's default applies.
        if let effort = request.effort { object["output_config"] = ["effort": effort.rawValue] }
        if !request.tools.isEmpty {
            object["tools"] = request.tools.map { tool -> [String: Any] in
                let parsed = try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))
                let schema: [String: Any] = (parsed as? [String: Any]) ?? ["type": "object"]
                return ["name": tool.name, "description": tool.description, "input_schema": schema]
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// The history as Anthropic messages: system text moves to `system`, tool results become user turns,
    /// consecutive turns of one role merge, and thinking blocks go back only within the current tool-use loop.
    static func messages(from history: [ChatMessage]) -> [[String: Any]] {
        let lastPrompt = history.lastIndex { $0.role == .user } ?? -1
        var turns: [(role: String, content: [[String: Any]])] = []
        for (index, message) in history.enumerated() {
            var role = "user"
            var blocks: [[String: Any]] = []
            switch message.role {
            case .system:
                continue
            case .user:
                blocks = (message.images ?? []).compactMap(imageBlock)
                if !message.content.isEmpty { blocks.append(["type": "text", "text": message.content]) }
            case .tool:
                blocks = [["type": "tool_result", "tool_use_id": message.toolCallID ?? "",
                           "content": message.content.isEmpty ? "(no output)" : message.content]]
            case .assistant:
                role = "assistant"
                if index > lastPrompt {
                    for block in message.reasoning ?? [] {
                        if let data = block.redactedData {
                            blocks.append(["type": "redacted_thinking", "data": data])
                        } else if let signature = block.signature {
                            blocks.append(["type": "thinking", "thinking": block.text, "signature": signature])
                        }
                    }
                }
                if !message.content.isEmpty { blocks.append(["type": "text", "text": message.content]) }
                for call in message.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input ?? [String: Any]()])
                }
            }
            guard !blocks.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].content += blocks
            } else {
                turns.append((role: role, content: blocks))
            }
        }
        // The conversation has to open with a user turn.
        if turns.first?.role == "assistant" {
            turns.insert((role: "user", content: [["type": "text", "text": "(continuing)"]]), at: 0)
        }
        return turns.map { ["role": $0.role, "content": $0.content] }
    }

    /// `data:image/png;base64,…` as an image block.
    static func imageBlock(_ dataURL: String) -> [String: Any]? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let meta = dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma]
        guard meta.hasSuffix(";base64") else { return nil }
        let mediaType = String(meta.dropLast(7))
        return ["type": "image",
                "source": ["type": "base64", "media_type": mediaType.isEmpty ? "image/jpeg" : mediaType,
                           "data": String(dataURL[dataURL.index(after: comma)...])]]
    }

    /// What a stream keeps between events: thinking blocks still being written, and the usage so far.
    struct StreamState {
        var thinking: [Int: ReasoningBlock] = [:]
        var inputTokens = 0
        var outputTokens = 0
    }

    /// Decodes one `data:` payload of a streamed message.
    static func decode(_ payload: String, state: inout StreamState) throws -> [StreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        let index = (object["index"] as? NSNumber)?.intValue ?? 0
        switch type {
        case "message_start":
            let usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            state.inputTokens = inputTokens(usage)
            state.outputTokens = (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
            return state.inputTokens > 0 ? [.usage(input: state.inputTokens, output: state.outputTokens)] : []
        case "content_block_start":
            let block = object["content_block"] as? [String: Any] ?? [:]
            switch block["type"] as? String {
            case "text":
                let text = block["text"] as? String ?? ""
                return text.isEmpty ? [] : [.text(text)]
            case "tool_use":
                // The input usually follows as JSON fragments; a start that already carries it passes it on.
                var arguments: String?
                if let input = block["input"] as? [String: Any], !input.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: input) {
                    arguments = String(decoding: data, as: UTF8.self)
                }
                return [.toolCallDelta(index: index, id: block["id"] as? String, name: block["name"] as? String,
                                       arguments: arguments)]
            case "thinking":
                let text = block["thinking"] as? String ?? ""
                state.thinking[index] = ReasoningBlock(text: text, signature: block["signature"] as? String)
                return text.isEmpty ? [] : [.reasoning(text)]
            case "redacted_thinking":
                return [.reasoningBlock(ReasoningBlock(text: "", redactedData: block["data"] as? String ?? ""))]
            default:
                return []
            }
        case "content_block_delta":
            let delta = object["delta"] as? [String: Any] ?? [:]
            switch delta["type"] as? String {
            case "text_delta":
                let text = delta["text"] as? String ?? ""
                return text.isEmpty ? [] : [.text(text)]
            case "input_json_delta":
                let json = delta["partial_json"] as? String ?? ""
                return json.isEmpty ? [] : [.toolCallDelta(index: index, id: nil, name: nil, arguments: json)]
            case "thinking_delta":
                let text = delta["thinking"] as? String ?? ""
                var block = state.thinking[index] ?? ReasoningBlock(text: "")
                block.text += text
                state.thinking[index] = block
                return text.isEmpty ? [] : [.reasoning(text)]
            case "signature_delta":
                var block = state.thinking[index] ?? ReasoningBlock(text: "")
                block.signature = (block.signature ?? "") + (delta["signature"] as? String ?? "")
                state.thinking[index] = block
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let block = state.thinking.removeValue(forKey: index) else { return [] }
            return [.reasoningBlock(block)]
        case "message_delta":
            let usage = object["usage"] as? [String: Any]
            if let output = (usage?["output_tokens"] as? NSNumber)?.intValue { state.outputTokens = output }
            let input = inputTokens(usage)
            if input > 0 { state.inputTokens = input }
            return state.inputTokens > 0 || state.outputTokens > 0
                ? [.usage(input: state.inputTokens, output: state.outputTokens)] : []
        case "error":
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "the gateway reported an error"
            throw StreamError(message: (error?["type"] as? String).map { "\($0): \(message)" } ?? message)
        default:
            return []
        }
    }

    /// Input tokens including the cached ones, since they all fill the context window.
    static func inputTokens(_ usage: [String: Any]?) -> Int {
        ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { total, key in
            total + ((usage?[key] as? NSNumber)?.intValue ?? 0)
        }
    }

    public func streamChat(_ request: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try Self.urlRequest(for: request)
                    var parser = SSEParser()
                    var state = StreamState()
                    var status = 0
                    var errorBody = Data()
                    for try await chunk in HTTP.stream(urlRequest) {
                        switch chunk {
                        case .status(let code):
                            status = code
                        case .data(let data):
                            guard (200..<300).contains(status) else {
                                errorBody.append(data)
                                continue
                            }
                            for payload in parser.feed(data) {
                                for event in try Self.decode(payload, state: &state) { continuation.yield(event) }
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard (200..<300).contains(status) else { throw APIError.from(status: status, body: errorBody) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
