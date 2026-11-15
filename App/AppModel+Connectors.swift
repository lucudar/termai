import Foundation
import Observation
import SwiftUI
import TermCore

@MainActor
extension AppModel {
    // MARK: Connectors

    /// More tools than this crowds the model's context and some gateways refuse long tool lists.
    static let remoteToolLimit = 96

    var enabledConnectorCount: Int { connectors.filter(\.isEnabled).count }

    func connectorToken(_ connector: Connector) -> String { secrets.secret(for: connector.secretKey) ?? "" }

    func saveConnector(_ connector: Connector, token: String) {
        var connector = connector
        connector.name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        connector.url = connector.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = connectors.firstIndex(where: { $0.id == connector.id }) {
            connectors[index] = connector
        } else {
            connectors.append(connector)
        }
        storage.saveConnectors(connectors)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        secrets.setSecret(trimmed.isEmpty ? nil : trimmed, for: connector.secretKey)
        forget(connector.id)
        if connector.isEnabled { refreshConnector(connector.id) }
    }

    func deleteConnector(_ connector: Connector) {
        connectors.removeAll { $0.id == connector.id }
        storage.saveConnectors(connectors)
        secrets.setSecret(nil, for: connector.secretKey)
        forget(connector.id)
    }

    func setConnector(_ id: UUID, enabled: Bool) {
        guard let index = connectors.firstIndex(where: { $0.id == id }) else { return }
        connectors[index].enabled = enabled
        storage.saveConnectors(connectors)
        if enabled, connectorTools[id] == nil { refreshConnector(id) }
    }

    func forget(_ id: UUID) {
        mcpClients[id] = nil
        connectorTools[id] = nil
        connectorErrors[id] = nil
    }

    func client(for connector: Connector) throws -> MCPClient {
        if let client = mcpClients[connector.id] { return client }
        let made = try MCPClient(url: connector.url, token: connectorToken(connector), headers: connector.headers ?? [])
        mcpClients[connector.id] = made
        return made
    }

    /// Lists a connector's tools again; the connectors sheet shows the count or the error.
    func refreshConnector(_ id: UUID) {
        guard let connector = connectors.first(where: { $0.id == id }), !connectorBusy.contains(id) else { return }
        connectorBusy.insert(id)
        connectorErrors[id] = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let tools = try await self.client(for: connector).listTools()
                self.connectorTools[id] = tools
            } catch {
                self.connectorErrors[id] = error.localizedDescription
                self.mcpClients[id] = nil
            }
            self.connectorBusy.remove(id)
        }
    }

    /// Enabled connectors whose tools are not known yet, e.g. when the sheet opens.
    func refreshUnknownConnectors() {
        for connector in connectors where connector.isEnabled && connectorTools[connector.id] == nil {
            refreshConnector(connector.id)
        }
    }

    /// Tries a connector before it is saved. Returns its tools or throws why it failed.
    func testConnector(url: String, token: String, headers: [HTTPHeader]) async throws -> [MCPTool] {
        let probe = try MCPClient(url: url, token: token, headers: headers)
        return try await probe.listTools()
    }

    /// The tools of every enabled connector for the next run. A connector that fails is skipped with a note.
    func remoteTools() async -> [RemoteTool] {
        var found: [RemoteTool] = []
        var taken = Set<String>()
        for connector in connectors where connector.isEnabled {
            do {
                let server = try self.client(for: connector)
                let tools: [MCPTool]
                if let known = connectorTools[connector.id] {
                    tools = known
                } else {
                    tools = try await server.listTools()
                    connectorTools[connector.id] = tools
                }
                for tool in tools {
                    let name = RemoteTool.exposedName(connector: connector.name, tool: tool.name, taken: taken)
                    taken.insert(name)
                    found.append(RemoteTool(exposedName: name, connectorName: connector.name, tool: tool, client: server))
                }
            } catch {
                connectorErrors[connector.id] = error.localizedDescription
                mcpClients[connector.id] = nil
                info("connector \(connector.name): \(error.localizedDescription). continuing without it")
            }
        }
        if found.count > Self.remoteToolLimit {
            info("connectors offer \(found.count) tools; the agent gets the first \(Self.remoteToolLimit). turn off the ones you do not need in Connectors")
            found = Array(found.prefix(Self.remoteToolLimit))
        }
        return found
    }

    func loadConnectorsDemo() {
        let wiki = Connector(name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp")
        let github = Connector(name: "GitHub", url: "https://api.githubcopilot.com/mcp/", enabled: false)
        connectors = [wiki, github]
        connectorTools[wiki.id] = [
            MCPTool(name: "read_wiki_structure", description: "Get a list of documentation topics for a GitHub repository", readOnly: true),
            MCPTool(name: "read_wiki_contents", description: "View documentation about a GitHub repository", readOnly: true),
            MCPTool(name: "ask_question", description: "Ask any question about a GitHub repository", readOnly: true),
        ]
    }
}
