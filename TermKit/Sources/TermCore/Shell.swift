import Foundation

/// One command typed in the terminal tab, run over SSH in the directory the previous command left.
public enum ShellCommand {
    static let marker: Character = "\u{1E}"

    /// `command` run in `directory`, followed by a marker line with the exit code and the new directory.
    public static func wrap(_ command: String, in directory: String?) -> String {
        var lines: [String] = []
        if let directory, !directory.isEmpty { lines.append("cd \(quotePath(directory)) 2>/dev/null || cd") }
        lines.append(command)
        lines.append(#"printf '\n\036%s\036%s\n' "$?" "$(pwd)""#)
        return lines.joined(separator: "\n")
    }

    /// `~` stays unquoted so the remote shell expands it.
    static func quotePath(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + RemoteFiles.quote(String(path.dropFirst(2))) }
        return RemoteFiles.quote(path)
    }

    /// The output without the marker, plus the exit code and directory when the marker arrived.
    public static func parse(_ output: String) -> (text: String, status: Int?, directory: String?) {
        guard let range = output.range(of: "\n\u{1E}", options: .backwards) else { return (output, nil, nil) }
        let tail = output[range.upperBound...].split(separator: marker, maxSplits: 1, omittingEmptySubsequences: false)
        guard tail.count == 2, let status = Int(tail[0]) else { return (output, nil, nil) }
        let directory = tail[1].trimmingCharacters(in: .newlines)
        return (String(output[..<range.lowerBound]), status, directory.isEmpty ? nil : directory)
    }

    /// What to show while output streams: everything before a marker.
    public static func visible(_ output: String) -> String {
        guard let range = output.range(of: "\n\u{1E}") else { return output }
        return String(output[..<range.lowerBound])
    }

    /// Full-screen programs that need a TTY, which a one-command-at-a-time terminal cannot give them.
    public static func needsTTY(_ command: String) -> Bool {
        let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let name = first.split(separator: "/").last.map(String.init) ?? first
        return ["vim", "vi", "nvim", "nano", "emacs", "less", "more", "man", "top", "htop", "btop", "tmux", "screen",
                "watch", "mc", "ranger"].contains(name)
    }
}

/// The terminal on "This iPhone". iOS apps cannot start processes, so this is a small set of file
/// commands inside the app's workspace; paths cannot leave it.
public struct WorkspaceShell {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static let commands = ["help", "pwd", "ls", "cd", "cat", "head", "tail", "mkdir", "touch", "rm", "mv", "cp",
                                  "echo", "clear"]

