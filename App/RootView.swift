import SwiftUI
import TermCore

/// Chat, Terminal and Settings as tabs, and every sheet in one place.
struct RootView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

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
        // Dragging any list or transcript puts the keyboard away, so the tab bar is never stuck under it.
        .scrollDismissesKeyboard(.interactively)
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
                case .folder:
                    FolderSheet()
                case .connectors:
                    ConnectorsView()
                case .chats:
                    ChatsView()
                }
            }
            .environment(model)
            .scrollDismissesKeyboard(.interactively)
            .tint(palette.accent)
            .preferredColorScheme(model.theme.isDark ? .dark : .light)
        }
    }
}
