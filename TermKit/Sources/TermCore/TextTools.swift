import Foundation

/// A tool failure with a message written for the model (and the user) to read.
struct ToolError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Collects streamed command output. Past `limit` bytes only the most recent half is kept,
/// so a runaway command cannot exhaust memory; the tail matters most.
public final class TextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    public let limit: Int

    public init(limit: Int = 400_000) {
        self.limit = limit
    }

    public func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        if text.utf8.count > limit { text = String(text.suffix(limit / 2)) }
    }

    public var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

public enum TextLines {
    /// Splits on line breaks (`\n`, or `\r\n` as one break). A final line break does not start an extra line.
    public static func split(_ text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    public static func count(_ text: String) -> Int {
        text.isEmpty ? 0 : split(text).count
    }

    /// `cat -n` style lines: a right-aligned number, a tab, then the line.
    public static func numbered(_ text: String, from start: Int, limit: Int? = nil, trailer: Bool = true) -> String {
        let lines = split(text)
        let first = max(start, 1)
        guard first <= lines.count else {
            return "(the file has \(lines.count) line\(lines.count == 1 ? "" : "s"))"
        }
        let last = min(lines.count, limit.map { first + max($0, 1) - 1 } ?? lines.count)
        var output = (first...last).map { number -> String in
            let label = String(number)
            return String(repeating: " ", count: max(0, 6 - label.count)) + label + "\t" + String(lines[number - 1])
        }
        .joined(separator: "\n")
        if trailer, last < lines.count {
            let rest = lines.count - last
            output += "\n… \(rest) more line\(rest == 1 ? "" : "s"); continue with offset \(last + 1)"
        }
        return output
    }

    /// The start of a new file as `+ ` lines, for previews.
    public static func addedPreview(_ text: String, maxLines: Int = 12) -> String {
        guard !text.isEmpty else { return "" }
        let lines = split(text)
        var shown = lines.prefix(maxLines).map { "+ " + String($0) }
        if lines.count > maxLines { shown.append("… \(lines.count - maxLines) more lines") }
        return shown.joined(separator: "\n")
    }
}

/// Exact-text replacement, the way edit_file works.
public enum TextEdit {
    public struct Outcome: Equatable, Sendable {
        public var text: String
        public var replacements: Int
        /// 1-based line where the first replacement starts.
        public var line: Int
    }

    public static func apply(to text: String, old: String, new: String, replaceAll: Bool = false) throws -> Outcome {
        guard !old.isEmpty else { throw ToolError(message: "old_string is empty; use write_file to create a file") }
        guard old != new else { throw ToolError(message: "old_string and new_string are identical; nothing to change") }
        // Byte-level matching: exact, and immune to grapheme clustering of \r\n.
        let bytes = Array(text.utf8)
        var oldBytes = Array(old.utf8)
        var newBytes = Array(new.utf8)
        var found = occurrences(of: oldBytes, in: bytes)
        if found.isEmpty, bytes.contains(13), oldBytes.contains(10), !oldBytes.contains(13) {
            // Models write \n; let the edit match a file with Windows line endings anyway.
            let crlfOld = crlf(oldBytes)
            found = occurrences(of: crlfOld, in: bytes)
            if !found.isEmpty {
                oldBytes = crlfOld
                newBytes = crlf(newBytes)
            }
        }
        guard let first = found.first else {
            throw ToolError(message: "old_string was not found. Read the file again and copy the text exactly, including indentation and line breaks")
        }
        if found.count > 1, !replaceAll {
            throw ToolError(message: "old_string matches \(found.count) places. Add surrounding lines to make it unique, or set replace_all to true")
        }
        let targets = replaceAll ? found : [first]
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + max(0, newBytes.count - oldBytes.count) * targets.count)
        var cursor = 0
        for start in targets {
            output.append(contentsOf: bytes[cursor..<start])
            output.append(contentsOf: newBytes)
            cursor = start + oldBytes.count
        }
        output.append(contentsOf: bytes[cursor...])
        let line = bytes[..<first].reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        return Outcome(text: String(decoding: output, as: UTF8.self), replacements: targets.count, line: line)
    }

