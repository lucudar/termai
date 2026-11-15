import Foundation
import Observation
import PhotosUI
import SwiftUI
import TermCore
import TermSSH
import UIKit

@MainActor
extension AppModel {
    // MARK: Agent runs

    func send(_ text: String) {
        guard !isRunning else { return info("busy. ^C stops the current run") }
        guard let profile = activeProfile else { return fail("no gateway yet. add one in settings, or type /setup") }
        guard let model = activeModel else { return fail("no model selected. pick one in the model menu or use /model <id>") }
        let attached = attachments
        attachments = []
        var parts = text.isEmpty ? [String]() : [text]
        var shown = parts
        var images: [String] = []
        for attachment in attached {
            switch attachment.kind {
            case .image(let url):
                images.append(url)
            case .text(let body):
                parts.append("<file name=\"\(attachment.name)\">\n\(body)\n</file>")
            case .file(let path):
                parts.append("[\(attachment.name) is saved in the on-device workspace at \(path)]")
            }
            shown.append("📎 " + attachment.name)
        }
        append(.user, shown.joined(separator: "\n"))
        if session.messages.isEmpty { session.title = String((text.isEmpty ? attached.first?.name ?? "attachment" : text).prefix(48)) }
        session.messages.append(ChatMessage(role: .user, content: parts.joined(separator: "\n\n"),
                                            images: images.isEmpty ? nil : images))
        startRun(profile: profile, model: model)
    }