    /// Runs one command line in `directory` (relative to the workspace, "" for its top).
    public func run(_ line: String, in directory: String) -> (output: String, status: Int, directory: String) {
        var words = Self.words(line)
        guard !words.isEmpty else { return ("", 0, directory) }
        let name = words.removeFirst()
        let flags = Set(words.filter { $0.hasPrefix("-") && $0.count > 1 && Int($0) == nil })
        let args = words.filter { !($0.hasPrefix("-") && $0.count > 1 && Int($0) == nil) }
        let files = FileManager.default
        do {
            switch name {
            case "help":
                return ("built in on This iPhone: " + Self.commands.joined(separator: ", ")
                        + "\nfiles live in the app's workspace (Files \u{203A} On My iPhone \u{203A} TermAI)."
                        + "\npick an SSH environment for a full shell.", 0, directory)
            case "pwd":
                return (Self.display(directory), 0, directory)
            case "cd":
                let target = args.first ?? "~"
                let path = Self.relative(target, from: directory)
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: url(path).path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    return ("cd: \(target): no such directory", 1, directory)
                }
                return ("", 0, path)
            case "ls":
                let path = Self.relative(args.first ?? ".", from: directory)
                var isDirectory: ObjCBool = false
                guard files.fileExists(atPath: url(path).path, isDirectory: &isDirectory) else {
                    return ("ls: \(args.first ?? "."): no such file or directory", 1, directory)
                }
                guard isDirectory.boolValue else { return ((args.first ?? path), 0, directory) }
                let names = try files.contentsOfDirectory(atPath: url(path).path)
                    .filter { flags.contains("-a") || !$0.hasPrefix(".") }
                    .sorted { $0.lowercased() < $1.lowercased() }
                let shown = names.map { name -> String in
                    var isFolder: ObjCBool = false
                    files.fileExists(atPath: url(path).appendingPathComponent(name).path, isDirectory: &isFolder)
                    return isFolder.boolValue ? name + "/" : name
                }
                return (shown.joined(separator: flags.contains("-l") || flags.contains("-1") ? "\n" : "  "), 0, directory)
            case "cat", "head", "tail":
                guard !args.isEmpty else { return ("\(name): missing file", 1, directory) }
                var count = 10
                if let index = words.firstIndex(of: "-n"), index + 1 < words.count, let value = Int(words[index + 1]) {
                    count = value
                }
                let paths = name == "cat" ? args : args.filter { Int($0) == nil }
                var parts: [String] = []
                for argument in paths {
                    let text = try String(contentsOf: url(Self.relative(argument, from: directory)), encoding: .utf8)
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    switch name {
                    case "head": parts.append(lines.prefix(count).joined(separator: "\n"))
                    case "tail": parts.append(lines.suffix(count).joined(separator: "\n"))
                    default: parts.append(text)
                    }
                }
                return (Truncate.middle(parts.joined(separator: "\n"), limit: 60_000), 0, directory)
            case "mkdir":
                guard !args.isEmpty else { return ("mkdir: missing directory", 1, directory) }
                for argument in args {
                    try files.createDirectory(at: url(Self.relative(argument, from: directory)),
                                              withIntermediateDirectories: true)
                }
                return ("", 0, directory)
            case "touch":
                guard !args.isEmpty else { return ("touch: missing file", 1, directory) }
                for argument in args {
                    let target = url(Self.relative(argument, from: directory))
                    if !files.fileExists(atPath: target.path) { try Data().write(to: target) }
                }
                return ("", 0, directory)
            case "rm":
                guard !args.isEmpty else { return ("rm: missing operand", 1, directory) }
                for argument in args {
                    let path = Self.relative(argument, from: directory)
                    guard !path.isEmpty else { return ("rm: refusing to remove the workspace", 1, directory) }
                    var isDirectory: ObjCBool = false
                    guard files.fileExists(atPath: url(path).path, isDirectory: &isDirectory) else {
                        return ("rm: \(argument): no such file or directory", 1, directory)
                    }
                    if isDirectory.boolValue, !(flags.contains("-r") || flags.contains("-rf") || flags.contains("-R")) {
                        return ("rm: \(argument): is a directory (use rm -r)", 1, directory)
                    }
                    try files.removeItem(at: url(path))
                }
                return ("", 0, directory)
            case "mv", "cp":
                guard args.count == 2 else { return ("usage: \(name) <from> <to>", 1, directory) }
                let source = url(Self.relative(args[0], from: directory))
                var target = url(Self.relative(args[1], from: directory))
                var isDirectory: ObjCBool = false
                if files.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    target = target.appendingPathComponent(source.lastPathComponent)
                }
                if name == "mv" {
                    try files.moveItem(at: source, to: target)
                } else {
                    try files.copyItem(at: source, to: target)
                }
                return ("", 0, directory)
            case "echo":
                if let index = words.firstIndex(where: { $0 == ">" || $0 == ">>" }), index + 1 < words.count {
                    let text = words[..<index].joined(separator: " ") + "\n"
                    let target = url(Self.relative(words[index + 1], from: directory))
                    if words[index] == ">>", let handle = try? FileHandle(forWritingTo: target) {
                        handle.seekToEndOfFile()
                        handle.write(Data(text.utf8))
                        handle.closeFile()
                    } else {
                        try Data(text.utf8).write(to: target)
                    }
                    return ("", 0, directory)
                }
                return (words.joined(separator: " "), 0, directory)
            default:
                return ("\(name): not available on This iPhone. type help, or pick an SSH environment for a full shell",
                        127, directory)
            }
        } catch {
            return ("\(name): \(error.localizedDescription)", 1, directory)
        }
    }

    func url(_ relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// `path` resolved against `directory`, as a path inside the workspace ("" is its top).
    static func relative(_ path: String, from directory: String) -> String {
        var parts = path.hasPrefix("/") || path.hasPrefix("~") ? [] : directory.split(separator: "/").map(String.init)
        let rest = path.hasPrefix("~") ? String(path.dropFirst()) : path
        for part in rest.split(separator: "/") {
            switch part {
            case ".", "":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }

    /// `~` for the top of the workspace, `~/notes` below it.
    public static func display(_ directory: String) -> String { directory.isEmpty ? "~" : "~/" + directory }

    /// Splits a command line into words, honouring single and double quotes and backslashes.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var started = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character == " " || character == "\t" {
                if started || !current.isEmpty { words.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
}
