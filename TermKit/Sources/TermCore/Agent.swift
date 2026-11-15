import Foundation

public enum AgentEvent: Sendable {
    case assistantDelta(String)
    /// Reasoning ("thinking") the model streams before it answers, for display. Anthropic's signed thinking
    /// blocks travel separately, on the assistant message.
    case reasoningDelta(String)
    /// A message to append to the conversation history (assistant turn or tool result).
    case message(ChatMessage)
    case toolStarted(ToolCall, summary: String)
    case toolOutput(id: String, chunk: String)
    case toolFinished(id: String, result: ToolResult, denied: Bool)
    case usage(input: Int, output: Int)
}

public enum ApprovalDecision: Sendable {
    case allow, deny
}

public enum AgentError: LocalizedError, Equatable {
    case tooManySteps(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManySteps(let limit): return "stopped after \(limit) tool rounds; send another message to continue"
        }
    }
}

/// Runs the model, executes the tool calls it asks for, and repeats until it answers in plain text.
public struct Agent: Sendable {
    public var client: ChatStreaming
    public var tools: ToolRunning
    public var maxSteps: Int
    /// The model's context size in tokens. Old tool output is shortened in requests as the history nears it.
    public var contextTokens: Int

    public init(client: ChatStreaming, tools: ToolRunning, maxSteps: Int = 100, contextTokens: Int = 128_000) {
        self.client = client
        self.tools = tools
        self.maxSteps = maxSteps
        self.contextTokens = contextTokens
    }

    /// `request.messages` is the history including the new user message. Every message produced is
    /// reported through `emit(.message)` as soon as it is complete, so the caller's history stays valid
    /// even when the run is cancelled or fails part-way.
    public func run(
        request: ChatRequest,
        approve: @escaping @Sendable (ToolCall, String) async -> ApprovalDecision,
        emit: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        var request = request
        request.tools = tools.specs
        // The plan works whatever the tool box: the agent answers update_plan itself, without approval.
        let plansHere = !request.tools.contains { $0.name == Plan.toolName }
        if plansHere { request.tools.append(Plan.spec) }

        for _ in 0..<maxSteps {
            var text = ""
            var calls: [Int: ToolCall] = [:]
            var reasoning: [ReasoningBlock] = []
            // The full history stays in `request`; only the copy sent to the model is trimmed.
            var outgoing = request
            outgoing.messages = ContextBudget.trimToolResults(request.messages, limit: contextTokens)

            do {
                for try await event in client.streamChat(outgoing) {
                    switch event {
                    case .text(let delta):
                        text += delta
                        await emit(.assistantDelta(delta))
                    case .reasoning(let delta):
                        await emit(.reasoningDelta(delta))
                    case .reasoningBlock(let block):
                        reasoning.append(block)
                    case .toolCallDelta(let index, let id, let name, let arguments):
                        var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                        if let id, !id.isEmpty { call.id = id }
                        if let name, !name.isEmpty { call.name = name }
                        if let arguments { call.arguments += arguments }
                        calls[index] = call
                    case .usage(let input, let output):
                        await emit(.usage(input: input, output: output))
                    }
                }
                try Task.checkCancellation()
            } catch {
                // Keep whatever text arrived; half-received tool calls are dropped so history stays well-formed.
                if !text.isEmpty { await emit(.message(ChatMessage(role: .assistant, content: text))) }
                throw Task.isCancelled ? CancellationError() : error
            }

            let toolCalls = calls.keys.sorted().compactMap { index -> ToolCall? in
                guard var call = calls[index], !call.name.isEmpty else { return nil }
                if call.id.isEmpty { call.id = "call_\(index)_\(UUID().uuidString.prefix(8))" }
                return call
            }

            let assistant = ChatMessage(role: .assistant, content: text, toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                                        reasoning: reasoning.isEmpty ? nil : reasoning)
            request.messages.append(assistant)
            await emit(.message(assistant))
            if toolCalls.isEmpty { return }

            for call in toolCalls {
                let isPlan = plansHere && call.name == Plan.toolName
                // A plan update is titled update_plan, so the app can show it as the plan rather than a tool.
                let summary = isPlan ? Plan.toolName : tools.summary(call)
                await emit(.toolStarted(call, summary: summary))

                var result: ToolResult
                var denied = false
                if Task.isCancelled {
                    result = ToolResult(text: "cancelled by the user", isError: true)
                } else if isPlan {
                    result = Plan.run(call)
                } else if tools.needsApproval(call), await approve(call, summary) == .deny {
                    denied = true
                    result = ToolResult(text: "The user declined to run this tool call.", isError: true)
                } else {
                    // Output is forwarded through a stream so chunks stay ordered and all arrive before the result.
                    let (output, continuation) = AsyncStream<String>.makeStream()
                    let forwarder = Task {
                        for await chunk in output { await emit(.toolOutput(id: call.id, chunk: chunk)) }
                    }
                    result = await tools.run(call) { continuation.yield($0) }
                    continuation.finish()
                    await forwarder.value
                }

                // Every tool call needs a result message, or the next request is rejected by the API.
                let message = ChatMessage(role: .tool, content: result.text, toolCallID: call.id)
                request.messages.append(message)
                await emit(.toolFinished(id: call.id, result: result, denied: denied))
                await emit(.message(message))
            }
            try Task.checkCancellation()
        }
        throw AgentError.tooManySteps(maxSteps)
    }
}
