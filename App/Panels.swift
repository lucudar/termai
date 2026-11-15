import SwiftUI
import TermCore

// MARK: Header

struct HeaderBar: View {
    @Environment(AppModel.self) var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        let palette = model.palette
        HStack(spacing: 16) {
            Button {
                inputFocused.wrappedValue = false
                model.toggleSidebar()
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .accessibilityLabel("Sessions")

            Text(model.showsHome ? "New session" : model.session.title)
                .font(palette.title)
                .foregroundStyle(palette.text)
                .lineLimit(1)

            Spacer(minLength: 8)

            if model.isRunning {
                ProgressView().controlSize(.small).tint(palette.accent)
            }
            Button {
                model.input = "!"
                inputFocused.wrappedValue = true
            } label: {
                Image(systemName: "terminal")
            }
            .accessibilityLabel("Run a command yourself")
            Button {
                model.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New session")
        }
        .font(.system(size: 17))
        .foregroundStyle(palette.dim)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: Home

/// What a new session shows: a greeting, where the agent will work, and the last session.
struct HomeView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let palette = model.palette
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                HStack(spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    Text("What are we building?")
                        .font(palette.greeting)
                        .foregroundStyle(palette.text)
                }
                .multilineTextAlignment(.center)

                EnvironmentCard(palette: palette)

                if let recent = model.recentSessions.first(where: { $0.id != model.session.id }) {
                    Button {
                        model.openSession(recent.id)
                    } label: {
                        HStack(spacing: 8) {
                            Text("Recent").foregroundStyle(palette.accent)
                            Text(recent.title).foregroundStyle(palette.text).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(palette.dim)
                        }
                        .font(palette.small)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(palette.code.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.dim.opacity(0.18)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if model.profiles.isEmpty {
                    VStack(spacing: 10) {
                        Text("No gateway yet. Add a base URL and an API key to start.")
                            .font(palette.small)
                            .foregroundStyle(palette.dim)
                        Button("Add a gateway") { model.showSettings = true }
                            .font(palette.bold)
                            .tint(palette.accent)
                    }
                    .multilineTextAlignment(.center)
                } else if let status = model.homeStatus {
                    Text(status.text)
                        .font(palette.small)
                        .foregroundStyle(status.kind == .error ? palette.error : palette.dim)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                } else {
                    Text("Type / for commands, or ! to run a command yourself.")
                        .font(palette.small)
                        .foregroundStyle(palette.dim)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// The folder and the environment the next session works in.
private struct EnvironmentCard: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let host = model.activeHost
        let folder = host?.workingDirectory
        VStack(spacing: 0) {
            Menu {
                FolderMenuContent()
            } label: {
                row(icon: "folder",
                    title: host == nil ? "On-device workspace" : (folder ?? "Open a folder…"),
                    trailing: host == nil || folder != nil ? "checkmark" : "chevron.down")
            }
            Rectangle().fill(palette.dim.opacity(0.18)).frame(height: 1)
            Menu {
                EnvironmentMenuContent()
            } label: {
                row(icon: host == nil ? "iphone" : "server.rack",
                    title: host.map { "\($0.name) · \($0.address)" } ?? "Choose environment",
                    trailing: "chevron.down")
            }
        }
        .background(palette.code.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.dim.opacity(0.18)))
    }

    private func row(icon: String, title: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(palette.dim)
            Text(title).foregroundStyle(palette.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Image(systemName: trailing).foregroundStyle(trailing == "checkmark" ? palette.accent : palette.dim)
        }
        .font(palette.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: Menus shared by the home card and the chips

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
            model.editingHost = SSHHost(name: "", host: "", username: "")
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
                model.promptForFolder = true
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

// MARK: Sidebar

/// Sessions, search and the active gateway, sliding in from the left.
struct SidebarView: View {
    @Environment(AppModel.self) var model
    @State var query = ""
    @State var searching = false
    @FocusState var searchFocused: Bool

    private var sessions: [SessionSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return model.recentSessions }
        return model.recentSessions.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TermAI").font(.system(size: 17, weight: .semibold)).foregroundStyle(palette.text)
                Spacer()
                Button {
                    model.showSidebar = false
                } label: {
                    Image(systemName: "sidebar.left").font(.system(size: 17)).foregroundStyle(palette.dim)
                }
                .accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 2) {
                item("square.and.pencil", "New session", palette) {
                    model.newSession()
                    model.showSidebar = false
                }
                item("magnifyingglass", "Search", palette) {
                    searching.toggle()
                    if searching {
                        searchFocused = true
                    } else {
                        query = ""
                    }
                }
                if searching {
                    TextField("Search sessions", text: $query)
                        .font(palette.small)
                        .foregroundStyle(palette.text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(palette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                }
                item("slider.horizontal.3", "Customize", palette) {
                    model.showSidebar = false
                    model.showSettings = true
                }
            }
            .padding(.horizontal, 8)

            Text("Recents")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.dim)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sessions) { summary in
                        Button {
                            model.openSession(summary.id)
                            model.showSidebar = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.title)
                                    .font(palette.small)
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                                Text(summary.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.dim)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(summary.id == model.session.id ? palette.background.opacity(0.6) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                model.deleteSession(summary.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    if sessions.isEmpty {
                        Text(query.isEmpty ? "Sessions you start will show up here." : "No sessions match.")
                            .font(palette.small)
                            .foregroundStyle(palette.dim)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle().fill(palette.dim.opacity(0.18)).frame(height: 1)
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.selectProfile(profile.id)
                        } label: {
                            if profile.id == model.activeProfile?.id {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                    Divider()
                    Button {
                        model.showSidebar = false
                        model.showSettings = true
                    } label: {
                        Label("Gateways…", systemImage: "network")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle").foregroundStyle(palette.accent)
                        Text(model.activeProfile?.name ?? "No gateway").foregroundStyle(palette.text).lineLimit(1)
                        Text("· Gateway").foregroundStyle(palette.dim)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(palette.dim)
                    }
                    .font(palette.small)
                }
                Spacer(minLength: 4)
                Button {
                    model.showSidebar = false
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(palette.dim)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.sidebar.ignoresSafeArea())
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
            if value.translation.width < -60 { model.showSidebar = false }
        })
    }

    private func item(_ icon: String, _ title: String, _ palette: Palette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(palette.font)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