    /// Start offsets of non-overlapping matches.
    static func occurrences(of needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var found: [Int] = []
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == needle[0] {
                var matched = 1
                while matched < needle.count, haystack[index + matched] == needle[matched] { matched += 1 }
                if matched == needle.count {
                    found.append(index)
                    index += needle.count
                    continue
                }
            }
            index += 1
        }
        return found
    }

    static func crlf(_ bytes: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + bytes.count / 20)
        for byte in bytes {
            if byte == 10 { result.append(13) }
            result.append(byte)
        }
        return result
    }

    /// A compact diff of one edit: changed lines as `- ` / `+ `, with up to two unchanged lines of context.
    public static func preview(old: String, new: String, maxLines: Int = 30) -> String {
        let oldLines: [String] = old.isEmpty ? [] : TextLines.split(old).map { String($0) }
        let newLines: [String] = new.isEmpty ? [] : TextLines.split(new).map { String($0) }
        var head = 0
        while head < oldLines.count, head < newLines.count, oldLines[head] == newLines[head] { head += 1 }
        var tail = 0
        while tail < oldLines.count - head, tail < newLines.count - head,
              oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] { tail += 1 }
        var lines: [String] = oldLines[..<head].suffix(2).map { "  " + $0 }
        lines += oldLines[head..<(oldLines.count - tail)].map { "- " + $0 }
        lines += newLines[head..<(newLines.count - tail)].map { "+ " + $0 }
        lines += oldLines[(oldLines.count - tail)...].prefix(2).map { "  " + $0 }
        if lines.isEmpty { return "(whitespace-only change)" }
        guard lines.count > maxLines else { return lines.joined(separator: "\n") }
        return (Array(lines.prefix(maxLines)) + ["… \(lines.count - maxLines) more lines"]).joined(separator: "\n")
    }
}

/// Shell-style file pattern. `*` and `?` stay within one path segment, `**/` spans folders, `{a,b}` picks one,
/// `[abc]` / `[!abc]` match one character. A pattern without a slash matches the file name in any folder.
public struct Glob {
    public let pattern: String
    private let regex: NSRegularExpression?
    private let nameOnly: Bool

    public init(_ pattern: String) {
        self.pattern = pattern
        nameOnly = !pattern.contains("/")
        regex = try? NSRegularExpression(pattern: Self.regularExpression(for: pattern), options: [])
    }

    public func matches(_ path: String) -> Bool {
        guard let regex else { return false }
        let target = nameOnly ? (path.split(separator: "/").last.map { String($0) } ?? path) : path
        return regex.firstMatch(in: target, options: [], range: NSRange(target.startIndex..., in: target)) != nil
    }

    static func regularExpression(for glob: String) -> String {
        var source = glob
        while source.hasPrefix("./") { source.removeFirst(2) }
        let characters = Array(source)
        var output = "^"
        var braces = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        output += "(?:.*/)?"
                        index += 3
                    } else {
                        output += ".*"
                        index += 2
                    }
                    continue
                }
                output += "[^/]*"
            case "?":
                output += "[^/]"
            case "{":
                braces += 1
                output += "(?:"
            case "}" where braces > 0:
                braces -= 1
                output += ")"
            case "," where braces > 0:
                output += "|"
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 {
                    var body = String(characters[(index + 1)..<close])
                    if body.hasPrefix("!") { body = "^" + String(body.dropFirst()) }
                    output += "[" + body.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    index = close + 1
                    continue
                }
                output += "\\["
            default:
                output += "\\^$.|?*+()[]{}".contains(character) ? "\\" + String(character) : String(character)
            }
            index += 1
        }
        return output + "$"
    }
}
