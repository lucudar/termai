import SwiftUI
import TermCore
import UIKit

/// The Terminal tab: your own shell on the SSH environment, or file commands in the on-device workspace.
/// Separate from the chat; "Ask the agent" carries the last output over as an attachment.
struct TerminalScreen: View {
    @Environment(AppModel.self) var model
    @FocusState var focused: Bool

    var body: some View {
        let palette = model.palette
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if model.terminalLines.isEmpty {
                            TerminalWelcome(palette: palette)
                        }
                        ForEach(model.terminalLines) { line in
                            if !line.text.isEmpty {
                                Text(line.text)
                                    .font(line.kind == .command ? palette.mono.weight(.semibold) : palette.mono)
                                    .foregroundStyle(color(line.kind, palette))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, line.kind == .command ? 6 : 0)
                            }
                        }
                        if model.terminalRunning {
                            Text("▍").font(palette.mono).foregroundStyle(palette.accent)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .shadow(color: model.theme.glow ? palette.text.opacity(0.5) : .clear, radius: 3)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                // A tap on the output puts the keyboard away, so the tabs are reachable again.
                .simultaneousGesture(TapGesture().onEnded { focused = false })
                .softScrollEdge()
                .onChange(of: model.terminalTick) {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            .background(palette.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TerminalInputBar(focused: $focused)
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        EnvironmentMenuContent()
                    } label: {
                        Label(model.environmentName, systemImage: model.activeHost == nil ? "iphone" : "server.rack")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Environment")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.askAgentAboutTerminal()
                        } label: {
                            Label("Ask the agent about the output", systemImage: "sparkles")
                        }
                        .disabled(model.lastTerminalBlock == nil)
                        Button {
                            model.copyTerminal()
                        } label: {
                            Label("Copy all", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            model.clearTerminal()
                        } label: {
                            Label("Clear", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
    }

    private func color(_ kind: TerminalLine.Kind, _ palette: Palette) -> Color {
        switch kind {
        case .command: return palette.accent
        case .output: return palette.text
        case .error: return palette.error
        case .note: return palette.dim
        }
    }
}

/// What an empty terminal says: where commands run and what works there.
struct TerminalWelcome: View {
    @Environment(AppModel.self) var model
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = model.activeHost {
                Text("\(host.username)@\(host.address)")
                    .foregroundStyle(palette.accent)
                Text("Commands run over SSH, one at a time, in the folder the last one left. Full-screen programs (vim, less, top) need a real terminal.")
                    .foregroundStyle(palette.dim)
            } else {
                Text("This iPhone")
                    .foregroundStyle(palette.accent)
                Text("iOS apps cannot start processes, so this is a small set of file commands in the app's workspace: \(WorkspaceShell.commands.joined(separator: ", ")). Pick an SSH environment above for a full shell.")
                    .foregroundStyle(palette.dim)
            }
        }
        .font(palette.monoSmall)
        .padding(.bottom, 8)
    }
}

/// The prompt line with run and stop, and a row of keys the iOS keyboard lacks.
struct TerminalInputBar: View {
    @Environment(AppModel.self) var model
    var focused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        let palette = model.palette
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                if focused.wrappedValue {
                    TerminalKeys(palette: palette, hideKeyboard: { focused.wrappedValue = false })
                }
                HStack(spacing: 10) {
                    Text(model.terminalPrompt)
                        .font(palette.monoSmall)
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 150, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("", text: $model.terminalInput, prompt: Text("command").foregroundStyle(palette.dim))
                        .font(palette.mono)
                        .foregroundStyle(palette.text)
                        .tint(palette.accent)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused(focused)
                        .onSubmit(run)
                    Button {
                        if model.terminalRunning { model.stopTerminal() } else { run() }
                    } label: {
                        Image(systemName: model.terminalRunning ? "stop.fill" : "return")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .roundProminent(model.terminalRunning ? palette.error : palette.accent)
                    .accessibilityLabel(model.terminalRunning ? "Stop" : "Run")
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .liquidGlass(in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func run() {
        model.runTerminal()
        DispatchQueue.main.async { focused.wrappedValue = true }
    }
}

/// esc, history, ^C and the characters that are slow to reach on the iOS keyboard.
struct TerminalKeys: View {
    @Environment(AppModel.self) var model
    let palette: Palette
    let hideKeyboard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc") { model.terminalInput = "" }
                    key("↑") { model.terminalHistoryUp() }
                    key("↓") { model.terminalHistoryDown() }
                    key("^C", tint: model.terminalRunning ? palette.error : nil) { model.stopTerminal() }
                    ForEach(["|", "~", "/", "-", "&&", ">", "$"], id: \.self) { text in
                        key(text) { model.terminalInput += text }
                    }
                    key("paste") {
                        if let text = UIPasteboard.general.string { model.terminalInput += text }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            // Pinned outside the scrolling keys, so putting the keyboard away is always one tap.
            Button(action: hideKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .frame(minWidth: 30, minHeight: 22)
            }
            .glassButton()
            .accessibilityLabel("Hide keyboard")
        }
    }

    private func key(_ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.monoSmall)
                .foregroundStyle(tint ?? palette.text)
                .frame(minWidth: 26, minHeight: 22)
        }
        .glassButton()
    }
}
