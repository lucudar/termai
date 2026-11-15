import Foundation
import Observation
import PhotosUI
import SwiftUI
import TermCore
import TermSSH
import UIKit

struct PendingApproval: Identifiable, Equatable {
    let id = UUID()
    let summary: String
    /// Diff or file preview shown under the summary.
    var detail: String? = nil
}

struct ShareItem: Identifiable {
    let id = UUID()
    let text: String
}

/// The `/setup` wizard: each step consumes one line of input.
enum SetupStep {
    case name
    case baseURL(name: String)
    case apiKey(name: String, baseURL: String)
    case model(name: String, baseURL: String, apiKey: String, models: [String])

    var placeholder: String {
        switch self {
        case .name: return "profile name"
        case .baseURL: return "base url"
        case .apiKey: return "api key (hidden)"
        case .model: return "model id"
        }
    }

    var isSecret: Bool {
        if case .apiKey = self { return true }
        return false
    }
}

struct UserFacingError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class AppModel {
    var profiles: [Profile] = []
    var hosts: [SSHHost] = []
    var settings = AppSettings()
    var session = Session()
    var input = ""
    var isRunning = false
    var pendingApproval: PendingApproval?
    var setup: SetupStep?
    var showSettings = false
    var shareItem: ShareItem?
    var usageLine: String?
    /// Bumped when the transcript should jump to the bottom.
    var scrollTick = 0
    var showSidebar = false
    var recentSessions: [SessionSummary] = []
    /// Files and photos for the next prompt.
    var attachments: [PendingAttachment] = []
    var showPhotoPicker = false
    var showFileImporter = false
    /// The "Open folder…" prompt.
    var promptForFolder = false
    /// A new SSH environment being set up from the environment menu.
    var editingHost: SSHHost?
    /// Prompt tokens of the last request: the context ring and `ctx %`.
    var lastInputTokens = 0

    @ObservationIgnored let storage: Storage
    @ObservationIgnored let secrets: SecretStore
    @ObservationIgnored let workspace: URL
    @ObservationIgnored var runTask: Task<Void, Never>?
    @ObservationIgnored var approvalContinuation: CheckedContinuation<ApprovalDecision, Never>?
    @ObservationIgnored var alwaysAllow = false
    @ObservationIgnored var connection: SSHConnection?
    @ObservationIgnored var connectionHostID: UUID?
    @ObservationIgnored var assistantItemID: UUID?
    @ObservationIgnored var toolItems: [String: UUID] = [:]
    @ObservationIgnored var promptHistory: [String] = []
    @ObservationIgnored var historyIndex: Int?
    @ObservationIgnored var runStart = Date()
    @ObservationIgnored var listedSessions: [SessionSummary] = []
    @ObservationIgnored var thinkingItemID: UUID?
    @ObservationIgnored var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// AGENTS.md / CLAUDE.md per host and project folder, read once per session.
    @ObservationIgnored var notesCache: [String: String] = [:]
    @ObservationIgnored var runContextLimit = Profile.defaultContextWindow
    @ObservationIgnored var contextHintShown = false

    init() {
        let files = FileManager.default
        let arguments = ProcessInfo.processInfo.arguments
        let isDemo = arguments.contains("-demo")
        let support: URL
        if isDemo {
            // Screenshot mode: sample content, nothing read from or written to real storage.
            let scratch = files.temporaryDirectory.appendingPathComponent("termai-demo-\(UUID().uuidString)")
            support = scratch.appendingPathComponent("support")
            workspace = scratch.appendingPathComponent("workspace")
            secrets = InMemorySecretStore()
        } else {
            support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TermAI")
            workspace = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            secrets = KeychainStore()
        }
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        try? files.createDirectory(at: workspace, withIntermediateDirectories: true)
        storage = Storage(directory: support)
        profiles = storage.loadProfiles()
        hosts = storage.loadHosts()
        settings = storage.loadSettings()

        if isDemo {
            loadDemo(withApproval: arguments.contains("-demoApproval"), home: arguments.contains("-demoHome"))
            showSettings = arguments.contains("-demoSettings")
            showSidebar = arguments.contains("-demoSidebar")
        } else {
            refreshRecents()
            // Model discovery: fill the picker from /models unless a hand-made list makes it unnecessary.
            if let profile = activeProfile, profile.discovers, profile.models.isEmpty {
                refreshModels(for: profile.id, quiet: true)
            }
        }
    }

    // MARK: Derived state

    var theme: Theme { Theme.named(settings.themeID) }
    var palette: Palette { Palette(theme: theme, fontSize: settings.fontSize) }

    var activeProfile: Profile? {
        profiles.first { $0.id == settings.activeProfileID } ?? profiles.first
    }

