import SwiftUI
import TermCore
import UIKit

/// The input card with its + menu, model menu and send button, and the chips under it, on Liquid Glass.
struct Composer: View {
    @Environment(AppModel.self) var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        GlassGroup(spacing: 10) {
            VStack(spacing: 10) {
                if let approval = model.pendingApproval {
                    ApprovalBar(approval: approval, palette: palette)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if !model.suggestions.isEmpty {
                    SuggestionList(palette: palette)
                }

                VStack(alignment: .leading, spacing: 10) {
                    if !model.attachments.isEmpty || model.attachmentsLoading > 0 {
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
                    EnvironmentChip(palette: palette)
                    FolderChip(palette: palette)
                    Spacer(minLength: 4)
                    PermissionsChip(palette: palette)
                    ContextRing(palette: palette)
                }
            }
        }
        .animation(.spring(duration: 0.3), value: model.pendingApproval)
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
            Text(title).lineLimit(1)
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
                    model.present(.files)
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
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
            .frame(maxWidth: 230, alignment: .trailing)
        }
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

private struct AttachmentStrip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.symbol)
                        Text(attachment.name).lineLimit(1)
                        Button {
                            model.removeAttachment(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(palette.dim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                    .font(palette.small)
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.text.opacity(0.08), in: Capsule())
                }
                if model.attachmentsLoading > 0 {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Reading…")
                    }
                    .font(palette.small)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.text.opacity(0.05), in: Capsule())
                }
            }
        }
    }
}

// MARK: Chips under the box

private struct EnvironmentChip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            EnvironmentMenuContent()
        } label: {
            ChipLabel(title: model.environmentName, symbol: model.activeHost == nil ? "iphone" : "server.rack",
                      color: palette.text.opacity(0.8), palette: palette)
        }
        .accessibilityLabel("Environment")
    }
}

private struct FolderChip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            FolderMenuContent()
        } label: {
            ChipLabel(title: model.folderName, symbol: "folder", color: palette.text.opacity(0.8), palette: palette)
        }
        .accessibilityLabel("Folder")
    }
}

private struct PermissionsChip: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        let bypass = model.settings.approvalMode == .auto
        Menu {
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
        } label: {
            ChipLabel(title: bypass ? "Bypass" : "Ask first", symbol: bypass ? "bolt.shield" : "hand.raised",
                      color: bypass ? palette.accent : palette.text.opacity(0.8), palette: palette)
        }
        .accessibilityLabel("Permissions")
    }
}

/// How full the model's context window is; tap for the numbers.
private struct ContextRing: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    @State private var showing = false

    var body: some View {
        let fraction = model.contextFraction
        let color = fraction >= 0.85 ? palette.error : palette.accent
        Button {
            showing = true
        } label: {
            ZStack {
                Circle().stroke(palette.dim.opacity(0.35), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .padding(9)
            .liquidGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context window")
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Context window").foregroundStyle(palette.dim)
                    Spacer(minLength: 16)
                    Text(model.contextSummary).foregroundStyle(palette.text)
                }
                ProgressView(value: fraction)
                    .tint(color)
                Text(fraction >= 0.85
                     ? "Almost full. /compact summarizes the session so the model keeps room to work."
                     : "Tokens the last request used, out of this gateway's context window.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14))
            .padding(16)
            .frame(width: 280)
            .presentationCompactAdaptation(.popover)
        }
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
