import Foundation
import Observation
import SwiftUI
import TermCore
import TermSSH
import UIKit

/// One entry in the terminal tab's scrollback.
struct TerminalLine: Identifiable, Equatable {
    enum Kind: Equatable {
        case command, output, error, note
    }

    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
extension AppModel {
    // MARK: Terminal tab

    /// "local" for This iPhone, the host id for an SSH environment.
    var terminalKey: String { activeHost?.id.uuidString ?? "local" }

    /// Where the next command runs. Over SSH, nil means the login directory.
    var terminalDirectory: String? {
        if let host = activeHost { return terminalDirectories[terminalKey] ?? host.workingDirectory }
        return terminalDirectories["local"] ?? ""
    }

    var terminalPrompt: String {
        if let host = activeHost {
            return "\(host.username)@\(host.name):\(Self.shortPath(terminalDirectory ?? "~"))$"
        }
        return "iphone:\(WorkspaceShell.display(terminalDirectory ?? ""))$"
    }

    /// `/home/deploy/app/src` becomes `…/app/src`.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 2 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    func runTerminal() {
        let line = terminalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !terminalRunning else { return }
        terminalInput = ""
        terminalHistoryIndex = nil
        guard !line.isEmpty else { return }
        if terminalHistory.last != line { terminalHistory.append(line) }
        appendTerminal("\(terminalPrompt) \(line)", kind: .command)
        if line == "clear" {
            terminalLines = []
            return
        }
        if ShellCommand.needsTTY(line) {
            let name = line.split(separator: " ").first.map(String.init) ?? line
            return noteTerminal("\(name) needs a full-screen terminal, which this one is not. use a one-shot form, e.g. git --no-pager log, top -b -n 1, cat instead of less")
        }
        if let host = activeHost {
            runRemote(line, on: host)
        } else {
            let result = WorkspaceShell(root: workspace).run(line, in: terminalDirectories["local"] ?? "")
            terminalDirectories["local"] = result.directory
            if !result.output.isEmpty { appendTerminal(result.output, kind: result.status == 0 ? .output : .error) }
        }
    }

    func runRemote(_ line: String, on host: SSHHost) {
        terminalRunning = true
        let key = host.id.uuidString
        let directory = terminalDirectories[key] ?? host.workingDirectory
        terminalTask = Task { [weak self] in
            guard let self else { return }
            do {
                let shell = try await self.connect(to: host, inTerminal: true)
                let id = self.appendTerminal("", kind: .output)
                let (output, continuation) = AsyncStream<String>.makeStream()
                let forwarder = Task { [weak self] () -> String in
                    var raw = ""
                    for await chunk in output {
                        raw += chunk
                        if raw.utf8.count > 400_000 { raw = String(raw.suffix(200_000)) }
                        self?.setTerminal(id, ShellCommand.visible(raw))
                    }
                    return raw
                }
                let code: Int
                do {
                    code = try await shell.run(command: ShellCommand.wrap(line, in: directory), timeout: 900) {
                        continuation.yield($0)
                    }
                } catch {
                    continuation.finish()
                    _ = await forwarder.value
                    throw error
                }
                continuation.finish()
                let parsed = ShellCommand.parse(await forwarder.value)
                self.setTerminal(id, parsed.text.hasSuffix("\n") ? String(parsed.text.dropLast()) : parsed.text)
                if let moved = parsed.directory { self.terminalDirectories[key] = moved }
                let status = parsed.status ?? code
                if status != 0 { self.appendTerminal("[exit \(status)]", kind: .error) }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    self.appendTerminal("^C", kind: .note)
                } else {
                    self.appendTerminal("ssh \(host.name): \(error.localizedDescription)", kind: .error)
                }
            }
            self.terminalLines.removeAll { $0.kind == .output && $0.text.isEmpty }
            self.terminalRunning = false
            self.terminalTask = nil
            self.terminalTick += 1
        }
    }

    func stopTerminal() {
        terminalTask?.cancel()
    }

    @discardableResult
    func appendTerminal(_ text: String, kind: TerminalLine.Kind) -> UUID {
        let line = TerminalLine(kind: kind, text: text)
        terminalLines.append(line)
        if terminalLines.count > 1_500 { terminalLines.removeFirst(terminalLines.count - 1_500) }
        terminalTick += 1
        return line.id
    }

    func noteTerminal(_ text: String) {
        appendTerminal(text, kind: .note)
    }

    func setTerminal(_ id: UUID, _ text: String) {
        guard let index = terminalLines.lastIndex(where: { $0.id == id }) else { return }
        terminalLines[index].text = text
        terminalTick += 1
    }

    func clearTerminal() {
        terminalLines = []
    }

    func terminalHistoryUp() {
        guard !terminalHistory.isEmpty else { return }
        let index = max((terminalHistoryIndex ?? terminalHistory.count) - 1, 0)
        terminalHistoryIndex = index
        terminalInput = terminalHistory[index]
    }

    func terminalHistoryDown() {
        guard let current = terminalHistoryIndex else { return }
        if current + 1 < terminalHistory.count {
            terminalHistoryIndex = current + 1
            terminalInput = terminalHistory[current + 1]
        } else {
            terminalHistoryIndex = nil
            terminalInput = ""
        }
    }

    /// The last command and its output, as a text attachment for the next chat prompt.
    var lastTerminalBlock: String? {
        guard let start = terminalLines.lastIndex(where: { $0.kind == .command }) else { return nil }
        let text = terminalLines[start...].map(\.text).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func askAgentAboutTerminal() {
        guard let block = lastTerminalBlock else { return }
        let number = attachments.filter { $0.name.hasPrefix("terminal") }.count + 1
        attachments.append(PendingAttachment(name: number == 1 ? "terminal output" : "terminal output \(number)",
                                             kind: .text(Truncate.middle(block, limit: 24_000))))
        tab = .chat
    }

    func copyTerminal() {
        UIPasteboard.general.string = terminalLines.map(\.text).joined(separator: "\n")
    }

    func loadTerminalDemo() {
        let host = activeHost
        terminalLines = [
            TerminalLine(kind: .note, text: "connected to \(host?.address ?? "web1")"),
            TerminalLine(kind: .command, text: "deploy@web1:…/deploy/app$ git status -sb"),
            TerminalLine(kind: .output, text: "## main...origin/main\n M config.py"),
            TerminalLine(kind: .command, text: "deploy@web1:…/deploy/app$ systemctl status app --no-pager | head -3"),
            TerminalLine(kind: .output, text: "● app.service - API\n     Loaded: loaded (/etc/systemd/system/app.service; enabled)\n     Active: active (running) since Sun 09:41:07 UTC; 2min ago"),
            TerminalLine(kind: .command, text: "deploy@web1:…/deploy/app$ curl -s localhost:8000/health"),
            TerminalLine(kind: .output, text: "{\"ok\": true}"),
        ]
        terminalInput = "tail -n 50 /var/log/app.log"
    }
}