    func startRun(profile: Profile, model: String) {
        isRunning = true
        usageLine = nil
        runStart = Date()
        assistantItemID = nil
        thinkingItemID = nil
        runContextLimit = profile.contextLimit
        beginBackgroundGrace()
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        if profile.baseURL.lowercased().hasPrefix("http://"), !apiKey.isEmpty {
            info("note: \(profile.name) uses plain http, so the API key is sent unencrypted")
        }
        let history = session.messages
        let host = activeHost
        let effort = settings.effort

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                var shell: SSHConnection?
                if let host {
                    do {
                        shell = try await self.connect(to: host)
                    } catch {
                        self.fail("ssh \(host.name): \(error.localizedDescription)")
                        self.info("continuing without SSH")
                    }
                }
                try Task.checkCancellation()
                // With a project folder on the host, the file tools work there and its AGENTS.md is read.
                var projectDirectory: String?
                var notes: String?
                if let shell, let host, let directory = host.workingDirectory, !directory.isEmpty {
                    projectDirectory = directory
                    notes = await self.projectNotes(shell: shell, host: host, directory: directory)
                }
                let system = SystemPrompt.build(
                    custom: self.settings.systemPrompt, hostLabel: shell == nil ? nil : host?.address,
                    projectDirectory: projectDirectory, projectNotes: notes)
                let request = profile.chatRequest(
                    apiKey: apiKey, model: model,
                    messages: [ChatMessage(role: .system, content: system)] + history,
                    effort: effort)
                let tools = ToolBox(workspace: self.workspace, shell: shell, projectDirectory: projectDirectory)
                let agent = Agent(client: OpenAIClient(), tools: tools, contextTokens: profile.contextLimit)
                try await agent.run(
                    request: request,
                    approve: { [weak self] call, summary in
                        await self?.requestApproval(summary, detail: ToolBox.preview(call)) ?? .deny
                    },
                    emit: { [weak self] event in await self?.handle(event) })
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.info("^C")
                } else {
                    self.fail(error.localizedDescription)
                    if AppModel.isContextOverflow(error.localizedDescription) {
                        self.info("the conversation no longer fits this model. /compact summarizes it, /new starts fresh")
                    } else if let effort, AppModel.mentionsEffort(error.localizedDescription) {
                        self.info("this model or gateway did not take effort \(effort.title). pick Auto in the model menu, or /effort auto")
                    }
                }
            }
            self.finishRun()
        }
    }

    func projectNotes(shell: SSHConnection, host: SSHHost, directory: String) async -> String? {
        let key = host.id.uuidString + "|" + directory
        if let cached = notesCache[key] { return cached.isEmpty ? nil : cached }
        let notes = await RemoteFiles(shell: shell, root: directory).projectNotes()
        notesCache[key] = notes ?? ""
        if let notes {
            let names = ["AGENTS.md", "CLAUDE.md"].filter { notes.contains($0 + ":\n") }
            info("using " + names.joined(separator: " + ") + " from \(host.name):\(directory)")
        }
        return notes
    }

    static func isContextOverflow(_ message: String) -> Bool {
        let text = message.lowercased()
        let phrases = ["context length", "context window", "context_length", "maximum context", "too many tokens",
                       "prompt is too long", "input is too long", "reduce the length"]
        return phrases.contains { text.contains($0) }
    }

    static func mentionsEffort(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("reasoning_effort") || text.contains("reasoning.effort")
            || (text.contains("reasoning") && text.contains("effort"))
    }

    static func percent(_ tokens: Int, of limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        return min(999, Int((Double(tokens) / Double(limit) * 100).rounded()))
    }

    func finishRun() {
        for index in session.transcript.indices where session.transcript[index].status == .running {
            session.transcript[index].status = .failed
        }
        isRunning = false
        runTask = nil
        assistantItemID = nil
        thinkingItemID = nil
        toolItems = [:]
        session.updatedAt = Date()
        storage.saveSession(session)
        refreshRecents()
        let used = Self.percent(lastInputTokens, of: runContextLimit)
        if used >= 85, !contextHintShown {
            contextHintShown = true
            info("context \(used)% full. /compact summarizes the session so the model keeps room to work")
        }
        endBackgroundGrace()
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .assistantDelta(let delta):
            thinkingItemID = nil
            if assistantItemID == nil { assistantItemID = append(.assistant, "") }
            mutateItem(assistantItemID) { $0.text += delta }
        case .reasoningDelta(let delta):
            if thinkingItemID == nil { thinkingItemID = append(.thinking, "") }
            mutateItem(thinkingItemID) { item in
                item.text += delta
                if item.text.utf8.count > 48_000 { item.text = String(item.text.suffix(16_000)) }
            }
        case .message(let message):
            session.messages.append(message)
            if message.role == .assistant {
                assistantItemID = nil
                thinkingItemID = nil
            }
        case .toolStarted(let call, let summary):
            thinkingItemID = nil
            toolItems[call.id] = append(.tool, "", title: summary, status: .running)
        case .toolOutput(let id, let chunk):
            appendOutput(toolItems[id], chunk)
        case .toolFinished(let id, let result, let denied):
            mutateItem(toolItems[id]) { item in
                item.status = denied ? .denied : (result.isError ? .failed : .ok)
                if denied {
                    item.text = "declined"
                } else if item.text.isEmpty {
                    item.text = String(result.text.prefix(2_000))
                } else if result.isError, let last = result.text.split(separator: "\n").last {
                    if !item.text.hasSuffix("\n") { item.text += "\n" }
                    item.text += last
                }
            }
        case .usage(let input, let output):
            lastInputTokens = input
            let seconds = Int(Date().timeIntervalSince(runStart).rounded())
            let context = Self.percent(input, of: runContextLimit)
            usageLine = "\(Self.compact(input)) in · \(Self.compact(output)) out · ctx \(context)% · \(seconds)s"
        }
    }

    static func compact(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    /// `850`, `12.4k`, `128k`, `1M`.
    static func tokens(_ count: Int) -> String {
        func trimmed(_ value: Double, _ unit: String) -> String {
            let text = String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if count >= 1_000_000 { return trimmed(Double(count) / 1_000_000, "M") }
        if count >= 1_000 { return trimmed(Double(count) / 1_000, "k") }
        return "\(count)"
    }

    func cancel() {
        guard isRunning else { return }
        runTask?.cancel()
        if pendingApproval != nil { resolveApproval(.deny) }
    }

    // MARK: Approval

    func requestApproval(_ summary: String, detail: String? = nil) async -> ApprovalDecision {
        if settings.approvalMode == .auto || alwaysAllow { return .allow }
        if Task.isCancelled { return .deny }
        pendingApproval = PendingApproval(summary: summary, detail: detail)
        scrollTick += 1
        return await withCheckedContinuation { approvalContinuation = $0 }
    }

    func resolveApproval(_ decision: ApprovalDecision) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: decision)
        approvalContinuation = nil
    }

    func allowAlways() {
        alwaysAllow = true
        info("auto-approving tool calls for the rest of this session")
        resolveApproval(.allow)
    }

    // MARK: SSH

    func connect(to host: SSHHost) async throws -> SSHConnection {
        if let connection, connectionHostID == host.id, connection.isConnected { return connection }
        await dropConnection()
        guard let secret = secrets.secret(for: host.secretKey), !secret.isEmpty else {
            throw UserFacingError(message: "no password or key stored for this host; open /config")
        }
        let credentials = SSHCredentials(
            host: host.host, port: host.port, username: host.username,
            secret: host.auth == .password
                ? .password(secret)
                : .privateKey(pem: secret, passphrase: secrets.secret(for: host.passphraseKey)))
        info("connecting to \(host.address)…")
        let new = try await SSHConnection.connect(credentials, label: host.name, trustedHostKey: host.trustedHostKey)
        if host.trustedHostKey == nil, !new.hostKey.isEmpty, let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index].trustedHostKey = new.hostKey
            storage.saveHosts(hosts)
            info("first connection: trusting host key \(SSHKeys.fingerprint(ofOpenSSHKey: new.hostKey))")
        }
        connection = new
        connectionHostID = host.id
        return new
    }

    func dropConnection() async {
        let old = connection
        connection = nil
        connectionHostID = nil
        await old?.close()
    }

    /// `!command`: run directly on the active host and tell the model what happened.
    func runShell(_ command: String) {
        guard !isRunning else { return info("busy. ^C stops the current run") }
        guard let host = activeHost else {
            return fail("no SSH host selected. add one in /config, then pick it with /host <name>")
        }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            var itemID: UUID?
            do {
                let shell = try await self.connect(to: host)
                let id = self.append(.tool, "", title: "ssh \(host.name) $ \(command)", status: .running)
                itemID = id
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] in
                    for await chunk in output { self?.appendOutput(id, chunk) }
                }
                let code: Int
                do {
                    code = try await shell.run(command: command, timeout: 300) { continuation.yield($0) }
                } catch {
                    continuation.finish()
                    await forwarder.value
                    throw error
                }
                continuation.finish()
                await forwarder.value
                self.mutateItem(id) { $0.status = code == 0 ? .ok : .failed }
                if code != 0 { self.appendOutput(id, "[exit \(code)]") }
                let text = self.session.transcript.first { $0.id == id }?.text ?? ""
                self.session.messages.append(ChatMessage(
                    role: .user,
                    content: "[I ran this on \(host.address) myself]\n$ \(command)\n\(Truncate.middle(text, limit: 4_000))\n[exit \(code)]"))
            } catch {
                self.mutateItem(itemID) { $0.status = .failed }
                if error is CancellationError || Task.isCancelled {
                    self.info("^C")
                } else {
                    self.fail("ssh \(host.name): \(error.localizedDescription)")
                }
            }
            self.finishRun()
        }
    }
}
