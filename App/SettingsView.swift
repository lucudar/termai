import SwiftUI
import TermCore
import TermSSH

/// Gateways, environments, agent behaviour and appearance.
struct SettingsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.profiles) { profile in
                        NavigationLink {
                            GatewayEditor(profile: profile, apiKey: model.apiKey(for: profile), isNew: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(profile.name)
                                    if profile.id == model.activeProfile?.id {
                                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(profile.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    NavigationLink {
                        GatewayEditor(profile: Profile(name: "", baseURL: "https://"), apiKey: "", isNew: true)
                    } label: {
                        Label("Add gateway", systemImage: "plus")
                    }
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("OpenAI-compatible or Anthropic Messages endpoints: OpenRouter, OpenAI, Anthropic, a LiteLLM or other proxy, Ollama. Keys stay in this device's Keychain.")
                }

                Section {
                    ForEach(model.hosts) { host in
                        NavigationLink {
                            HostEditor(host: host, secret: model.hostSecret(for: host),
                                       passphrase: model.hostPassphrase(for: host), isNew: false)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                Text(host.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    NavigationLink {
                        HostEditor(host: SSHHost(name: "", host: "", username: ""), secret: "", passphrase: "", isNew: true)
                    } label: {
                        Label("Add SSH environment", systemImage: "plus")
                    }
                } header: {
                    Text("Environments")
                } footer: {
                    Text("On This iPhone the agent works in an on-device workspace. On an SSH environment it runs commands, and with a folder open it reads, edits and searches the files there.")
                }

                Section {
                    Picker("Permissions", selection: Binding(
                        get: { model.settings.approvalMode },
                        set: { model.setApproval($0) })) {
                        Text("Ask before acting").tag(ApprovalMode.ask)
                        Text("Bypass permissions").tag(ApprovalMode.auto)
                    }
                    Toggle("Always start with the default model", isOn: Binding(
                        get: { model.settings.alwaysStartWithDefault ?? false },
                        set: { value in model.update { $0.alwaysStartWithDefault = value } }))
                    NavigationLink("System prompt") {
                        TextEditor(text: binding(\.systemPrompt))
                            .font(.system(.body, design: .monospaced))
                            .padding(8)
                            .navigationTitle("System prompt")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("Ask before acting: commands, file writes and web requests wait for your OK. Bypass runs them right away. New sessions can go back to the gateway's default model and effort.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: binding(\.themeID)) {
                        ForEach(Theme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    Stepper("Font size: \(Int(model.settings.fontSize))", value: binding(\.fontSize), in: 10...22, step: 1)
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Files the agent writes on this iPhone are in Files › On My iPhone › TermAI.\nTermAI \(Self.version)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

/// One gateway, laid out like a desktop app's third-party inference settings.
private struct GatewayEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    @State var apiKey: String
    let isNew: Bool
    @State private var modelsText = ""
    @State private var contextText = ""
    @State private var timeoutText = ""
    @State private var maxTokensText = ""
    @State private var headers: [HeaderRow] = []
    @State private var loaded = false
    @State private var showKey = false
    @State private var isFetching = false
    @State private var fetchMessage: String?

    struct HeaderRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    private var modelIDs: [String] {
        var seen = Set<String>()
        return modelsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// What the default-model picker can offer: the list, or what discovery found.
    private var candidates: [String] { modelIDs.isEmpty ? (profile.discoveredModels ?? []) : modelIDs }

    private var cleanHeaders: [HTTPHeader] {
        headers.map { HTTPHeader(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.name.isEmpty }
    }

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: profile.baseURL)?.host != nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name, e.g. openrouter", text: $profile.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("API format", selection: Binding(
                    get: { profile.format },
                    set: { profile.apiFormat = $0 })) {
                    ForEach(APIFormat.allCases, id: \.self) { format in
                        Text(format.title).tag(format)
                    }
                }
                LabeledContent("Credential kind", value: "Static API key")
                TextField("https://llm-gateway.example.com/v1", text: $profile.baseURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Group {
                        if showKey {
                            TextField("API key", text: $apiKey)
                        } else {
                            SecureField("API key", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showKey ? "Hide key" : "Show key")
                }
                Picker("Auth scheme", selection: Binding(
                    get: { profile.auth },
                    set: { profile.authScheme = $0 })) {
                    ForEach(AuthScheme.allCases, id: \.self) { scheme in
                        Text(scheme.title).tag(scheme)
                    }
                }
            } header: {
                Text("Gateway credentials")
            } footer: {
                Text("OpenAI-compatible covers OpenAI, OpenRouter, LiteLLM, Ollama and most proxies; Anthropic Messages is for api.anthropic.com and gateways that speak its /messages. Base URL is the part before /chat/completions or /messages, usually ending in /v1. Bearer sends Authorization: Bearer <key>; x-api-key sends the key in an x-api-key header, the Anthropic default. The key is stored in the Keychain.")
            }

            Section {
                ForEach($headers) { $row in
                    HStack {
                        TextField("Header", text: $row.name)
                        TextField("Value", text: $row.value)
                    }
                    .font(.system(.callout, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button {
                    headers.append(HeaderRow(name: "", value: ""))
                } label: {
                    Label("Add header", systemImage: "plus")
                }
            } header: {
                Text("Custom headers")
            } footer: {
                Text("Sent with every request, for routing or a tenant, e.g. HTTP-Referer. Swipe left to remove one.")
            }

            Section {
                HStack {
                    Text("Stream idle timeout")
                    Spacer()
                    TextField("300", text: $timeoutText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("s").foregroundStyle(.secondary)
                }
            } footer: {
                Text("How long to wait for the next bytes of a streamed answer before giving up. Default 300.")
            }

            Section {
                Toggle("Model discovery", isOn: Binding(
                    get: { profile.discoverModels ?? true },
                    set: { profile.discoverModels = $0 }))
                TextEditor(text: $modelsText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 110)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    fetchModels()
                } label: {
                    HStack {
                        Text("Fetch from gateway")
                        if isFetching {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isFetching || !canSave)
                if let fetchMessage {
                    Text(fetchMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Models")
            } footer: {
                Text("With discovery on and the list empty, the model picker shows what the gateway's /models returns. A list here overrides it: one model ID per line, the first is the default.")
            }

            Section {
                if !candidates.isEmpty {
                    Picker("Default model", selection: Binding(
                        get: { profile.defaultModel.flatMap { candidates.contains($0) ? $0 : nil } ?? candidates[0] },
                        set: { profile.defaultModel = $0 })) {
                        ForEach(candidates, id: \.self) { Text($0).tag($0) }
                    }
                }
                Picker("Default effort", selection: Binding(
                    get: { profile.defaultEffort },
                    set: { profile.defaultEffort = $0 })) {
                    Text("Auto").tag(Effort?.none)
                    ForEach(Effort.allCases, id: \.self) { effort in
                        Text(effort.title).tag(Effort?.some(effort))
                    }
                }
                TextField("Context window, e.g. 200k", text: $contextText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                if profile.format == .anthropic {
                    TextField("Max output tokens, default 32000", text: $maxTokensText)
                        .keyboardType(.numberPad)
                }
            } footer: {
                Text("Effort goes out as reasoning_effort (Extra as xhigh), or as output_config.effort in the Anthropic format; Auto sends nothing, and models that do not reason may reject the rest. The context window drives the ring under the input and when old tool output is shortened; empty means 128k.")
            }

            if !isNew {
                Section {
                    Button("Delete gateway", role: .destructive) {
                        model.deleteProfile(profile)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New gateway" : profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            modelsText = profile.models.joined(separator: "\n")
            contextText = profile.contextWindow.map { String($0) } ?? ""
            timeoutText = profile.idleTimeout.map { String(Int($0)) } ?? ""
            maxTokensText = profile.maxTokens.map { String($0) } ?? ""
            headers = (profile.headers ?? []).map { HeaderRow(name: $0.name, value: $0.value) }
        }
    }

    private func save() {
        var saved = profile
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        saved.baseURL = saved.baseURL.trimmingCharacters(in: .whitespaces)
        saved.models = modelIDs
        saved.contextWindow = Profile.parseContextWindow(contextText)
        saved.idleTimeout = Double(timeoutText.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 5 ? $0 : nil }
        saved.maxTokens = Int(maxTokensText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        let list = cleanHeaders
        saved.headers = list.isEmpty ? nil : list
        if let chosen = saved.defaultModel, !saved.pickerModels.contains(chosen) { saved.defaultModel = nil }
        model.saveProfile(saved, apiKey: apiKey)
        dismiss()
    }

    private func fetchModels() {
        isFetching = true
        fetchMessage = nil
        let baseURL = profile.baseURL.trimmingCharacters(in: .whitespaces)
        let key = apiKey
        let scheme = profile.auth
        let format = profile.format
        let extra = cleanHeaders
        let keepList = !modelIDs.isEmpty
        Task {
            do {
                let fetched = try await OpenAIClient().listModels(baseURL: baseURL, apiKey: key, authScheme: scheme,
                                                                  headers: extra, format: format)
                profile.discoveredModels = fetched
                if keepList {
                    let existing = Set(modelIDs)
                    let added = fetched.filter { !existing.contains($0) }
                    modelsText = (modelIDs + added).joined(separator: "\n")
                    fetchMessage = "\(fetched.count) models found, \(added.count) added to the list."
                } else {
                    fetchMessage = "\(fetched.count) models found. The picker shows them while the list above is empty."
                }
            } catch {
                fetchMessage = "Failed: \(error.localizedDescription)"
            }
            isFetching = false
        }
    }
}

struct HostEditor: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var host: SSHHost
    @State var secret: String
    @State var passphrase: String
    let isNew: Bool

    private var canSave: Bool {
        ![host.name, host.host, host.username].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && (1...65_535).contains(host.port)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name, e.g. web1", text: $host.name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Hostname or IP", text: $host.host)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port", value: $host.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                TextField("Username", text: $host.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }

            Section {
                TextField("~/app or /srv/app", text: Binding(
                    get: { host.workingDirectory ?? "" },
                    set: { host.workingDirectory = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Project folder")
            } footer: {
                Text("Optional. File tools work in this folder and commands start in it; its AGENTS.md or CLAUDE.md is read. Same as /cd.")
            }

            Section {
                Picker("Method", selection: $host.auth) {
                    Text("Password").tag(SSHHost.Auth.password)
                    Text("Private key").tag(SSHHost.Auth.privateKey)
                }
                .pickerStyle(.segmented)
                .onChange(of: host.auth) {
                    secret = ""
                    passphrase = ""
                }
                if host.auth == .password {
                    SecureField("Password", text: $secret)
                } else {
                    TextEditor(text: $secret)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Passphrase (if the key has one)", text: $passphrase)
                }
            } header: {
                Text("Authentication")
            } footer: {
                Text(host.auth == .password
                     ? "Stored in the Keychain on this device."
                     : "Paste an Ed25519 or RSA private key in OpenSSH format (-----BEGIN OPENSSH PRIVATE KEY-----). Stored in the Keychain on this device.")
            }

            if let key = host.trustedHostKey {
                Section {
                    Text(SSHKeys.fingerprint(ofOpenSSHKey: key)).font(.system(.caption, design: .monospaced))
                    Button("Forget host key", role: .destructive) { host.trustedHostKey = nil }
                } header: {
                    Text("Trusted host key")
                } footer: {
                    Text("Recorded on first connection. Connections are refused if the server presents a different key.")
                }
            }

            if !isNew {
                Section {
                    Button("Delete environment", role: .destructive) {
                        model.deleteHost(host)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(isNew ? "New SSH environment" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var saved = host
                    saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                    saved.host = saved.host.trimmingCharacters(in: .whitespaces)
                    saved.username = saved.username.trimmingCharacters(in: .whitespaces)
                    saved.workingDirectory = saved.workingDirectory?.trimmingCharacters(in: .whitespaces)
                    if saved.workingDirectory?.isEmpty == true { saved.workingDirectory = nil }
                    model.saveHost(saved, secret: secret, passphrase: passphrase)
                    if isNew { model.selectHost(saved.id) }
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }
}
