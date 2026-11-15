import Foundation

public enum Shell {
    /// Wraps `text` in single quotes so a POSIX shell passes it through unchanged.
    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// File tools on the SSH host, built from plain POSIX sh, base64, find and grep so nothing has to be
/// installed there. Every script runs under `sh -c`, whatever the user's login shell is.
public struct RemoteFiles: Sendable {
    public let shell: RemoteShell
    /// Directory that relative paths start from; nil means the login directory.
    public let root: String?

    public static let maxFileBytes = 2_000_000
    /// Base64 characters per upload command. Dropbear refuses commands over about 9 KB,
    /// so a failed first chunk starts over with the small size.
    static let chunkSizes = [60_000, 6_000]

    public init(shell: RemoteShell, root: String?) {
        self.shell = shell
        self.root = root
    }

    /// A shell word for `path`: absolute paths stay as they are, `~/x` goes under $HOME, anything else
    /// goes under `base` (resolved the same way; no base means $HOME).
    public static func pathExpression(_ path: String, base: String?) -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/") { return Shell.quote(path) }
        if path == "~" { return #""$HOME""# }
        if path.hasPrefix("~/") { return #""$HOME"/"# + Shell.quote(String(path.dropFirst(2))) }
        let start = base.map { pathExpression($0, base: nil) } ?? #""$HOME""#
        return path.isEmpty || path == "." ? start : start + "/" + Shell.quote(path)
    }

    func expression(_ path: String?) -> String {
        Self.pathExpression(path ?? ".", base: root)
    }

    /// `path` as seen from inside the root, so search results keep short relative paths.
    static func searchTarget(_ path: String?) -> String {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty, path != "." else { return "." }
        if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") { return pathExpression(path, base: nil) }
        return Shell.quote(path)
    }

    static func displayPrefix(_ path: String?) -> String {
        guard var path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty, path != "." else { return "" }
        if path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        return path.isEmpty ? "/" : path + "/"
    }

    static func lastLines(_ output: String, count: Int = 3) -> String {
        let lines = output.split(whereSeparator: { $0.isNewline }).suffix(count)
        return lines.isEmpty ? "no output" : lines.joined(separator: " / ")
    }

    /// Runs a POSIX sh script and collects its combined output.
    func exec(_ script: String, timeout: TimeInterval = 60, limit: Int = 400_000) async throws -> (code: Int, output: String) {
        try Task.checkCancellation()
        let buffer = TextBuffer(limit: limit)
        let code = try await shell.run(command: "sh -c " + Shell.quote(script), timeout: timeout) { buffer.append($0) }
        return (code, buffer.value)
    }

    // MARK: Read and write

    public func read(_ path: String) async throws -> String {
        let script = [
            "f=\(expression(path))",
            #"if [ ! -e "$f" ]; then echo termai:missing; exit 4; fi"#,
            #"if [ -d "$f" ]; then echo termai:directory; exit 5; fi"#,
            #"if [ ! -r "$f" ]; then echo termai:unreadable; exit 6; fi"#,
            #"n=$(wc -c < "$f" | tr -d ' ')"#,
            #"if [ "$n" -gt \#(Self.maxFileBytes) ]; then echo "termai:toolarge:$n"; exit 7; fi"#,
            "echo termai:begin",
            #"base64 < "$f" 2>/dev/null || openssl base64 < "$f""#,
            "echo termai:end",
        ].joined(separator: "; ")
        let (code, output) = try await exec(script, timeout: 120, limit: 3_600_000)
        if let begin = output.range(of: "termai:begin\n"), let end = output.range(of: "termai:end", options: .backwards),
           begin.upperBound <= end.lowerBound {
            let encoded = String(output[begin.upperBound..<end.lowerBound])
            guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
                throw ToolError(message: "could not decode \(path) from the host")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ToolError(message: "not a UTF-8 text file (\(data.count) bytes): \(path)")
            }
            return text
        }
        if output.contains("termai:missing") { throw ToolError(message: "file not found: \(path)") }
        if output.contains("termai:directory") { throw ToolError(message: "\(path) is a directory; use list_files or glob") }
        if output.contains("termai:unreadable") { throw ToolError(message: "permission denied: \(path)") }
        if let marker = output.range(of: "termai:toolarge:") {
            let size = output[marker.upperBound...].prefix { $0.isNumber }
            throw ToolError(message: "\(path) is \(size) bytes; read_file handles up to 2 MB. Use grep, or ssh_exec with head or sed -n for a part of it")
        }
        throw ToolError(message: "could not read \(path) (exit \(code)): " + Self.lastLines(output))
    }