    var activeModel: String? {
        if let model = settings.activeModel, !model.isEmpty { return model }
        return activeProfile?.preferredModel
    }

    var activeHost: SSHHost? {
        hosts.first { $0.id == settings.activeHostID }
    }

    var effort: Effort? { settings.effort }

    var contextLimit: Int { activeProfile?.contextLimit ?? Profile.defaultContextWindow }

    var contextFraction: Double { min(1, Double(lastInputTokens) / Double(max(contextLimit, 1))) }

    var contextSummary: String { "\(Self.tokens(lastInputTokens)) / \(Self.tokens(contextLimit))" }

    /// `claude-sonnet-5` for `anthropic/claude-sonnet-5`.
    var activeModelShortName: String {
        guard let model = activeModel else { return activeProfile == nil ? "No gateway" : "No model" }
        return model.split(separator: "/").last.map { String($0) } ?? model
    }

    /// The home screen shows until the session has a prompt, an answer or a command in it.
    var showsHome: Bool {
        let content: Set<TranscriptItem.Kind> = [.user, .assistant, .tool, .thinking]
        return !session.transcript.contains { content.contains($0.kind) }
    }

    /// The latest note or error, shown under the cards on the home screen.
    var homeStatus: TranscriptItem? {
        session.transcript.last { $0.kind == .info || $0.kind == .error }
    }

    var environmentName: String { activeHost?.name ?? "This iPhone" }

    var folderName: String {
        guard let host = activeHost else { return "Workspace" }
        guard let directory = host.workingDirectory, !directory.isEmpty else { return "No folder" }
        return directory.split(separator: "/").last.map { String($0) } ?? directory
    }

    var suggestions: [SlashCommand] {
        setup == nil && pendingApproval == nil ? Commands.suggestions(for: input) : []
    }

    var inputIsSecret: Bool { setup?.isSecret ?? false }

    var placeholder: String {
        if let setup { return setup.placeholder }
        if pendingApproval != nil { return "y / n / a" }
        if isRunning { return "Working… ■ stops it" }
        return palette.monospaced ? "message, /command or !shell" : "Describe a task or ask a question"
    }

    func update(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        storage.saveSettings(settings)
    }

    // MARK: Transcript

    @discardableResult
    func append(_ kind: TranscriptItem.Kind, _ text: String, title: String? = nil,
                status: TranscriptItem.Status? = nil) -> UUID {
        let item = TranscriptItem(kind: kind, text: text, title: title, status: status)
        session.transcript.append(item)
        return item.id
    }

    func info(_ text: String) { append(.info, text) }
    func fail(_ text: String) { append(.error, text) }

    func mutateItem(_ id: UUID?, _ change: (inout TranscriptItem) -> Void) {
        guard let id, let index = session.transcript.lastIndex(where: { $0.id == id }) else { return }
        change(&session.transcript[index])
    }

    func appendOutput(_ id: UUID?, _ chunk: String) {
        mutateItem(id) { item in
            item.text += chunk
            // Only the tail is shown; keep the stored text bounded for long-running commands.
            if item.text.utf8.count > 48_000 { item.text = String(item.text.suffix(16_000)) }
        }
    }

    // MARK: Input

    func submit() {
        let raw = input
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        historyIndex = nil
        scrollTick += 1

        if let step = setup {
            advanceSetup(step, trimmed)
            return
        }
        if pendingApproval != nil {
            switch trimmed.lowercased() {
            case "y", "yes": resolveApproval(.allow)
            case "a", "always": allowAlways()
            case "n", "no": resolveApproval(.deny)
            default: break
            }
            return
        }

        let parsed = Commands.parse(raw)
        if parsed != .empty, promptHistory.last != trimmed { promptHistory.append(trimmed) }
        switch parsed {
        case .empty:
            if !attachments.isEmpty { send("") }
        case .prompt(let text): send(text)
        case .shell(let command): runShell(command)
        case .command(let name, let args):
            append(.user, trimmed)
            runCommand(name, args)
        }
    }

    func historyUp() {
        guard !promptHistory.isEmpty else { return }
        let index = max((historyIndex ?? promptHistory.count) - 1, 0)
        historyIndex = index
        input = promptHistory[index]
    }

    func historyDown() {
        guard let current = historyIndex else { return }
        if current + 1 < promptHistory.count {
            historyIndex = current + 1
            input = promptHistory[current + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func completeSuggestion() {
        if let first = suggestions.first { input = "/\(first.name) " }
    }

    func escape() {
        if setup != nil {
            setup = nil
            info("setup cancelled")
        }
        input = ""
        historyIndex = nil
    }
}
