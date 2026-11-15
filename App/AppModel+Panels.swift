import Foundation
import Observation
import PhotosUI
import SwiftUI
import TermCore
import TermSSH
import UIKit

@MainActor
extension AppModel {
    // MARK: Settings screen support

    func apiKey(for profile: Profile) -> String { secrets.secret(for: profile.secretKey) ?? "" }

    func saveProfile(_ profile: Profile, apiKey: String) {
        let previous = profiles.first { $0.id == profile.id }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        storage.saveProfiles(profiles)
        secrets.setSecret(apiKey, for: profile.secretKey)
        if settings.activeProfileID == nil || profiles.count == 1 {
            update {
                $0.activeProfileID = profile.id
                $0.activeModel = profile.preferredModel
                $0.effort = profile.defaultEffort
            }
        } else if settings.activeProfileID == profile.id {
            if let model = settings.activeModel, !profile.pickerModels.contains(model) {
                update { $0.activeModel = profile.preferredModel }
            }
            if previous?.defaultEffort != profile.defaultEffort {
                update { $0.effort = profile.defaultEffort }
            }
        }
        if profile.discovers, profile.models.isEmpty, (profile.discoveredModels ?? []).isEmpty {
            refreshModels(for: profile.id, quiet: true)
        }
    }

    func deleteProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        storage.saveProfiles(profiles)
        secrets.setSecret(nil, for: profile.secretKey)
        if settings.activeProfileID == profile.id {
            update {
                $0.activeProfileID = profiles.first?.id
                $0.activeModel = profiles.first?.preferredModel
            }
        }
    }

    func hostSecret(for host: SSHHost) -> String { secrets.secret(for: host.secretKey) ?? "" }
    func hostPassphrase(for host: SSHHost) -> String { secrets.secret(for: host.passphraseKey) ?? "" }

    func saveHost(_ host: SSHHost, secret: String, passphrase: String) {
        let isFirst = hosts.isEmpty
        var host = host
        if let directory = host.workingDirectory, !directory.isEmpty { host.remember(directory: directory) }
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        storage.saveHosts(hosts)
        secrets.setSecret(secret, for: host.secretKey)
        secrets.setSecret(passphrase, for: host.passphraseKey)
        if isFirst { update { $0.activeHostID = host.id } }
        // Reconnect with the new details on next use.
        if connectionHostID == host.id { Task { await dropConnection() } }
    }

    func deleteHost(_ host: SSHHost) {
        hosts.removeAll { $0.id == host.id }
        storage.saveHosts(hosts)
        secrets.setSecret(nil, for: host.secretKey)
        secrets.setSecret(nil, for: host.passphraseKey)
        if settings.activeHostID == host.id { selectHost(nil) }
    }

    // MARK: Panels

    /// The chats sheet: every saved session, newest first.
    func showChats() {
        refreshRecents()
        sheet = .chats
    }

    func refreshRecents() {
        recentSessions = Array(storage.sessionSummaries().prefix(60))
    }

    func newSession() {
        guard !isRunning else { return info("busy. ^C stops the current run") }
        startNewSession()
    }

    func openSession(_ id: UUID) {
        guard !isRunning else { return info("busy. ^C stops the current run") }
        guard id != session.id else { return }
        guard let loaded = storage.loadSession(id: id) else {
            refreshRecents()
            return fail("that session could not be opened")
        }
        resume(loaded)
    }

    func deleteSession(_ id: UUID) {
        if id == session.id {
            guard !isRunning else { return info("busy. ^C stops the current run") }
            session = Session()
            usageLine = nil
            lastInputTokens = 0
            contextHintShown = false
        }
        storage.deleteSession(id: id)
        refreshRecents()
    }

    /// The context chip's "Compact the session": the same as typing /compact.
    func compactSession() {
        guard !isRunning else { return info("busy. ^C stops the current run") }
        append(.user, "/compact")
        runCommand("compact", "")
    }

    func setEffort(_ effort: Effort?) {
        update { $0.effort = effort }
    }

    func setApproval(_ mode: ApprovalMode) {
        update { $0.approvalMode = mode }
        if mode == .ask { alwaysAllow = false }
    }

    /// The folder menu's "Open folder…": the same as `/cd <path>`.
    func openFolder(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isRunning else { return info("busy. ^C stops the current run") }
        cdCommand(trimmed)
    }

    func closeFolder() {
        guard let host = activeHost else { return }
        setWorkingDirectory(nil, for: host.id)
        info("folder closed. file tools use the on-device workspace again")
    }

    /// Fills a gateway's model picker from its `/models`.
    func refreshModels(for profileID: UUID? = nil, quiet: Bool = false) {
        guard let profile = profiles.first(where: { $0.id == (profileID ?? activeProfile?.id) }) else {
            if !quiet { fail("no gateway yet. add one in settings") }
            return
        }
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        Task { [weak self] in
            do {
                let found = try await OpenAIClient().listModels(
                    baseURL: profile.baseURL, apiKey: apiKey, authScheme: profile.auth, headers: profile.extraHeaders,
                    format: profile.format)
                guard let self, let index = self.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
                self.profiles[index].discoveredModels = found
                self.storage.saveProfiles(self.profiles)
                if !quiet {
                    let note = profile.models.isEmpty ? "" : ". your own model list still decides what the picker shows"
                    self.info("\(found.count) models on \(profile.name)\(note)")
                }
            } catch {
                if !quiet { self?.fail("models on \(profile.name): \(error.localizedDescription)") }
            }
        }
    }

    /// "Add files": the system document picker, once the + menu has finished closing.
    func pickFiles() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            DocumentPicker.present { urls in self?.addFiles(urls) }
        }
    }

    func addPhotos(_ items: [PhotosPickerItem]) {
        for item in items {
            attachmentsLoading.append("photo")
            Task { [weak self] in
                let data = try? await item.loadTransferable(type: Data.self)
                // Decoding and scaling a camera photo takes a moment; keep it off the main thread.
                let url: String? = await Task.detached(priority: .userInitiated) {
                    data.flatMap { ImageAttachment.dataURL(from: $0) }
                }.value
                guard let self else { return }
                self.finishLoading("photo")
                guard let url else { return self.notify("Could not read that photo", error: true) }
                let number = self.attachments.filter { $0.isImage }.count + 1
                self.attachments.append(PendingAttachment(name: "photo \(number)", kind: .image(url), detail: "image"))
            }
        }
    }

    /// Files from the document picker (already copied into the app). Images go to the model as images,
    /// text and PDF text are inlined, anything else lands in the workspace's Inbox folder. Each file shows
    /// as "Reading…" until it is ready, then a line over the input says how it went.
    func addFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let inbox = workspace.appendingPathComponent("Inbox", isDirectory: true)
        attachmentsLoading += urls.map(\.lastPathComponent)
        Task { [weak self] in
            var failures: [String] = []
            var saved: [String] = []
            for url in urls {
                let name = url.lastPathComponent
                let loaded: Result<PendingAttachment, Error> = await Task.detached(priority: .userInitiated) {
                    Result { try FileAttachment.load(url, inbox: inbox) }
                }.value
                guard let self else { return }
                self.finishLoading(name)
                switch loaded {
                case .success(let attachment):
                    self.attachments.append(attachment)
                    if case .file(let path) = attachment.kind { saved.append(path) }
                case .failure(let error):
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }
            guard let self else { return }
            if !failures.isEmpty {
                self.notify("Could not add " + failures.joined(separator: "; "), error: true)
            } else if !saved.isEmpty {
                self.notify("Not text, so it was saved for the agent to open: " + saved.joined(separator: ", "))
            } else {
                self.notify(urls.count == 1 ? "Attached \(urls[0].lastPathComponent)" : "Attached \(urls.count) files")
            }
        }
    }

    func finishLoading(_ name: String) {
        if let index = attachmentsLoading.firstIndex(of: name) { attachmentsLoading.remove(at: index) }
    }

    /// Shows `text` over the input for a few seconds, with a tap of the haptic engine.
    func notify(_ text: String, error: Bool = false) {
        let notice = ComposerNotice(text: text, isError: error)
        composerNotice = notice
        UINotificationFeedbackGenerator().notificationOccurred(error ? .error : .success)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self?.composerNotice == notice { self?.composerNotice = nil }
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: Demo content

    func loadDemo(withApproval: Bool, home: Bool) {
        let profile = Profile(name: "openrouter", baseURL: "https://openrouter.ai/api/v1",
                              models: ["anthropic/claude-sonnet-5", "openai/gpt-6-luna"], defaultModel: "anthropic/claude-sonnet-5",
                              contextWindow: 200_000, defaultEffort: .high)
        let host = SSHHost(name: "web1", host: "10.0.0.12", username: "deploy", workingDirectory: "/home/deploy/app",
                           recentDirectories: ["/home/deploy/app", "/srv/api"])
        profiles = [profile]
        hosts = [host]
        settings = AppSettings(activeProfileID: profile.id, activeModel: profile.defaultModel, activeHostID: host.id,
                               themeID: UserDefaults.standard.string(forKey: "theme") ?? Theme.desktop.id, effort: .high)
        let now = Date()
        recentSessions = [
            SessionSummary(id: UUID(), title: "the api on web1 returns 500, fix it", updatedAt: now),
            SessionSummary(id: UUID(), title: "add rate limiting to /login", updatedAt: now.addingTimeInterval(-3_600)),
            SessionSummary(id: UUID(), title: "why is the nightly backup slow", updatedAt: now.addingTimeInterval(-86_400 * 2)),
        ]
        if home { return }
        session = Session(title: "the api on web1 returns 500, fix it", messages: [ChatMessage(role: .user, content: "demo")])
        lastInputTokens = 8_200
        append(.user, "the api on web1 returns 500, fix it")
        append(.thinking, "A 500 from the API. Start with the service log, then read the code it points at.")
        let plan = [PlanStep("Read the service log", .completed), PlanStep("Find the failing code", .completed),
                    PlanStep("Fix it and restart", withApproval ? .inProgress : .completed)]
        append(.tool, Plan.render(plan), title: Plan.toolName, status: .ok)
        append(.tool, "KeyError: 'DATABASE_URL'\n  File \"/home/deploy/app/config.py\", line 12, in load",
               title: "ssh web1:app $ journalctl -u app -n 20 --no-pager", status: .ok)
        append(.tool, "config.py:12:url = os.environ['DATABASE_URL']\n.env:3:DB_URL=postgres://app@db/app",
               title: "grep DATABASE_URL|DB_URL in web1", status: .ok)
        append(.assistant, "config.py reads DATABASE_URL, but .env sets DB_URL. I'll accept both:")
        let title = "edit web1:config.py (1 → 1 lines)"
        let diff = "- url = os.environ['DATABASE_URL']\n+ url = os.environ.get('DATABASE_URL') or os.environ['DB_URL']"
        if withApproval {
            append(.tool, "", title: title, status: .running)
            isRunning = true
            pendingApproval = PendingApproval(summary: title, detail: diff)
        } else {
            append(.tool, diff, title: title, status: .ok)
            append(.tool, "{\"ok\": true}", title: "ssh web1:app $ sudo systemctl restart app && curl -s localhost:8000/health", status: .ok)
            append(.assistant, "Fixed. /health answers ok again.")
            usageLine = "8.2k in · 410 out · ctx 4% · 16s"
        }
    }
}
