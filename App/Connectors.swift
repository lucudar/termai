import SwiftUI
import TermCore

/// A ready-made connector to start from.
struct ConnectorPreset: Identifiable {
    let id: String
    let name: String
    let url: String
    let symbol: String
    let about: String
    /// What the token field asks for; nil when the server needs none.
    let tokenHint: String?

    static let all: [ConnectorPreset] = [
        ConnectorPreset(id: "deepwiki", name: "DeepWiki", url: "https://mcp.deepwiki.com/mcp", symbol: "book.pages",
                        about: "Docs and answers about any public GitHub repository. No key needed.", tokenHint: nil),
        ConnectorPreset(id: "context7", name: "Context7", url: "https://mcp.context7.com/mcp", symbol: "books.vertical",
                        about: "Current documentation for libraries and frameworks. Works without a key; a Context7 API key raises the limits.",
                        tokenHint: "Context7 API key (optional)"),
        ConnectorPreset(id: "github", name: "GitHub", url: "https://api.githubcopilot.com/mcp/",
                        symbol: "chevron.left.forwardslash.chevron.right",
                        about: "Repositories, issues, pull requests and code search. Needs a GitHub personal access token.",
                        tokenHint: "GitHub personal access token"),
    ]

    func connector() -> Connector { Connector(name: name, url: url) }
}

/// "Manage connectors": remote MCP servers whose tools the agent can use in every chat.
struct ConnectorsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.connectors) { connector in
                        NavigationLink {
                            ConnectorEditor(connector: connector, token: model.connectorToken(connector), isNew: false)
                        } label: {
                            ConnectorRow(connector: connector)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                model.setConnector(connector.id, enabled: !connector.isEnabled)
                            } label: {
                                Label(connector.isEnabled ? "Turn off" : "Turn on",
                                      systemImage: connector.isEnabled ? "pause.circle" : "play.circle")
                            }
                            .tint(connector.isEnabled ? .gray : .green)
                        }
                    }
                    if model.connectors.isEmpty {
                        Text("No connectors yet. Add one below; DeepWiki works without a key.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your connectors")
                } footer: {
                    Text("The agent can use the tools of every connector that is on. Tools the server marks read-only run right away; the rest ask first, unless permissions are bypassed. Swipe a connector to turn it off.")
                }

                Section {
                    ForEach(ConnectorPreset.all) { preset in
                        NavigationLink {
                            ConnectorEditor(connector: preset.connector(), token: "", isNew: true,
                                            about: preset.about, tokenHint: preset.tokenHint)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: preset.symbol)
                                    .frame(width: 28)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                    Text(preset.about).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    NavigationLink {
                        ConnectorEditor(connector: Connector(name: "", url: "https://"), token: "", isNew: true)
                    } label: {
                        Label("Custom MCP server", systemImage: "plus")
                    }
                } header: {
                    Text("Add")
                } footer: {
                    Text("Remote servers over Streamable HTTP, with an optional bearer token and headers. Servers that only allow browser sign-in (OAuth) are not supported yet.")
                }
            }
            .navigationTitle("Connectors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { model.refreshUnknownConnectors() }
        }
    }
}

/// A connector in the list: on or off, and how many tools it offers or why it failed.
struct ConnectorRow: View {
    @Environment(AppModel.self) var model
    let connector: Connector

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(connector.isEnabled ? (model.connectorErrors[connector.id] == nil ? Color.green : Color.orange) : Color.gray.opacity(0.5))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.name.isEmpty ? "Connector" : connector.name)
                Group {
                    if !connector.isEnabled {
                        Text("Off")
                    } else if model.connectorBusy.contains(connector.id) {
                        Text("Connecting…")
                    } else if let error = model.connectorErrors[connector.id] {
                        Text(error).foregroundStyle(.orange)
                    } else if let tools = model.connectorTools[connector.id] {
                        Text(tools.count == 1 ? "1 tool" : "\(tools.count) tools")
                    } else {
                        Text(URL(string: connector.url)?.host ?? connector.url)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.connectorBusy.contains(connector.id) {
                ProgressView().controlSize(.small)
            }
        }
    }
}

