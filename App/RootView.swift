import SwiftUI
import TermCore

/// Chat, Terminal and Settings as tabs, the sessions sidebar over them, and every sheet in one place.
struct RootView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack(alignment: .leading) {
            TabView(selection: $model.tab) {
                ChatScreen()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(AppTab.chat)
                TerminalScreen()
                    .tabItem { Label("Terminal", systemImage: "apple.terminal") }
                    .tag(AppTab.terminal)
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .minimizingTabBar()

            if model.showSidebar {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { model.showSidebar = false }
                    .transition(.opacity)
                SidebarView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.12), value: model.showSidebar)
        .tint(palette.accent)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .share(let text):
                    ShareSheet(text: text)
                case .host(let host):
                    NavigationStack {
                        HostEditor(host: host, secret: "", passphrase: "", isNew: true)
                    }
                case .files:
                    DocumentPicker(
                        onPick: { urls in
                            model.sheet = nil
                            model.addFiles(urls)
                        },
                        onCancel: { model.sheet = nil })
                        .ignoresSafeArea()
                case .folder:
                    FolderSheet()
                case .connectors:
                    ConnectorsView()
                }
            }
            .environment(model)
            .tint(palette.accent)
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
        }
    }
}
