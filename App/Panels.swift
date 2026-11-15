import SwiftUI
import TermCore

// MARK: New chat

/// A new chat: a quiet mark, the setup step while no gateway exists yet, and the latest note if there is one.
struct EmptyChatView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let palette = model.palette
        VStack(spacing: 14) {
            Image(systemName: "sparkle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(palette.accent.opacity(0.6))
            if model.profiles.isEmpty {
                Text("Add a gateway, a base URL and an API key, to start.")
                    .font(palette.small)
                    .foregroundStyle(palette.dim)
                Button("Add a gateway") { model.showSettings = true }
                    .font(palette.bold)
                    .tint(palette.accent)
                    .glassButton(prominent: true)
                Text("TermAI \(AppInfo.version)")
                    .font(.caption2)
                    .foregroundStyle(palette.dim.opacity(0.7))
            }
            if let status = model.homeStatus {
                Text(status.text)
                    .font(palette.small)
                    .foregroundStyle(status.kind == .error ? palette.error : palette.dim)
                    .lineLimit(5)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { Keyboard.hide() }
    }
}

// MARK: Menus shared by the chips and the terminal

struct EnvironmentMenuContent: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Section("Local") {
            Button {
                model.selectHost(nil)
            } label: {
                if model.activeHost == nil {
                    Label("This iPhone", systemImage: "checkmark")
                } else {
                    Label("This iPhone", systemImage: "iphone")
                }
            }
        }
        Section("SSH") {
            ForEach(model.hosts) { host in
                Button {
                    model.selectHost(host.id)
                } label: {
                    if host.id == model.activeHost?.id {
                        Label(host.name, systemImage: "checkmark")
                    } else {
                        Label(host.name, systemImage: "server.rack")
                    }
                }
            }
        }
        Button {
            model.present(.host(SSHHost(name: "", host: "", username: "")))
        } label: {
            Label("New environment", systemImage: "plus")
        }
    }
}

struct FolderMenuContent: View {
    @Environment(AppModel.self) var model

    var body: some View {
        if let host = model.activeHost {
            let recents = host.recentDirectories ?? []
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button {
                            model.openFolder(path)
                        } label: {
                            if path == host.workingDirectory {
                                Label(path, systemImage: "checkmark")
                            } else {
                                Text(path)
                            }
                        }
                    }
                }
            }
            Button {
                model.present(.folder)
            } label: {
                Label("Open folder…", systemImage: "folder.badge.plus")
            }
            if host.workingDirectory != nil {
                Button {
                    model.closeFolder()
                } label: {
                    Label("Close folder", systemImage: "xmark")
                }
            }
        } else {
            Section("This iPhone") {
                Label("On-device workspace", systemImage: "checkmark")
            }
            Text("Folders on a server open in an SSH environment")
        }
    }
}

// MARK: Chats

/// Every saved chat, newest first: search, open one, swipe to delete.
struct ChatsView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var query = ""

    private var sessions: [SessionSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.recentSessions }
        return model.recentSessions.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { summary in
                    Button {
                        model.openSession(summary.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.title)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(summary.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if summary.id == model.session.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { sessions[$0].id }
                    ids.forEach { model.deleteSession($0) }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No chats yet" : "No chats match",
                                           systemImage: "bubble.left.and.bubble.right")
                }
            }
            .searchable(text: $query, prompt: "Search chats")
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        model.newSession()
                        dismiss()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// "Open folder…": a folder on the SSH environment for the file tools and commands.
struct FolderSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var path = ""

    private var canOpen: Bool {
        model.activeHost != nil && !path.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("~/app or /srv/app", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(submit)
                } header: {
                    Text(model.activeHost.map { "Folder on \($0.name)" } ?? "Folder")
                } footer: {
                    Text(model.activeHost == nil
                         ? "Pick an SSH environment first."
                         : "File tools work there and commands start in it. Its AGENTS.md or CLAUDE.md is read.")
                }
                if let recents = model.activeHost?.recentDirectories, !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { recent in
                            Button {
                                path = recent
                                submit()
                            } label: {
                                Label(recent, systemImage: "folder")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Open folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: submit).disabled(!canOpen)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() {
        guard canOpen else { return }
        model.openFolder(path)
        dismiss()
    }
}
