import PhotosUI
import SwiftUI
import TermCore
import UIKit

/// The Chat tab: a new chat or the transcript, the composer floating over it, chats and new chat on top.
struct ChatScreen: View {
    @Environment(AppModel.self) var model
    @FocusState var inputFocused: Bool
    @State var photoItems: [PhotosPickerItem] = []

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        NavigationStack {
            Group {
                if model.showsHome {
                    EmptyChatView()
                } else {
                    TranscriptView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Backdrop(palette: palette))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(inputFocused: $inputFocused)
            }
            .navigationTitle(model.showsHome ? "" : model.session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        inputFocused = false
                        model.showChats()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Chats")
                    Button {
                        model.newSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
        }
        .photosPicker(isPresented: $model.showPhotoPicker, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) {
            guard !photoItems.isEmpty else { return }
            model.addPhotos(photoItems)
            photoItems = []
        }
    }
}

// MARK: Transcript

private struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let palette = model.palette
        let rows = TranscriptLayout.rows(model.session.transcript, running: model.isRunning)
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { row in
                            switch row {
                            case .item(let item):
                                ItemView(item: item, palette: palette)
                            case .activity(let group):
                                ActivityView(group: group, palette: palette,
                                             expanded: model.expandAllActivity || expanded.contains(group.id)) {
                                    toggle(group.id)
                                }
                            }
                        }
                        if model.isRunning, model.pendingApproval == nil, !TranscriptLayout.hasLive(rows) {
                            WorkingLine(palette: palette)
                        } else if !model.isRunning, let usage = model.usageLine {
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
                .softScrollEdge()
                .scrollDismissesKeyboard(.interactively)
                // A tap on the transcript puts the keyboard away.
                .simultaneousGesture(TapGesture().onEnded { Keyboard.hide() })
                .onChange(of: model.scrollTick) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.25)) {
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
        }
    }
}

// MARK: Folding a turn's work

/// A turn's work: thinking, tool calls, the plan and the notes between them, shown under one line.
struct ActivityGroup {
    let id: UUID
    var items: [TranscriptItem]
    /// The run is still working on it.
    var live: Bool

    var actions: [TranscriptItem] { items.filter { $0.kind == .tool && !$0.isPlan } }
    var plan: TranscriptItem? { items.last { $0.isPlan } }
    var failures: Int { actions.filter { $0.status == .failed }.count }
    /// What it is doing now: the latest tool call, or the reasoning streaming in.
    var current: TranscriptItem? { items.last { ($0.kind == .tool && !$0.isPlan) || $0.kind == .thinking } }
}

enum TranscriptRow: Identifiable {
    case item(TranscriptItem)
    case activity(ActivityGroup)

    var id: UUID {
        switch self {
        case .item(let item): return item.id
        case .activity(let group): return group.id
        }
    }
}

enum TranscriptLayout {
    static let work: Set<TranscriptItem.Kind> = [.tool, .thinking]

    /// The prompt, the final answer and errors stay in view; what the agent did in between folds into one
    /// group per turn. Turns started by a /command or a !command are left as they are.
    static func rows(_ transcript: [TranscriptItem], running: Bool) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var head: TranscriptItem?
        var turn: [TranscriptItem] = []

        func close(isLast: Bool) {
            defer { turn = [] }
            let folds = head.map { !$0.text.hasPrefix("/") && !$0.text.hasPrefix("!") } ?? false
            guard folds, let lastWork = turn.lastIndex(where: { TranscriptLayout.work.contains($0.kind) }) else {
                rows += turn.map { TranscriptRow.item($0) }
                return
            }
            let worked = turn[...lastWork]
            let folded: [TranscriptItem] = worked.filter { $0.kind != .error }
            rows.append(.activity(ActivityGroup(id: folded[0].id, items: folded, live: isLast && running)))
            rows += worked.filter { $0.kind == .error }.map { TranscriptRow.item($0) }
            rows += turn[(lastWork + 1)...].map { TranscriptRow.item($0) }
        }

        for item in transcript {
            if item.kind == .user {
                close(isLast: false)
                rows.append(.item(item))
                head = item
            } else {
                turn.append(item)
            }
        }
        close(isLast: true)
        return rows
    }

    /// Whether a group is still working, so its header already shows the progress.
    static func hasLive(_ rows: [TranscriptRow]) -> Bool {
        rows.contains { row in
            if case .activity(let group) = row { return group.live }
            return false
        }
    }
}

extension TranscriptItem {
    /// A plan update from update_plan, shown as the plan rather than as a tool call.
    var isPlan: Bool { kind == .tool && title == Plan.toolName }
}

