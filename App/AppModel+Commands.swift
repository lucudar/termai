import Foundation
import Observation
import PhotosUI
import SwiftUI
import TermCore
import TermSSH
import UIKit

@MainActor
extension AppModel {
    // MARK: Commands

    func runCommand(_ name: String, _ args: String) {
        let changesSession = ["new", "sessions", "retry", "clear", "setup", "compact", "cd"].contains(name)
        if isRunning, changesSession, !((name == "sessions" || name == "cd") && args.isEmpty) {
            return info("busy. ^C stops the current run")
        }
        switch name {
        case "help":
            let width = Commands.all.map(\.usage.count).max() ?? 0
            let lines = Commands.all.map { $0.usage.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.help }
            info(lines.joined(separator: "\n") + "\n\n!<command>  run a command on the SSH host yourself\n^C          stop the current run")
        case "setup":
            setup = .name
            info("new API profile. esc cancels.\nprofile name (e.g. openrouter):")
        case "config":
            showSettings = true
        case "model": modelCommand(args)
        case "effort": effortCommand(args)
        case "profile": profileCommand(args)
        case "host": hostCommand(args)
        case "cd": cdCommand(args)
        case "compact": compactCommand()
        case "approve":
            if let mode = ApprovalMode(rawValue: args.lowercased()) {
                setApproval(mode)
            } else if !args.isEmpty {
                return fail("usage: /approve ask|auto")
            }
            info(settings.approvalMode == .ask
                 ? "approval: ask before commands, file writes and web requests"
                 : "approval: auto. tool calls run without asking")
        case "theme":
            if args.isEmpty {
                info(Theme.all.map { ($0.id == theme.id ? "* " : "  ") + $0.id.padding(toLength: 11, withPad: " ", startingAt: 0) + $0.name }
                    .joined(separator: "\n"))
            } else if let match = Theme.all.first(where: { $0.id == args.lowercased() || $0.name.lowercased().hasPrefix(args.lowercased()) }) {
                update { $0.themeID = match.id }
                info("theme: \(match.name)")
            } else {
                fail("unknown theme. options: " + Theme.all.map(\.id).joined(separator: ", "))
            }
        case "system":
            if args.isEmpty {
                info(settings.systemPrompt.isEmpty ? "no custom system prompt. /system <text> sets one" : settings.systemPrompt)
            } else {
                update { $0.systemPrompt = args.lowercased() == "reset" ? "" : args }
                info(settings.systemPrompt.isEmpty ? "system prompt reset" : "system prompt set")
            }
        case "new":
            startNewSession()
        case "sessions": sessionsCommand(args)
        case "retry":
            guard let index = session.messages.lastIndex(where: { $0.role == .user }) else { return fail("nothing to retry") }
            guard let profile = activeProfile, let model = activeModel else { return fail("no profile or model selected") }
            session.messages.removeSubrange((index + 1)...)
            startRun(profile: profile, model: model)
        case "copy":
            guard let last = session.transcript.last(where: { $0.kind == .assistant }) else { return fail("no answer to copy") }
            UIPasteboard.general.string = last.text
            info("copied \(last.text.count) characters")
        case "export":
            guard !session.isEmpty else { return fail("nothing to export yet") }
            shareItem = ShareItem(text: Markdown.export(session))
        case "clear":
            session.transcript.removeAll()
        default:
            fail("unknown command: /\(name)")
        }
    }

    func startNewSession() {
        storage.saveSession(session)
        session = Session()
        alwaysAllow = false
        usageLine = nil
        lastInputTokens = 0
        contextHintShown = false
        notesCache = [:]
        attachments = []
        if settings.alwaysStartWithDefault == true, let profile = activeProfile {
            update {
                $0.activeModel = profile.preferredModel
                $0.effort = profile.defaultEffort
            }
        }
        refreshRecents()
    }

    func effortCommand(_ args: String) {
        let value = args.lowercased()
        if value.isEmpty {
            let options = ["auto"] + Effort.allCases.map { $0.title.lowercased() }
            return info("effort: \(effort?.title ?? "Auto")\noptions: " + options.joined(separator: ", ")
                        + "\nsent as reasoning_effort, or output_config.effort for Anthropic; auto sends nothing")
        }
        if value == "auto" || value == "off" {
            setEffort(nil)
            return info("effort: Auto. nothing is sent, the provider decides")
        }
        guard let match = Effort.allCases.first(where: { $0.rawValue == value || $0.title.lowercased() == value }) else {
            return fail("usage: /effort auto|low|medium|high|extra|max")
        }
        setEffort(match)
        info("effort: \(match.title)")
    }