    /// Writes through a base64 temp file and `cat >`, so an existing file keeps its owner and permissions.
    public func write(_ path: String, content: String) async throws {
        let target = expression(path)
        if content.isEmpty {
            let (code, output) = try await exec(#"f=\#(target); mkdir -p "$(dirname "$f")" && : > "$f""#)
            guard code == 0 else { throw ToolError(message: "could not write \(path): " + Self.lastLines(output)) }
            return
        }
        let temp = #""${TMPDIR:-/tmp}"/termai-"# + UUID().uuidString + ".b64"
        try await upload(Data(content.utf8).base64EncodedString(), to: temp)
        let script = [
            "f=\(target)",
            "t=\(temp)",
            #"mkdir -p "$(dirname "$f")" || { rm -f "$t"; exit 8; }"#,
            #"{ base64 -d < "$t" 2>/dev/null || base64 -D < "$t" 2>/dev/null || openssl base64 -d -A < "$t"; } > "$t.out""#,
            "c=$?",
            #"if [ $c -eq 0 ]; then cat "$t.out" > "$f"; c=$?; fi"#,
            #"rm -f "$t" "$t.out""#,
            "exit $c",
        ].joined(separator: "; ")
        let (code, output) = try await exec(script)
        guard code == 0 else { throw ToolError(message: "could not write \(path) (exit \(code)): " + Self.lastLines(output)) }
    }

    func upload(_ encoded: String, to temp: String) async throws {
        let bytes = Array(encoded.utf8)
        var sizes = Self.chunkSizes
        var size = sizes.removeFirst()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            let chunk = String(decoding: bytes[offset..<end], as: UTF8.self)
            let script = "printf %s '\(chunk)' \(offset == 0 ? ">" : ">>") \(temp)"
            var succeeded = false
            var failure: Error?
            do {
                succeeded = try await exec(script).code == 0
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = error
            }
            if !succeeded {
                if offset == 0, !sizes.isEmpty {
                    size = sizes.removeFirst()
                    continue
                }
                throw failure ?? (ToolError(message: "upload to the host failed") as Error)
            }
            offset = end
        }
    }

    // MARK: Browse and search

    public func list(_ path: String?) async throws -> String {
        let (code, output) = try await exec("cd \(expression(path)) && ls -1Ap", timeout: 30)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code == 0 else { throw ToolError(message: text.isEmpty ? "cannot list \(path ?? ".")" : Self.lastLines(text)) }
        return text.isEmpty ? "(empty)" : Truncate.middle(text, limit: 20_000)
    }

    /// Files under `path` matching `pattern`, relative to the root, sorted.
    public func glob(_ pattern: String, in path: String?) async throws -> [String] {
        let script = "cd \(expression(nil)) && cd \(Self.searchTarget(path)) || exit 3; "
            + #"find . \( -name .git -o -name node_modules -o -name .build -o -name DerivedData -o -name Pods \) -prune -o -type f -print 2>/dev/null | head -n 20000"#
        let (code, output) = try await exec(script, timeout: 90, limit: 4_000_000)
        if code == 3 { throw ToolError(message: "no such directory: \(path ?? ".")") }
        let matcher = Glob(pattern)
        let prefix = Self.displayPrefix(path)
        return output.split(whereSeparator: { $0.isNewline }).compactMap { line -> String? in
            var relative = String(line)
            if relative.hasPrefix("./") { relative.removeFirst(2) }
            return !relative.isEmpty && matcher.matches(relative) ? prefix + relative : nil
        }
        .sorted()
    }

    /// `path:line:text` for each matching line. Uses ripgrep when the host has it, grep -E otherwise.
    public func grep(_ pattern: String, in path: String?, glob: String?, ignoreCase: Bool) async throws -> [String] {
        let target = Self.searchTarget(path)
        let quoted = Shell.quote(pattern)
        let filter = glob.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var ripgrep = "rg -n -H --no-heading --color never"
        var fallback = "grep -rnHE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.build"
        if ignoreCase {
            ripgrep += " -i"
            fallback += " -i"
        }
        // Name-only globs filter on the host; globs with folders are applied to the results below.
        if let filter, !filter.contains("/") {
            ripgrep += " -g " + Shell.quote(filter)
            fallback += " --include=" + Shell.quote(filter)
        }
        let script = "cd \(expression(nil)) || exit 3; "
            + "{ if command -v rg >/dev/null 2>&1; then \(ripgrep) -e \(quoted) -- \(target); else \(fallback) -e \(quoted) \(target); fi; } 2>/dev/null"
            + " | head -n 300 | cut -c1-400"
        let (code, output) = try await exec(script, timeout: 120, limit: 2_000_000)
        if code == 3 { throw ToolError(message: "no such directory: \(root ?? "~")") }
        let matcher = filter.map { Glob($0) }
        return output.split(whereSeparator: { $0.isNewline }).compactMap { line -> String? in
            var text = String(line)
            if text.hasPrefix("./") { text.removeFirst(2) }
            if let matcher, !matcher.matches(String(text.prefix { $0 != ":" })) { return nil }
            return text
        }
    }

    // MARK: Project

    /// Absolute path of `path` (relative to the root) if it is a directory the user can enter.
    public func resolveDirectory(_ path: String) async throws -> String {
        let (code, output) = try await exec("cd \(expression(path)) && pwd", timeout: 30, limit: 20_000)
        let last = output.split(whereSeparator: { $0.isNewline }).last.map { String($0) } ?? ""
        guard code == 0, last.hasPrefix("/") else {
            throw ToolError(message: last.isEmpty ? "no such directory: \(path)" : last)
        }
        return last
    }

    /// AGENTS.md and CLAUDE.md from the root, for the system prompt.
    public func projectNotes() async -> String? {
        let script = "cd \(expression(nil)) 2>/dev/null || exit 0; "
            + #"for n in AGENTS.md CLAUDE.md; do if [ -f "$n" ]; then echo "termai:file:$n"; head -c 6000 "$n"; echo; fi; done; exit 0"#
        guard let result = try? await exec(script, timeout: 20, limit: 40_000) else { return nil }
        var sections: [String] = []
        for part in result.output.components(separatedBy: "termai:file:").dropFirst() {
            guard let newline = part.firstIndex(of: "\n") else { continue }
            let body = part[part.index(after: newline)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append("\(part[..<newline]):\n\(body)") }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
