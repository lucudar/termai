import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ToolResult: Equatable, Sendable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// A connected remote machine that can run shell commands.
public protocol RemoteShell: Sendable {
    var label: String { get }
    /// Runs `command`, streaming combined stdout/stderr, and returns the exit code.
    func run(command: String, timeout: TimeInterval, onOutput: @escaping @Sendable (String) -> Void) async throws -> Int
}

public protocol ToolRunning: Sendable {
    var specs: [ToolSpec] { get }
    func needsApproval(_ call: ToolCall) -> Bool
    /// One-line description shown in the transcript and in approval prompts.
    func summary(_ call: ToolCall) -> String
    func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult
}

public enum Truncate {
    /// Keeps the head and tail of long output so the model sees both the start and the final lines.
    public static func middle(_ text: String, limit: Int = 16_000) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        return String(text.prefix(half)) + "\n… [\(text.count - limit) characters omitted] …\n" + String(text.suffix(half))
    }
}

/// The agent's tools. Files live in the on-device workspace, or on the SSH host once a project directory
/// is set there; ssh_exec runs commands on the active host; fetch_url reads the web.
public struct ToolBox: ToolRunning {
    public let workspace: URL
    public let shell: RemoteShell?
    /// Folder on the SSH host that the file tools work in and commands start in. Needs `shell`.
    public let projectDirectory: String?

    public init(workspace: URL, shell: RemoteShell?, projectDirectory: String? = nil) {
        self.workspace = workspace
        self.shell = shell
        self.projectDirectory = projectDirectory
    }

    /// Set when the file tools act on the SSH host instead of the on-device workspace.
    var remote: RemoteFiles? {
        guard let shell, let projectDirectory, !projectDirectory.isEmpty else { return nil }
        return RemoteFiles(shell: shell, root: projectDirectory)
    }

    static let readOnlyTools: Set<String> = ["read_file", "list_files", "glob", "grep"]

