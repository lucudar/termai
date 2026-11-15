import SwiftUI
import TermCore
import UIKit

/// The input card with its + menu, model menu and send button, and two chips under it, on Liquid Glass.
struct Composer: View {
    @Environment(AppModel.self) var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        GlassGroup(spacing: 4) {
            VStack(spacing: 10) {
                if let approval = model.pendingApproval {
                    ApprovalBar(approval: approval, palette: palette)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !model.suggestions.isEmpty {
                    SuggestionList(palette: palette)
                }

                VStack(alignment: .leading, spacing: 10) {
                    if let notice = model.composerNotice {
                        NoticeLine(notice: notice, palette: palette)
                    }
                    if !model.attachments.isEmpty || !model.attachmentsLoading.isEmpty {
                        AttachmentStrip(palette: palette)
                    }
                    Group {
                        if model.inputIsSecret {
                            SecureField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim))
                        } else {
                            TextField("", text: $model.input, prompt: Text(model.placeholder).foregroundStyle(palette.dim), axis: .vertical)
                                .lineLimit(1...8)
                        }
                    }
                    .font(palette.font)
                    .foregroundStyle(palette.text)
                    .tint(palette.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused(inputFocused)
                    .onSubmit(send)

                    HStack(spacing: 8) {
                        PlusMenu(palette: palette)
                        if inputFocused.wrappedValue {
                            Button {
                                inputFocused.wrappedValue = false
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(palette.dim)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Hide keyboard")
                        }
                        Spacer(minLength: 6)
                        ModelMenu(palette: palette)
                        SendButton(palette: palette, send: send)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                HStack(spacing: 8) {
                    PlaceChip(palette: palette)
                    Spacer(minLength: 8)
                    AgentChip(palette: palette)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: model.pendingApproval)
        .animation(.spring(duration: 0.25), value: model.composerNotice)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func send() {
        model.submit()
        // Submitting drops focus; keep the keyboard up for the next message.
        DispatchQueue.main.async { inputFocused.wrappedValue = true }
    }
}

/// A chip under the input card: a small glass capsule.
struct ChipLabel: View {
    let title: String
    let symbol: String?
    let color: Color
    let palette: Palette

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .medium)) }
            Text(title).lineLimit(1).truncationMode(.middle)
        }
        .font(palette.chip)
        .foregroundStyle(color)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .liquidGlass(in: Capsule(), interactive: true)
    }
}

// MARK: Inside the card

private struct PlusMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            Section {
                Button {
                    model.presentPhotos()
                } label: {
                    Label("Add photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    model.pickFiles()
                } label: {
                    Label("Add files", systemImage: "paperclip")
                }
                Button {
                    model.present(.folder)
                } label: {
                    Label("Open folder…", systemImage: "folder.badge.plus")
                }
                .disabled(model.activeHost == nil)
            }
            Section {
                Button {
                    model.input = "/"
                } label: {
                    Label("Slash commands", systemImage: "slash.circle")
                }
                Button {
                    model.openTerminal()
                } label: {
                    Label("Open terminal", systemImage: "apple.terminal")
                }
            }
            Section {
                Button {
                    model.present(.connectors)
                } label: {
                    Label(model.connectors.isEmpty ? "Manage connectors" : "Manage connectors (\(model.enabledConnectorCount) on)",
                          systemImage: "puzzlepiece.extension")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 34, height: 34)
                .background(palette.text.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Add")
    }
}

/// Models of every gateway, the effort submenu, and a way to refresh the list.
private struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            ForEach(model.profiles) { profile in
                Section(profile.name) {
                    ForEach(profile.pickerModels, id: \.self) { id in
                        Button {
                            model.select(model: id, in: profile.id)
                        } label: {
                            if profile.id == model.activeProfile?.id, id == model.activeModel {
                                Label(id, systemImage: "checkmark")
                            } else {
                                Text(id)
                            }
                        }
                    }
                    if profile.pickerModels.isEmpty {
                        Text("No models yet: refresh, or list some in Settings")
                    }
                }
            }
            Menu {
                Section("Higher effort means more thorough answers, but it takes longer and uses more tokens.") {
                    effortButton(nil)
                    ForEach(Effort.allCases, id: \.self) { effort in
                        effortButton(effort)
                    }
                }
            } label: {
                Label("Effort: \(model.effort?.title ?? "Auto")", systemImage: "speedometer")
            }
            Button {
                model.refreshModels()
            } label: {
                Label("Refresh models", systemImage: "arrow.clockwise")
            }
            Button {
                model.showSettings = true
            } label: {
                Label("Gateways…", systemImage: "network")
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.activeModelShortName).foregroundStyle(palette.text)
                Text(model.effort?.title ?? "Auto").foregroundStyle(palette.dim)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.dim)
            }
            .font(palette.chip)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.text.opacity(0.06), in: Capsule())
            .frame(maxWidth: 230, alignment: .trailing)
        }
        // A plain label: iOS 26 would otherwise draw its own tinted capsule around every menu.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Model and effort")
    }

    private func effortButton(_ effort: Effort?) -> some View {
        Button {
            model.setEffort(effort)
        } label: {
            if model.effort == effort {
                Label(effort?.title ?? "Auto", systemImage: "checkmark")
            } else {
                Text(effort?.title ?? "Auto")
            }
        }
    }
}