/// One connector: address, token, headers, a connection test, and the tools it offers.
struct ConnectorEditor: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var connector: Connector
    @State var token: String
    let isNew: Bool
    var about: String? = nil
    var tokenHint: String? = nil
    @State var headers: [EditableHeader] = []
    @State var loaded = false
    @State var showToken = false
    @State var testing = false
    @State var testMessage: String?
    @State var testFailed = false
    @State var tools: [MCPTool] = []

    struct EditableHeader: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    private var canSave: Bool {
        let url = connector.url.trimmingCharacters(in: .whitespaces).lowercased()
        return !connector.name.trimmingCharacters(in: .whitespaces).isEmpty
            && (url.hasPrefix("https://") || url.hasPrefix("http://")) && url.count > 8
    }

    private var cleanHeaders: [HTTPHeader] {
        headers.compactMap { row in
            let name = row.name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : HTTPHeader(name: name, value: row.value.trimmingCharacters(in: .whitespaces))
        }
    }

    var body: some View {
        Form {
            if let about {
                Section {
                    Text(about).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Server") {
                TextField("Name", text: $connector.name)
                    .autocorrectionDisabled()
                TextField("https://example.com/mcp", text: $connector.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("On", isOn: Binding(
                    get: { connector.isEnabled },
                    set: { connector.enabled = $0 }))
            }

            Section {
                HStack {
                    Group {
                        if showToken {
                            TextField(tokenHint ?? "Token (optional)", text: $token)
                        } else {
                            SecureField(tokenHint ?? "Token (optional)", text: $token)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showToken ? "Hide token" : "Show token")
                }
            } header: {
                Text("Token")
            } footer: {
                Text("Sent as Authorization: Bearer. Stored in this device's Keychain.")
            }

            Section {
                ForEach($headers) { $row in
                    HStack {
                        TextField("Header", text: $row.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Divider()
                        TextField("Value", text: $row.value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .font(.system(.callout, design: .monospaced))
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button {
                    headers.append(EditableHeader(name: "", value: ""))
                } label: {
                    Label("Add header", systemImage: "plus")
                }
            } header: {
                Text("Headers")
            } footer: {
                Text("Extra HTTP headers some servers want, e.g. X-API-Key.")
            }

            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "bolt.horizontal")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || !canSave)
                if let testMessage {
                    Text(testMessage)
                        .font(.caption)
                        .foregroundStyle(testFailed ? Color.red : Color.green)
                }
                if !tools.isEmpty {
                    DisclosureGroup(tools.count == 1 ? "1 tool" : "\(tools.count) tools") {
                        ForEach(tools, id: \.name) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tool.name).font(.system(.callout, design: .monospaced))
                                    if tool.readOnly {
                                        Text("read-only").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if !tool.description.isEmpty {
                                    Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                    }
                }
            }

            if !isNew {
                Section {
                    Button("Delete connector", role: .destructive) {
                        model.deleteConnector(connector)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New connector" : (connector.name.isEmpty ? "Connector" : connector.name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = connector
                    saved.headers = cleanHeaders.isEmpty ? nil : cleanHeaders
                    model.saveConnector(saved, token: token)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            headers = (connector.headers ?? []).map { EditableHeader(name: $0.name, value: $0.value) }
            tools = model.connectorTools[connector.id] ?? []
        }
    }

    private func test() {
        testing = true
        testMessage = nil
        let url = connector.url
        let secret = self.token
        let extra = cleanHeaders
        Task {
            do {
                let found = try await model.testConnector(url: url, token: secret, headers: extra)
                tools = found
                testFailed = false
                testMessage = found.isEmpty ? "Connected, but the server lists no tools." : "Connected."
            } catch {
                tools = []
                testFailed = true
                testMessage = error.localizedDescription
            }
            testing = false
        }
    }
}