    public var specs: [ToolSpec] {
        let onHost = remote != nil
        let place = onHost ? "on \(shell?.label ?? "the SSH host")" : "in the on-device workspace"
        let pathHelp = onHost ? "Relative to the project directory, or absolute" : "Relative to the workspace root"
        let read = ToolSpec(
            name: "read_file",
            description: "Read a text file \(place). Returns the raw text. For long files pass offset and limit to get a numbered range of lines.",
            parametersJSON: Self.schema([
                "path": ["type": "string", "description": pathHelp],
                "offset": ["type": "integer", "description": "First line to read, 1-based"],
                "limit": ["type": "integer", "description": "Number of lines to read"],
            ], required: ["path"]))
        let write = ToolSpec(
            name: "write_file",
            description: "Create or overwrite a text file \(place). Use edit_file to change part of an existing file.",
            parametersJSON: Self.schema([
                "path": ["type": "string", "description": pathHelp],
                "content": ["type": "string"],
            ], required: ["path", "content"]))
        let edit = ToolSpec(
            name: "edit_file",
            description: "Replace an exact piece of text in a file \(place). old_string must match the file exactly, including indentation and line breaks, and must occur once unless replace_all is true; include a few neighbouring lines to make it unique. Read the file before editing it.",
            parametersJSON: Self.schema([
                "path": ["type": "string", "description": pathHelp],
                "old_string": ["type": "string", "description": "Exact text to replace"],
                "new_string": ["type": "string", "description": "Replacement text"],
                "replace_all": ["type": "boolean", "description": "Replace every occurrence"],
            ], required: ["path", "old_string", "new_string"]))
        let list = ToolSpec(
            name: "list_files",
            description: "List a directory \(place).",
            parametersJSON: Self.schema([
                "path": ["type": "string", "description": onHost
                    ? "Relative to the project directory, or absolute; omit for the project directory"
                    : "Directory relative to the workspace root; omit for the root"],
            ]))
        let glob = ToolSpec(
            name: "glob",
            description: "Find files by name pattern \(place), e.g. **/*.swift or src/**/*.{ts,tsx}. A pattern without a slash matches file names in every folder. Skips .git, node_modules and build folders.",
            parametersJSON: Self.schema([
                "pattern": ["type": "string"],
                "path": ["type": "string", "description": "Folder to search in; omit for all"],
            ], required: ["pattern"]))
        let grep = ToolSpec(
            name: "grep",
            description: "Search file contents \(place) with a regular expression. Returns path:line:text for each matching line, at most 200.",
            parametersJSON: Self.schema([
                "pattern": ["type": "string", "description": "Regular expression"],
                "path": ["type": "string", "description": "File or folder to search; omit for all"],
                "glob": ["type": "string", "description": "Only search files matching this pattern, e.g. *.py"],
                "ignore_case": ["type": "boolean"],
            ], required: ["pattern"]))
        let fetch = ToolSpec(
            name: "fetch_url", description: "Fetch a web page or API response over HTTP(S) and return its text.",
            parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#)

        var specs: [ToolSpec] = [read, write, edit, list, glob, grep, fetch]
        if let shell {
            let start = onHost ? "Every call starts in the project directory \(projectDirectory ?? "")" : "Every call starts a fresh shell"
            specs.insert(ToolSpec(
                name: "ssh_exec",
                description: "Run a shell command on \(shell.label) over SSH. Non-interactive: no TTY, no prompts. Returns combined stdout/stderr and the exit code. \(start); cd does not carry over to the next call.",
                parametersJSON: #"{"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"number","description":"Default 120, max 900"}},"required":["command"]}"#), at: 0)
        }
        return specs
    }

    static func schema(_ properties: [String: [String: Any]], required: [String] = []) -> String {
        var object: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { object["required"] = required }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"type":"object"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func needsApproval(_ call: ToolCall) -> Bool {
        !Self.readOnlyTools.contains(call.name)
    }

    public func summary(_ call: ToolCall) -> String {
        let host = shell?.label ?? "?"
        let at = remote == nil ? "" : host + ":"
        let path = call.string("path")
        switch call.name {
        case "ssh_exec":
            return "ssh \(host)\(projectTag) $ \(call.string("command") ?? "")"
        case "read_file":
            var text = "read \(at)\(path ?? "")"
            if let offset = call.integer("offset") { text += ":\(offset)" }
            if let limit = call.integer("limit") { text += "+\(limit)" }
            return text
        case "write_file":
            return "write \(at)\(path ?? "") (\((call.string("content") ?? "").utf8.count) bytes)"
        case "edit_file":
            let removed = TextLines.count(call.string("old_string") ?? "")
            let added = TextLines.count(call.string("new_string") ?? "")
            let scope = call.flag("replace_all") ? "every match, " : ""
            return "edit \(at)\(path ?? "") (\(scope)\(removed) → \(added) lines)"
        case "list_files":
            return "ls \(at)\(path ?? ".")"
        case "glob":
            return "glob \(at)\(call.string("pattern") ?? "")" + (path.map { " in \($0)" } ?? "")
        case "grep":
            var text = "grep \(call.string("pattern") ?? "")"
            if let path {
                text += " in \(at)\(path)"
            } else if remote != nil {
                text += " in \(host)"
            }
            if let glob = call.string("glob") { text += " (\(glob))" }
            return text
        case "fetch_url":
            return "fetch \(call.string("url") ?? "")"
        default:
            return call.name
        }
    }

    /// `:app` when commands start in a project directory, so the transcript shows where they ran.
    private var projectTag: String {
        guard remote != nil, let projectDirectory else { return "" }
        return ":" + (projectDirectory.split(separator: "/").last.map { String($0) } ?? projectDirectory)
    }

    /// What an approval prompt shows under the summary: the diff of an edit, the start of a new file.
    public static func preview(_ call: ToolCall) -> String? {
        switch call.name {
        case "edit_file":
            return TextEdit.preview(old: call.string("old_string") ?? "", new: call.string("new_string") ?? "")
        case "write_file":
            let text = TextLines.addedPreview(call.string("content") ?? "")
            return text.isEmpty ? nil : text
        default:
            return nil
        }
    }

    public func run(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async -> ToolResult {
        do {
            if let remote, let result = try await runOnHost(call, remote, onOutput: onOutput) { return result }
            switch call.name {
            case "ssh_exec": return try await sshExec(call, onOutput: onOutput)
            case "read_file": return try readFile(call)
            case "write_file": return try writeFile(call, onOutput: onOutput)
            case "edit_file": return try editFile(call, onOutput: onOutput)
            case "list_files": return try listFiles(call)
            case "glob": return try globFiles(call)
            case "grep": return try grepFiles(call)
            case "fetch_url": return try await fetchURL(call)
            default: return ToolResult(text: "unknown tool: \(call.name)", isError: true)
            }
        } catch is CancellationError {
            return ToolResult(text: "cancelled", isError: true)
        } catch {
            return ToolResult(text: "error: \(error.localizedDescription)", isError: true)
        }
    }

    private func require(_ call: ToolCall, _ key: String) throws -> String {
        guard let value = call.string(key) else { throw ToolError(message: "missing argument: \(key)") }
        return value
    }

    static func readOutput(_ text: String, _ call: ToolCall) -> String {
        let offset = call.integer("offset")
        let limit = call.integer("limit")
        guard offset != nil || limit != nil else { return Truncate.middle(text, limit: 60_000) }
        return Truncate.middle(TextLines.numbered(text, from: offset ?? 1, limit: limit), limit: 60_000)
    }

    static func editReport(_ path: String, _ outcome: TextEdit.Outcome, newLines: Int) -> String {
        let count = outcome.replacements == 1 ? "1 replacement" : "\(outcome.replacements) replacements"
        let snippet = TextLines.numbered(outcome.text, from: max(outcome.line - 2, 1), limit: max(newLines, 1) + 4, trailer: false)
        return "edited \(path): \(count), first at line \(outcome.line)\n\(snippet)"
    }

    static func fileList(_ paths: [String], pattern: String) -> String {
        guard !paths.isEmpty else { return "no files match \(pattern)" }
        guard paths.count > 300 else { return paths.joined(separator: "\n") }
        return paths.prefix(300).joined(separator: "\n") + "\n… \(paths.count - 300) more files; narrow the pattern"
    }

    static func matchList(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "no matches" }
        guard lines.count > 200 else { return lines.joined(separator: "\n") }
        return lines.prefix(200).joined(separator: "\n") + "\n… more matches not shown; narrow the pattern or the path"
    }

    // MARK: Workspace

    var workspaceRoot: URL { workspace.standardizedFileURL.resolvingSymlinksInPath() }

    /// Resolves a model-supplied path, refusing anything that escapes the workspace.
    func resolve(_ path: String) throws -> URL {
        let root = workspaceRoot
        var relative = path.trimmingCharacters(in: .whitespaces)
        while relative.hasPrefix("/") { relative.removeFirst() }
        let target = relative.isEmpty || relative == "." ? root
            : root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root.path || target.path.hasPrefix(root.path + "/") else {
            throw ToolError(message: "path is outside the workspace: \(path)")
        }
        return target
    }

    private func readText(_ url: URL, _ path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError(message: "file not found: \(path)") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError(message: "not a UTF-8 text file (\(data.count) bytes)")
        }
        return text
    }

    private func readFile(_ call: ToolCall) throws -> ToolResult {
        let path = try require(call, "path")
        let text = try readText(try resolve(path), path)
        return ToolResult(text: Self.readOutput(text, call))
    }

    private func writeFile(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) throws -> ToolResult {
        let url = try resolve(try require(call, "path"))
        let content = try require(call, "content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
        let preview = TextLines.addedPreview(content)
        if !preview.isEmpty { onOutput(preview) }
        return ToolResult(text: "wrote \(content.utf8.count) bytes")
    }

    private func editFile(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) throws -> ToolResult {
        let path = try require(call, "path")
        let url = try resolve(path)
        let old = try require(call, "old_string")
        let new = try require(call, "new_string")
        let original = try readText(url, path)
        let outcome = try TextEdit.apply(to: original, old: old, new: new, replaceAll: call.flag("replace_all"))
        try Data(outcome.text.utf8).write(to: url, options: .atomic)
        onOutput(TextEdit.preview(old: old, new: new))
        return ToolResult(text: Self.editReport(path, outcome, newLines: TextLines.count(new)))
    }

    private func listFiles(_ call: ToolCall) throws -> ToolResult {
        let url = try resolve(call.string("path") ?? "")
        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        let lines = entries.map { entry -> String in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return values?.isDirectory == true ? entry.lastPathComponent + "/"
                : "\(entry.lastPathComponent)  \(values?.fileSize ?? 0)"
        }
        .sorted()
        return ToolResult(text: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }

    struct LocalFile {
        /// Relative to the folder searched, for glob matching.
        var relative: String
        /// Relative to the workspace root, for output.
        var display: String
        var absolute: String
    }

    /// Regular files under `path` (or just `path` when it is a file).
    func localFiles(under path: String?) throws -> [LocalFile] {
        let root = workspaceRoot
        let url = try resolve(path ?? "")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ToolError(message: "no such file or folder: \(path ?? ".")")
        }
        let display = url.path == root.path ? "" : String(url.path.dropFirst(root.path.count + 1))
        guard isDirectory.boolValue else {
            return [LocalFile(relative: url.lastPathComponent, display: display, absolute: url.path)]
        }
        let prefix = display.isEmpty ? "" : display + "/"
        return Self.walk(url.path).map { LocalFile(relative: $0, display: prefix + $0, absolute: url.path + "/" + $0) }
    }

    static let skippedFolders: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods"]

    /// Regular files below `directory` as sorted relative paths. Symlinks are not followed.
    static func walk(_ directory: String, limit: Int = 20_000) -> [String] {
        let files = FileManager.default
        var found: [String] = []
        var pending = [""]
        while let relative = pending.popLast() {
            let absolute = relative.isEmpty ? directory : directory + "/" + relative
            guard let names = try? files.contentsOfDirectory(atPath: absolute) else { continue }
            for name in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let type = (try? files.attributesOfItem(atPath: directory + "/" + path))?[.type] as? FileAttributeType
                if type == FileAttributeType.typeDirectory {
                    if !skippedFolders.contains(name) { pending.append(path) }
                } else if type == FileAttributeType.typeRegular {
                    found.append(path)
                    if found.count >= limit { return found.sorted() }
                }
            }
        }
        return found.sorted()
    }

    private func globFiles(_ call: ToolCall) throws -> ToolResult {
        let pattern = try require(call, "pattern")
        let matcher = Glob(pattern)
        let matches = try localFiles(under: call.string("path")).filter { matcher.matches($0.relative) }.map { $0.display }
        return ToolResult(text: Self.fileList(matches, pattern: pattern))
    }

    private func grepFiles(_ call: ToolCall) throws -> ToolResult {
        let pattern = try require(call, "pattern")
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: call.flag("ignore_case") ? [.caseInsensitive] : [])
        } catch {
            throw ToolError(message: "invalid regular expression: \(pattern)")
        }
        let filter = call.string("glob").flatMap { $0.isEmpty ? nil : Glob($0) }
        var results: [String] = []
        for file in try localFiles(under: call.string("path")) where filter?.matches(file.relative) ?? true {
            if results.count > 200 { break }
            guard let data = FileManager.default.contents(atPath: file.absolute), data.count <= 2_000_000,
                  !data.prefix(8_000).contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for (index, line) in TextLines.split(text).enumerated() {
                let line = String(line)
                guard regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                results.append("\(file.display):\(index + 1):" + (line.count > 300 ? String(line.prefix(300)) + "…" : line))
                if results.count > 200 { break }
            }
        }
        return ToolResult(text: Self.matchList(results))
    }

    // MARK: Files on the SSH host

    private func runOnHost(_ call: ToolCall, _ files: RemoteFiles,
                           onOutput: @escaping @Sendable (String) -> Void) async throws -> ToolResult? {
        switch call.name {
        case "read_file":
            let text = try await files.read(try require(call, "path"))
            return ToolResult(text: Self.readOutput(text, call))
        case "write_file":
            let path = try require(call, "path")
            let content = try require(call, "content")
            try await files.write(path, content: content)
            let preview = TextLines.addedPreview(content)
            if !preview.isEmpty { onOutput(preview) }
            return ToolResult(text: "wrote \(content.utf8.count) bytes to \(path)")
        case "edit_file":
            let path = try require(call, "path")
            let old = try require(call, "old_string")
            let new = try require(call, "new_string")
            let original = try await files.read(path)
            let outcome = try TextEdit.apply(to: original, old: old, new: new, replaceAll: call.flag("replace_all"))
            try await files.write(path, content: outcome.text)
            onOutput(TextEdit.preview(old: old, new: new))
            return ToolResult(text: Self.editReport(path, outcome, newLines: TextLines.count(new)))
        case "list_files":
            return ToolResult(text: try await files.list(call.string("path")))
        case "glob":
            let pattern = try require(call, "pattern")
            return ToolResult(text: Self.fileList(try await files.glob(pattern, in: call.string("path")), pattern: pattern))
        case "grep":
            let pattern = try require(call, "pattern")
            let lines = try await files.grep(pattern, in: call.string("path"), glob: call.string("glob"),
                                             ignoreCase: call.flag("ignore_case"))
            return ToolResult(text: Self.matchList(lines))
        default:
            return nil
        }
    }

    // MARK: Network

    private func fetchURL(_ call: ToolCall) async throws -> ToolResult {
        let raw = try require(call, "url")
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ToolError(message: "only http and https URLs are supported")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (status, body) = try await HTTP.collect(request, limit: 400_000)
        var text = String(decoding: body, as: UTF8.self)
        if text.range(of: "<html", options: .caseInsensitive) != nil { text = Self.stripHTML(text) }
        return ToolResult(text: "HTTP \(status)\n" + Truncate.middle(text), isError: !(200..<400).contains(status))
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<[^>]+>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for (entity, value) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: SSH

    private func sshExec(_ call: ToolCall, onOutput: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        guard let shell else {
            throw ToolError(message: "no SSH host is connected; the user can add one with /config and select it with /host")
        }
        var command = try require(call, "command")
        if remote != nil, let projectDirectory {
            command = "cd \(RemoteFiles.pathExpression(projectDirectory, base: nil)) || exit 97\n" + command
        }
        let timeout = min(max(call.number("timeout_seconds") ?? 120, 1), 900)
        let buffer = TextBuffer()
        let code = try await shell.run(command: command, timeout: timeout) { chunk in
            buffer.append(chunk)
            onOutput(chunk)
        }
        let output = Truncate.middle(buffer.value)
        return ToolResult(text: (output.isEmpty ? "" : output + "\n") + "[exit \(code)]", isError: code != 0)
    }
}
