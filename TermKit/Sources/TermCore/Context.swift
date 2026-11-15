import Foundation

/// Keeps long agent runs inside the model's context window.
public enum ContextBudget {
    /// Rough token count: about three characters per token, plus a little per message.
    public static func estimate(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            let calls = (message.toolCalls ?? []).reduce(0) { $0 + $1.name.count + $1.arguments.count }
            // An image costs the model about a thousand tokens, whatever its data URL's length.
            let images = (message.images?.count ?? 0) * 1_000
            return total + 4 + images + (message.content.count + calls) / 3
        }
    }

    /// Once the history passes `fraction` of `limit`, shortens old tool output (keeping the newest
    /// `keepRecent` results whole). The model can always run a tool again for the full text.
    public static func trimToolResults(_ messages: [ChatMessage], limit: Int, fraction: Double = 0.6,
                                       keepRecent: Int = 6) -> [ChatMessage] {
        guard estimate(messages) > Int(Double(limit) * fraction) else { return messages }
        let toolIndices = messages.indices.filter { messages[$0].role == .tool }
        let recent = Set(toolIndices.suffix(keepRecent))
        var trimmed = messages
        for index in toolIndices where !recent.contains(index) {
            let content = trimmed[index].content
            guard content.count > 1_200 else { continue }
            trimmed[index].content = String(content.prefix(500))
                + "\n… [\(content.count - 1_000) characters trimmed to save context; run the tool again if you need them] …\n"
                + String(content.suffix(500))
        }
        return trimmed
    }
}

/// `/compact`: the model summarizes the conversation and the summary replaces the history.
public enum Compaction {
    public static let systemPrompt = "You write handoff summaries of conversations between a user and a coding agent, so the agent can continue the work with a fresh context."

    public static let instructions = """
    Summarize the conversation above for a handoff. Cover what the user wants and their constraints, \
    decisions made, files created or changed (with paths) and how, important command output and errors, \
    the current state, and open questions or next steps. Keep names, paths, commands and numbers exact. \
    Plain text, under 400 words.
    """

    /// The history is flattened to text, so providers that are strict about tool messages accept it.
    public static func messages(for history: [ChatMessage], contextTokens: Int) -> [ChatMessage] {
        let budget = max(Int(Double(contextTokens) * 3 * 0.6), 12_000)
        let transcript = Truncate.middle(render(history), limit: budget)
        return [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: "Conversation so far:\n\n\(transcript)\n\n---\n\(instructions)"),
        ]
    }

    static func render(_ history: [ChatMessage]) -> String {
        history.map { message -> String in
            switch message.role {
            case .system:
                return "SYSTEM: " + message.content
            case .user:
                let count = message.images?.count ?? 0
                return "USER: " + message.content + (count == 0 ? "" : " [\(count) image\(count == 1 ? "" : "s") attached]")
            case .tool:
                return "TOOL RESULT: " + Truncate.middle(message.content, limit: 1_500)
            case .assistant:
                var text = "ASSISTANT: " + message.content
                for call in message.toolCalls ?? [] {
                    text += "\n→ \(call.name) " + Truncate.middle(call.arguments, limit: 1_500)
                }
                return text
            }
        }
        .joined(separator: "\n\n")
    }

    /// What the history becomes after compacting.
    public static func replacement(summary: String) -> [ChatMessage] {
        [
            ChatMessage(role: .user, content: "[Summary of our conversation so far; the earlier messages were compacted]\n\n" + summary),
            ChatMessage(role: .assistant, content: "Got it. I'll continue from this summary."),
        ]
    }
}