private struct SendButton: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    let send: () -> Void

    var body: some View {
        let running = model.isRunning && model.pendingApproval == nil
        let ready = !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty
        Button {
            if running {
                model.cancel()
            } else {
                send()
            }
        } label: {
            Image(systemName: running ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .roundProminent(running ? palette.error : (ready ? palette.accent : palette.dim.opacity(0.6)))
        .animation(.easeOut(duration: 0.15), value: ready)
        .accessibilityLabel(running ? "Stop" : "Send")
    }
}

/// What goes with the next prompt: a chip per file or photo, and one per file still being read.
private struct AttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 8) {
                        Image(systemName: attachment.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                            if !attachment.detail.isEmpty {
                                Text(attachment.detail)
                                    .font(.caption2)
                                    .foregroundStyle(palette.dim)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: 190, alignment: .leading)
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(palette.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(palette.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(palette.text.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
                ForEach(Array(model.attachmentsLoading.enumerated()), id: \.offset) { _, name in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(palette.accent)
                        Text("Reading \(name)…")
                            .foregroundStyle(palette.dim)
                            .lineLimit(1)
                            .frame(maxWidth: 190, alignment: .leading)
                    }
                    .font(palette.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(palette.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .animation(.spring(duration: 0.25), value: model.attachments)
            .animation(.spring(duration: 0.25), value: model.attachmentsLoading)
        }
    }
}

/// How adding files went: attached, saved to the workspace, or the error.
private struct NoticeLine: View {
    @Environment(AppModel.self) private var model
    let notice: ComposerNotice
    let palette: Palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(notice.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.composerNotice = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .font(palette.small)
        .foregroundStyle(notice.isError ? palette.error : palette.success)
        .transition(.opacity)
    }
}

// MARK: Chips under the box

/// Where the agent works: This iPhone, or an SSH environment and its folder, both from one menu.
private struct PlaceChip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            EnvironmentMenuContent()
            if model.activeHost != nil {
                Divider()
                FolderMenuContent()
            }
        } label: {
            ChipLabel(title: model.placeName, symbol: model.activeHost == nil ? "iphone" : "server.rack",
                      color: palette.text.opacity(0.85), palette: palette)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Environment and folder")
    }
}

/// How freely the agent acts and how full its context window is, in one chip. The menu also compacts.
private struct AgentChip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let bypass = model.settings.approvalMode == .auto
        let fraction = model.contextFraction
        let ring = fraction >= 0.85 ? palette.error : palette.accent
        let color = bypass ? palette.accent : palette.text.opacity(0.85)
        Menu {
            Section("Permissions") {
                Button {
                    model.setApproval(.ask)
                } label: {
                    if bypass {
                        Text("Ask before acting")
                    } else {
                        Label("Ask before acting", systemImage: "checkmark")
                    }
                }
                Button {
                    model.setApproval(.auto)
                } label: {
                    if bypass {
                        Label("Bypass permissions", systemImage: "checkmark")
                    } else {
                        Text("Bypass permissions")
                    }
                }
            }
            Section {
                Button {
                    model.compactSession()
                } label: {
                    Label("Compact the session", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .disabled(model.session.messages.isEmpty || model.isRunning)
            } header: {
                Text(verbatim: "Context window: \(model.contextSummary) (\(model.contextPercent)%)")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: bypass ? "bolt.shield" : "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                Text(bypass ? "Bypass" : "Ask first").lineLimit(1)
                ZStack {
                    Circle().stroke(palette.dim.opacity(0.35), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(fraction))
                        .stroke(ring, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 13, height: 13)
                Text(verbatim: "\(model.contextPercent)%").foregroundStyle(palette.dim)
            }
            .font(palette.chip)
            .foregroundStyle(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule(), interactive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Permissions and context window")
    }
}

private struct SuggestionList: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.suggestions.prefix(6), id: \.name) { command in
                Button {
                    model.input = "/\(command.name) "
                } label: {
                    HStack(spacing: 10) {
                        Text("/\(command.name)").foregroundStyle(palette.accent)
                        Text(command.help).foregroundStyle(palette.dim).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(palette.small)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct ApprovalBar: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    private var question: String {
        if approval.summary.hasPrefix("edit ") { return "Apply this edit?" }
        if approval.summary.hasPrefix("write ") { return "Write this file?" }
        if approval.summary.contains(" \u{00B7} ") { return "Use this connector tool?" }
        return "Run this?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(question, systemImage: "exclamationmark.shield")
                .font(palette.small.weight(.semibold))
                .foregroundStyle(palette.accent)
            Text(approval.summary).font(palette.monoSmall).foregroundStyle(palette.text).lineLimit(6)
            if let detail = approval.detail, !detail.isEmpty {
                DiffText(text: detail, palette: palette)
                    .lineLimit(12)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.code.opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 8) {
                choice(palette.monospaced ? "[y] yes" : "Allow", palette.success, prominent: true) { model.resolveApproval(.allow) }
                choice(palette.monospaced ? "[n] no" : "Deny", palette.error, prominent: false) { model.resolveApproval(.deny) }
                choice(palette.monospaced ? "[a] always" : "Always", palette.text, prominent: false) { model.allowAlways() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), tint: palette.accent.opacity(0.12))
    }

    private func choice(_ label: String, _ color: Color, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.small.weight(.semibold))
                .foregroundStyle(prominent ? Color.white : color)
                .frame(maxWidth: .infinity, minHeight: 26)
        }
        .glassButton(prominent: prominent)
        .tint(prominent ? color : nil)
    }
}
