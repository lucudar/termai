import Foundation

/// A connector tool as the model sees it: a safe, unique name that maps back to the server's own.
public struct RemoteTool: Sendable {
    public var exposedName: String
    public var connectorName: String
    public var tool: MCPTool
    public var client: MCPClient

    public init(exposedName: String, connectorName: String, tool: MCPTool, client: MCPClient) {
        self.exposedName = exposedName
        self.connectorName = connectorName
        self.tool = tool
        self.client = client
    }

    /// `mcp_<connector>_<tool>` in letters, digits, `_` and `-`, at most 64 characters (what OpenAI and
    /// Anthropic both accept), and not in `taken`.
    public static func exposedName(connector: String, tool: String, taken: Set<String>) -> String {
        func clean(_ text: String) -> String {
            var result = ""
            for scalar in text.unicodeScalars {
                let value = scalar.value
                let allowed = (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
                    || scalar == "_" || scalar == "-"
                result += allowed ? String(scalar) : "_"
            }
            return result
        }
        let base = String(("mcp_" + clean(connector.lowercased()) + "_" + clean(tool)).prefix(64))
        var name = base
        var number = 2
        while taken.contains(name) {
            let suffix = "_\(number)"
            name = String(base.prefix(64 - suffix.count)) + suffix
            number += 1
        }
        return name
    }
}

/// The built-in tools plus the tools of the enabled connectors.
public struct ToolSet: ToolRunning {
    public var base: ToolRunning
    public var remote: [RemoteTool]

    public init(base: ToolRunning, remote: [RemoteTool]) {
        self.base = base
        self.remote = remote
    }

    func remoteTool(_ call: ToolCall) -> RemoteTool? { remote.first { $0.exposedName == call.name } }

    public var specs: [ToolSpec] {
        base.specs + remote.map { entry in
            let tool = entry.tool
            let about = tool.description.isEmpty ? (tool.title ?? tool.name) : tool.description
            return ToolSpec(name: entry.exposedName, description: "[\(entry.connectorName) connector] \(about)",
                            parametersJSON: tool.inputSchemaJSON)
        }
    }

    /// Connector tools ask first unless the server marks them read-only.
    public func needsApproval(_ call: ToolCall) -> Bool {
        guard let remote = remoteTool(call) else { return base.needsApproval(call) }
        return !remote.tool.readOnly
    }

    public func summary(_ call: ToolCall) -> String {
        guard let remote = remoteTool(call) else { return base.summary(call) }
        let arguments = call.arguments.count > 120 ? String(call.arguments.prefix(117)) + "\u{2026}" : call.arguments
        return "\(remote.connectorName) \u{00B7} \(remote.tool.name) \(arguments)"
    }

    public func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult {
        guard let remote = remoteTool(call) else { return await base.run(call, onOutput: onOutput) }
        do {
            return try await remote.client.callTool(remote.tool.name, argumentsJSON: call.arguments.isEmpty ? "{}" : call.arguments)
        } catch {
            return ToolResult(text: "\(remote.connectorName): \(error.localizedDescription)", isError: true)
        }
    }

    /// The arguments of a connector call, pretty-printed for the approval prompt.
    public static func argumentsPreview(_ call: ToolCall) -> String? {
        guard call.name.hasPrefix("mcp_"), let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data), JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let text = String(decoding: pretty, as: UTF8.self)
        return text == "{\n\n}" || text == "{}" ? nil : text
    }
}