    func modelCommand(_ args: String) {
        guard let profile = activeProfile else { return fail("no API profile. run /setup") }
        let known = profile.pickerModels
        if args.isEmpty {
            let current = activeModel
            let lines = known.map { ($0 == current ? "* " : "  ") + $0 }
            info(lines.isEmpty ? "no models known for \(profile.name). /model <id> adds one" : lines.joined(separator: "\n"))
            return
        }
        // Accept an exact ID, a unique substring of a known ID, or a brand-new ID.
        let matches = known.filter { $0.localizedCaseInsensitiveContains(args) }
        let chosen = known.first { $0 == args } ?? (matches.count == 1 ? matches[0] : args)
        select(model: chosen, in: profile.id)
        info("model: \(chosen)")
    }

    func select(model: String, in profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let profile = profiles[index]
        // A hand-made list grows with models picked by ID; a discovered one is left as the gateway sent it.
        if !profile.pickerModels.contains(model), !profile.models.isEmpty || !profile.discovers {
            profiles[index].models.append(model)
            storage.saveProfiles(profiles)
        }
        let switching = settings.activeProfileID != profileID
        update { settings in
            settings.activeProfileID = profileID
            settings.activeModel = model
            if switching { settings.effort = profile.defaultEffort }
        }
    }

    func selectProfile(_ id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        update {
            $0.activeProfileID = profile.id
            $0.activeModel = profile.preferredModel
            $0.effort = profile.defaultEffort
        }
        if profile.discovers, profile.models.isEmpty, (profile.discoveredModels ?? []).isEmpty {
            refreshModels(for: profile.id, quiet: true)
        }
    }

