import PhotosUI
import SwiftUI
import TermCore
import UIKit
import UniformTypeIdentifiers

/// The main screen: header, home or transcript, the composer, and the sidebar over them.
struct TerminalView: View {
    @Environment(AppModel.self) var model
    @FocusState var inputFocused: Bool
    @State var photoItems: [PhotosPickerItem] = []
    @State var folderDraft = ""

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                HeaderBar(inputFocused: $inputFocused)
                Rectangle().fill(palette.dim.opacity(0.2)).frame(height: 1)
                if model.showsHome {
                    HomeView()
                } else {
                    TranscriptView()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(inputFocused: $inputFocused)
            }
            .background(palette.background.ignoresSafeArea())

            if model.showSidebar {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { model.showSidebar = false }
                    .transition(.opacity)
                SidebarView()
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.showSidebar)
        .preferredColorScheme(model.theme.isDark ? .dark : .light)
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(item: $model.shareItem) { item in
            ShareSheet(text: item.text)
        }
        .sheet(item: $model.editingHost) { host in
            NavigationStack {
                HostEditor(host: host, secret: "", passphrase: "", isNew: true)
            }
        }
        .photosPicker(isPresented: $model.showPhotoPicker, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) {
            guard !photoItems.isEmpty else { return }
            model.addPhotos(photoItems)
            photoItems = []
        }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.addFiles(result)
        }
        .alert("Open folder", isPresented: $model.promptForFolder) {
            TextField("~/app or /srv/app", text: $folderDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open") {
                model.openFolder(folderDraft)
                folderDraft = ""
            }
            Button("Cancel", role: .cancel) { folderDraft = "" }
        } message: {
            Text(model.activeHost.map { "A folder on \($0.name). File tools work there and commands start in it." }
                 ?? "Pick an SSH environment first.")
        }
    }
}

// MARK: Transcript

private struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let palette = model.palette
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.session.transcript) { item in
                            ItemView(item: item, palette: palette)
                        }
                        if model.isRunning, model.pendingApproval == nil {
                            if palette.monospaced {
                                Text("▍").font(palette.font).foregroundStyle(palette.accent)
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small).tint(palette.accent)
                                    Text("Working…").font(palette.small).foregroundStyle(palette.dim)
                                }
                            }
                        } else if let usage = model.usageLine {
                            Text(usage).font(palette.small).foregroundStyle(palette.dim)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // A short transcript starts at the top, like a fresh terminal, rather than hugging the input.
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .shadow(color: model.theme.glow ? palette.text.opacity(0.55) : .clear, radius: 3)
                }
                // Stay pinned to the newest output while it streams, unless the user scrolls up.
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.scrollTick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct ItemView: View {
    let item: TranscriptItem
    let palette: Palette

    var body: some View {
        switch item.kind {
        case .user:
            if palette.monospaced {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("❯").foregroundStyle(palette.accent)
                    Text(item.text).foregroundStyle(palette.text).textSelection(.enabled)
                }
                .font(palette.bold)
            } else {
                // The desktop look: the prompt in a bubble on the right.
                Text(item.text)
                    .font(palette.font)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.code, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 36)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Markdown.segments(item.text).enumerated()), id: \.offset) { _, segment in
                    if segment.isCode {
                        CodeBlock(code: segment.text, palette: palette)
                    } else {
                        Text(segment.text).font(palette.font).foregroundStyle(palette.text).textSelection(.enabled)
                    }
                }
            }
        case .tool:
            ToolBlock(item: item, palette: palette)
        case .thinking:
            ThinkingBlock(item: item, palette: palette)
        case .info:
            Text(item.text).font(palette.monospaced ? palette.font : palette.small)
                .foregroundStyle(palette.dim).textSelection(.enabled)
        case .error:
            Text(item.text).font(palette.monospaced ? palette.font : palette.small)
                .foregroundStyle(palette.error).textSelection(.enabled)
        }
    }
}

private struct CodeBlock: View {
    let code: String
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code).font(palette.mono).foregroundStyle(palette.text).textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.leading, 10)
                .padding(.trailing, 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(palette.dim).padding(8)
            }
            .accessibilityLabel("Copy code")
        }
    }
}

private struct ToolBlock: View {
    let item: TranscriptItem
    let palette: Palette

    private var glyph: (String, Color) {
        switch item.status {
        case .running: return ("…", palette.accent)
        case .ok: return ("✓", palette.success)
        case .failed: return ("✗", palette.error)
        case .denied: return ("⊘", palette.dim)
        case nil: return ("·", palette.dim)
        }
    }

    /// Long output is shown from the end, where the result usually is.
    private var tail: String {
        let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 40 else { return item.text }
        return "… \(lines.count - 40) earlier lines\n" + lines.suffix(40).joined(separator: "\n")
    }

    /// Edits and writes show their change as a coloured diff.
    private var showsDiff: Bool {
        let title = item.title ?? ""
        return (title.hasPrefix("edit ") || title.hasPrefix("write ")) && (item.status == .ok || item.status == .running)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(glyph.0).foregroundStyle(glyph.1)
                Text(item.title ?? "tool").foregroundStyle(palette.text.opacity(0.85)).textSelection(.enabled)
            }
            .font(palette.monoSmall)
            if !item.text.isEmpty {
                if showsDiff {
                    DiffText(text: tail, palette: palette)
                } else {
                    Text(tail).font(palette.monoSmall).foregroundStyle(palette.dim).textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: palette.monospaced ? 6 : 10))
    }
}

/// The model's reasoning: dim, the last few lines while it streams; tap to see all of it.
private struct ThinkingBlock: View {
    let item: TranscriptItem
    let palette: Palette
    @State private var expanded = false

    private var shown: String {
        if expanded { return item.text }
        let lines = item.text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(3).joined(separator: "\n")
    }

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("✻").foregroundStyle(palette.accent)
                    Text(expanded ? "thinking ▾" : "thinking ▸").foregroundStyle(palette.dim)
                }
                if !shown.isEmpty {
                    Text(shown).italic().foregroundStyle(palette.dim).multilineTextAlignment(.leading)
                }
            }
            .font(palette.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide reasoning" : "Show reasoning")
    }
}

/// `+ ` lines in the success colour, `- ` lines in the error colour, context dimmed.
struct DiffText: View {
    let text: String
    let palette: Palette

    var body: some View {
        Text(attributed).font(palette.monoSmall).textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(String(line) + (index < lines.count - 1 ? "\n" : ""))
            let color: Color = line.hasPrefix("+ ") ? palette.success : line.hasPrefix("- ") ? palette.error : palette.dim
            piece.foregroundColor = color
            result += piece
        }
        return result
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