/// A turn's work under one line: a spinner and what it is doing while it runs, a summary once done.
/// Tap it to unfold every step; the plan stays in view either way.
private struct ActivityView: View {
    let group: ActivityGroup
    let palette: Palette
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    if group.live {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else {
                        Image(systemName: group.failures > 0 ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(group.failures > 0 ? palette.error : palette.success)
                    }
                    Text(title).foregroundStyle(palette.text.opacity(0.9))
                    if group.failures > 0 {
                        Text("· \(group.failures) failed").foregroundStyle(palette.error)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.dim)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(palette.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide the steps" : "Show the steps")

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.items) { item in
                        ItemView(item: item, palette: palette)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.dim.opacity(0.25)).frame(width: 1.5)
                }
            } else {
                if group.live, let line = liveLine {
                    Text(line)
                        .font(palette.monoSmall)
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let plan = group.plan {
                    PlanCard(item: plan, live: group.live, palette: palette)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: palette.monospaced ? 6 : 16, style: .continuous))
    }

    private var title: String {
        let count = group.actions.count
        let actions = count == 1 ? "1 action" : "\(count) actions"
        if group.live {
            let doing = group.current?.kind == .thinking ? "Thinking…" : "Working…"
            return count == 0 ? doing : "\(doing) · \(actions)"
        }
        return count == 0 ? "Thought it through" : "Worked · \(actions)"
    }

    /// The running command, or the last line of the reasoning streaming in.
    private var liveLine: String? {
        guard let current = group.current else { return nil }
        if current.kind == .thinking {
            return current.text.split(separator: "\n").last.map { String($0) }
        }
        return current.title
    }
}

/// The agent's plan for a long task: finished steps ticked off, the current one highlighted.
struct PlanCard: View {
    let item: TranscriptItem
    let live: Bool
    let palette: Palette

    var body: some View {
        let steps = Plan.parse(item.text)
        let done = steps.filter { $0.status == .completed }.count
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(palette.accent)
                Text("Plan").foregroundStyle(palette.text)
                Text(verbatim: "\(done)/\(steps.count)").foregroundStyle(palette.dim)
            }
            .font(palette.small.weight(.semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(step.status))
                        .font(.system(size: 13))
                        .foregroundStyle(color(step.status))
                        .symbolEffect(.pulse, isActive: live && step.status == .inProgress)
                    Text(step.step)
                        .foregroundStyle(step.status == .completed ? palette.dim : palette.text)
                        .strikethrough(step.status == .completed, color: palette.dim)
                        .fontWeight(step.status == .inProgress ? .semibold : .regular)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(palette.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(_ status: PlanStep.Status) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .inProgress: return "circle.inset.filled"
        case .pending: return "circle"
        }
    }

    private func color(_ status: PlanStep.Status) -> Color {
        switch status {
        case .completed: return palette.success
        case .inProgress: return palette.accent
        case .pending: return palette.dim
        }
    }
}

/// While a run starts, before anything arrives that could be folded.
private struct WorkingLine: View {
    let palette: Palette

    var body: some View {
        if palette.monospaced {
            Text("▍").font(palette.font).foregroundStyle(palette.accent)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(palette.accent)
                Text("Working…").font(palette.small).foregroundStyle(palette.dim)
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
                    .background(palette.code, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.leading, 36)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Markdown.segments(item.text).enumerated()), id: \.offset) { _, segment in
                    if segment.isCode {
                        CodeBlock(code: segment.text, palette: palette)
                    } else {
                        Text(InlineMarkdown.attributed(segment.text))
                            .font(palette.font)
                            .foregroundStyle(palette.text)
                            .tint(palette.accent)
                            .textSelection(.enabled)
                    }
                }
            }
        case .tool:
            if item.isPlan, item.status != .failed {
                PlanCard(item: item, live: false, palette: palette)
                    .padding(10)
                    .background(palette.code, in: RoundedRectangle(cornerRadius: palette.monospaced ? 6 : 14, style: .continuous))
            } else {
                ToolBlock(item: item, palette: palette)
            }
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
        .background(palette.code, in: RoundedRectangle(cornerRadius: palette.monospaced ? 6 : 14, style: .continuous))
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

/// Inline Markdown for answers: bold, italics, code and links; headings become bold lines, list
/// markers become bullets. Code blocks are split off before this by `Markdown.segments`.
enum InlineMarkdown {
    static func attributed(_ text: String) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var line = String(line)
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let heading = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                line = heading.isEmpty ? "" : "**" + heading + "**"
            } else if line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) != nil {
                line = line.replacingOccurrences(of: #"^(\s*)[-*+]\s+"#, with: "$1• ", options: .regularExpression)
            }
            return line
        }
        let source = lines.joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
    }
}