    func profileCommand(_ args: String) {
        if args.isEmpty {
            let current = activeProfile?.id
            let lines = profiles.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.baseURL }
            return info(lines.isEmpty ? "no profiles. run /setup" : lines.joined(separator: "\n"))
        }
        guard let match = profiles.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no profile named \(args)")
        }
        selectProfile(match.id)
        info("profile: \(match.name) · \(match.preferredModel ?? "no model")")
    }

    func hostCommand(_ args: String) {
        if args.isEmpty {
            let current = activeHost?.id
            let lines = hosts.map { ($0.id == current ? "* " : "  ") + $0.name + "  " + $0.address }
            return info(lines.isEmpty ? "no SSH hosts. add one in /config" : lines.joined(separator: "\n") + (current == nil ? "\n(none selected)" : ""))
        }
        if ["off", "none"].contains(args.lowercased()) {
            selectHost(nil)
            return info("ssh: off")
        }
        guard let match = hosts.first(where: { $0.name.lowercased().hasPrefix(args.lowercased()) }) else {
            return fail("no host named \(args)")
        }
        selectHost(match.id)
        info("ssh: \(match.name) (\(match.address)). connects on first use")
    }

    func selectHost(_ id: UUID?) {
        update { $0.activeHostID = id }
        if connectionHostID != id { Task { await dropConnection() } }
    }

    func sessionsCommand(_ args: String) {
        if args.isEmpty {
            listedSessions = Array(storage.sessionSummaries().prefix(20))
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            let lines = listedSessions.enumerated().map { index, summary in
                "\(index + 1)".padding(toLength: 4, withPad: " ", startingAt: 0) + formatter.string(from: summary.updatedAt) + "  " + summary.title
            }
            return info(lines.isEmpty ? "no saved sessions" : lines.joined(separator: "\n") + "\n\n/sessions <n> resumes one")
        }
        guard let number = Int(args), listedSessions.indices.contains(number - 1),
              let loaded = storage.loadSession(id: listedSessions[number - 1].id) else {
            return fail("run /sessions first, then /sessions <n>")
        }
        resume(loaded)
        info("resumed: \(loaded.title)")
    }

    func resume(_ loaded: Session) {
        storage.saveSession(session)
        session = loaded
        alwaysAllow = false
        usageLine = nil
        lastInputTokens = 0
        contextHintShown = false
        notesCache = [:]
        attachments = []
        refreshRecents()
        scrollTick += 1
    }

    /// `/cd`: the project folder on the active host. File tools then work there and commands start there.
    func cdCommand(_ args: String) {
        guard let host = activeHost else {
            return fail("no SSH host selected. add one in /config, then pick it with /host <name>")
        }
        if args.isEmpty {
            if let directory = host.workingDirectory, !directory.isEmpty {
                return info("project: \(host.name):\(directory)\nfile tools and commands start there. /cd off goes back to the on-device workspace")
            }
            return info("no project folder on \(host.name). /cd <path> sets one, e.g. /cd ~/app")
        }
        if ["off", "none"].contains(args.lowercased()) {
            setWorkingDirectory(nil, for: host.id)
            return info("project folder cleared. file tools use the on-device workspace again")
        }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let shell = try await self.connect(to: host)
                let path = try await RemoteFiles(shell: shell, root: host.workingDirectory).resolveDirectory(args)
                self.setWorkingDirectory(path, for: host.id)
                self.info("project: \(host.name):\(path)\nfile tools and commands now start there. an AGENTS.md or CLAUDE.md in it is read automatically")
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.info("^C")
                } else {
                    self.fail("cd: \(error.localizedDescription)")
                }
            }
            self.finishRun()
        }
    }

    func setWorkingDirectory(_ path: String?, for hostID: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == hostID }) else { return }
        hosts[index].workingDirectory = path
        if let path { hosts[index].remember(directory: path) }
        storage.saveHosts(hosts)
        notesCache = [:]
    }

    /// `/compact`: the model summarizes the session, and the summary replaces the history it sees.
    func compactCommand() {
        guard !session.messages.isEmpty else { return info("nothing to compact yet") }
        guard let profile = activeProfile, let model = activeModel else { return fail("no profile or model selected") }
        let apiKey = secrets.secret(for: profile.secretKey) ?? ""
        let history = session.messages
        let before = ContextBudget.estimate(history)
        isRunning = true
        usageLine = nil
        info("compacting \(history.count) messages…")
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let request = profile.chatRequest(
                    apiKey: apiKey, model: model,
                    messages: Compaction.messages(for: history, contextTokens: profile.contextLimit))
                var summary = ""
                for try await event in OpenAIClient().streamChat(request) {
                    if case .text(let delta) = event { summary += delta }
                }
                try Task.checkCancellation()
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw UserFacingError(message: "the model sent an empty summary; nothing changed") }
                self.session.messages = Compaction.replacement(summary: trimmed)
                self.lastInputTokens = 0
                self.contextHintShown = false
                let after = ContextBudget.estimate(self.session.messages)
                self.info("compacted ~\(AppModel.compact(before)) → ~\(AppModel.compact(after)) tokens. the model now sees this summary:\n\n\(trimmed)")
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.info("^C. nothing changed")
                } else {
                    self.fail("compact: \(error.localizedDescription)")
                }
            }
            self.finishRun()
        }
    }

    // MARK: Background

    /// Asks iOS for extra time so a run can finish when the user switches apps mid-answer.
    func beginBackgroundGrace() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "agent run") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endBackgroundGrace()
            }
        }
    }

    func endBackgroundGrace() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Setup wizard

    func advanceSetup(_ step: SetupStep, _ value: String) {
        switch step {
        case .name:
            guard !value.isEmpty else { return info("profile name:") }
            append(.user, value)
            setup = .baseURL(name: value)
            info("base URL (e.g. https://api.openai.com/v1):")
        case .baseURL(let name):
            guard let url = URL(string: value), url.scheme?.hasPrefix("http") == true, url.host != nil else {
                return info("that is not an http(s) URL. base URL:")
            }
            append(.user, value)
            setup = .apiKey(name: name, baseURL: value)
            info("API key (hidden, stored in the Keychain; empty for none):")
        case .apiKey(let name, let baseURL):
            append(.user, value.isEmpty ? "(none)" : String(repeating: "•", count: min(value.count, 16)))
            info("fetching models…")
            Task { [weak self] in
                var models: [String] = []
                var problem: String?
                do {
                    // /setup has no format question: api.anthropic.com gets the Anthropic format, the rest OpenAI.
                    let format = Profile.guessFormat(baseURL)
                    models = try await OpenAIClient().listModels(
                        baseURL: baseURL, apiKey: value, authScheme: format == .anthropic ? .xAPIKey : .bearer, format: format)
                } catch {
                    problem = error.localizedDescription
                }
                guard let self, case .apiKey? = self.setup else { return }
                self.setup = .model(name: name, baseURL: baseURL, apiKey: value, models: models)
                if let problem {
                    self.fail("could not list models: \(problem)")
                    self.info("type a model ID to use anyway:")
                } else if models.isEmpty {
                    self.info("the endpoint listed no models. model ID:")
                } else {
                    let shown = models.prefix(12).joined(separator: "\n  ")
                    let more = models.count > 12 ? "\n  … \(models.count - 12) more" : ""
                    self.info("\(models.count) models:\n  \(shown)\(more)\ndefault model ID (enter for \(models[0])):")
                }
            }
        case .model(let name, let baseURL, let apiKey, let models):
            let chosen = value.isEmpty ? models.first : (models.first { $0 == value }
                ?? models.first { $0.localizedCaseInsensitiveContains(value) } ?? value)
            guard let chosen else { return info("model ID:") }
            append(.user, chosen)
            var profile = Profile(name: name, baseURL: baseURL, models: models, defaultModel: chosen)
            if !profile.models.contains(chosen) { profile.models.insert(chosen, at: 0) }
            saveProfile(profile, apiKey: apiKey)
            update {
                $0.activeProfileID = profile.id
                $0.activeModel = chosen
            }
            setup = nil
            info("saved. \(name) · \(chosen) is active. say something.")
        }
    }
}
