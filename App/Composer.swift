import SwiftUI
import TermCore
import UIKit

/// The input box with its + menu, model menu and send button, and the chips under it.
struct Composer: View {
    @Environment(AppModel.self) var model
    var inputFocused: FocusState<Bool>.Binding

    var body: some View {
        @Bindable var model = model
        let palette = model.palette

        VStack(spacing: 8) {
            if let approval = model.pendingApproval {
                ApprovalBar(approval: approval, palette: palette)
            } else if !model.suggestions.isEmpty {
                SuggestionList(palette: palette)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
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

                HStack(spacing: 10) {
                    PlusMenu(palette: palette)
                    Spacer(minLength: 6)
                    ModelMenu(palette: palette)
                    SendButton(palette: palette, send: send)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(palette.code, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.dim.opacity(0.22), lineWidth: 1))

            HStack(spacing: 14) {
                EnvironmentChip(palette: palette)
                FolderChip(palette: palette)
                Spacer(minLength: 6)
                PermissionsChip(palette: palette)
                ContextRing(palette: palette)
            }
            .padding(.horizontal, 6)

            if inputFocused.wrappedValue {
                KeyRow(palette: palette, send: send, hideKeyboard: { inputFocused.wrappedValue = false })
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(palette.background)
    }

    private func send() {
        model.submit()
        // Submitting drops focus; keep the keyboard up like a terminal would.
        DispatchQueue.main.async { inputFocused.wrappedValue = true }
    }
}

// MARK: Inside the box

private struct PlusMenu: View {
    @Environment(AppModel.self) private var model
    let palette: Palette

    var body: some View {
        Menu {
            Button {
                model.showPhotoPicker = true
            } label: {
                Label("Add photos", systemImage: "photo.on.rectangle")
            }
            Button {
                model.showFileImporter = true
            } label: {
                Label("Add files", systemImage: "paperclip")
            }
            Button {
                model.promptForFolder = true
            } label: {
                Label("Add folder", systemImage: "folder.badge.plus")
            }
            .disabled(model.activeHost == nil)
            Divider()
            Button {
                model.input = "/"
            } label: {
                Label("Slash commands", systemImage: "slash.circle")
            }
            Button {
                model.input = "!"
            } label: {
                Label("Run a command yourself", systemImage: "terminal")
            }
            Divider()
            Button {
            } label: {
                Label("Manage connectors (soon)", systemImage: "square.grid.2x2")
            }
            .disabled(true)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.text)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
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
            }
            .font(palette.chip)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 220, alignment: .trailing)
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
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(palette.background)
                .frame(width: 32, height: 32)
                .background(running ? palette.error : (ready ? palette.accent : palette.dim.opacity(0.5)), in: Circle())
        }
        .buttonStyle(.plain)
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
                    .background(palette.background.opacity(0.7), in: Capsule())
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
            Label(model.environmentName, systemImage: model.activeHost == nil ? "iphone" : "server.rack")
                .font(palette.chip)
                .foregroundStyle(palette.dim)
                .lineLimit(1)
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
            Label(model.folderName, systemImage: "folder")
                .font(palette.chip)
                .foregroundStyle(palette.dim)
                .lineLimit(1)
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
            Text(bypass ? "Bypass permissions" : "Ask first")
                .font(palette.chip)
                .foregroundStyle(bypass ? palette.accent : palette.dim)
                .lineLimit(1)
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
            .frame(width: 16, height: 16)
            .padding(6)
            .contentShape(Rectangle())
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

// MARK: Terminal helpers

private struct KeyRow: View {
    @Environment(AppModel.self) private var model
    let palette: Palette
    let send: () -> Void
    let hideKeyboard: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { model.escape() }
                key("/") { model.input += "/" }
                key("!") { model.input += "!" }
                key("↑") { model.historyUp() }
                key("↓") { model.historyDown() }
                key("tab") { model.completeSuggestion() }
                key("^C", tint: model.isRunning ? palette.error : nil) { model.cancel() }
                key("paste") {
                    if let text = UIPasteboard.general.string { model.input += text }
                }
                key("⌄", action: hideKeyboard)
                key("⏎", tint: palette.accent, action: send)
            }
            .padding(.horizontal, 4)
        }
    }

    private func key(_ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(palette.monoSmall)
                .foregroundStyle(tint ?? palette.text)
                .padding(.horizontal, 11)
                .frame(minWidth: 38, minHeight: 32)
                .background(palette.code, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
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
        .padding(.vertical, 4)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ApprovalBar: View {
    @Environment(AppModel.self) private var model
    let approval: PendingApproval
    let palette: Palette

    private var question: String {
        if approval.summary.hasPrefix("edit ") { return "Apply this edit?" }
        if approval.summary.hasPrefix("write ") { return "Write this file?" }
        return "Run this?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question).font(palette.small).foregroundStyle(palette.accent)
            Text(approval.summary).font(palette.monoSmall).foregroundStyle(palette.text).lineLimit(6)
            if let detail = approval.detail, !detail.isEmpty {
                DiffText(text: detail, palette: palette)
                    .lineLimit(12)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                choice(palette.monospaced ? "[y] yes" : "Allow", palette.success) { model.resolveApproval(.allow) }
                choice(palette.monospaced ? "[n] no" : "Deny", palette.error) { model.resolveApproval(.deny) }
                choice(palette.monospaced ? "[a] always" : "Always allow", palette.dim) { model.allowAlways() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 14))
    }

    private func choice(_ label: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(palette.small).foregroundStyle(color)
                .padding(.horizontal, 12)
                .frame(minHeight: 34)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }
}
