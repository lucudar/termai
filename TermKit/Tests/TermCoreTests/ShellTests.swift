import XCTest
@testable import TermCore

final class ShellTests: XCTestCase {
    func testWrapAndParse() {
        let wrapped = ShellCommand.wrap("ls -la", in: "~/my app")
        XCTAssertTrue(wrapped.hasPrefix("cd ~/'my app' 2>/dev/null || cd\nls -la\nprintf"))
        XCTAssertEqual(ShellCommand.wrap("pwd", in: nil).split(separator: "\n").first, "pwd")
        XCTAssertTrue(ShellCommand.wrap("pwd", in: "/srv/it's").hasPrefix(#"cd '/srv/it'\''s'"#))

        let parsed = ShellCommand.parse("file1\nfile2\n\n\u{1E}0\u{1E}/home/me/app\n")
        XCTAssertEqual(parsed.text, "file1\nfile2\n")
        XCTAssertEqual(parsed.status, 0)
        XCTAssertEqual(parsed.directory, "/home/me/app")
        XCTAssertNil(ShellCommand.parse("no marker").status)
        XCTAssertEqual(ShellCommand.parse("no marker").text, "no marker")
        XCTAssertEqual(ShellCommand.visible("out\n\u{1E}2\u{1E}/tmp"), "out")
        XCTAssertTrue(ShellCommand.needsTTY("vim notes.txt"))
        XCTAssertTrue(ShellCommand.needsTTY("/usr/bin/top"))
        XCTAssertFalse(ShellCommand.needsTTY("git status"))
    }

    #if os(macOS) || os(Linux)
    /// The wrapper runs for real through /bin/sh, so the marker survives a real shell.
    func testWrapperThroughARealShell() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", ShellCommand.wrap("cd /tmp && echo hi; false", in: "/")]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parsed = ShellCommand.parse(output)
        XCTAssertEqual(parsed.text.trimmingCharacters(in: .newlines), "hi")
        XCTAssertEqual(parsed.status, 1)
        XCTAssertTrue(parsed.directory?.hasSuffix("tmp") ?? false)
    }
    #endif

    func testWorkspaceShell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = WorkspaceShell(root: root)
        var directory = ""
        func run(_ line: String) -> (output: String, status: Int) {
            let result = shell.run(line, in: directory)
            directory = result.directory
            return (result.output, result.status)
        }
        XCTAssertEqual(run("mkdir notes").status, 0)
        XCTAssertEqual(run("cd notes").status, 0)
        XCTAssertEqual(directory, "notes")
        XCTAssertEqual(run("pwd").output, "~/notes")
        XCTAssertEqual(run("echo hello world > a.txt").status, 0)
        XCTAssertEqual(run("cat a.txt").output, "hello world\n")
        XCTAssertEqual(run("echo again >> a.txt").status, 0)
        XCTAssertEqual(run("head -n 1 a.txt").output, "hello world")
        XCTAssertEqual(run("cp a.txt b.txt").status, 0)
        XCTAssertEqual(run("ls").output, "a.txt  b.txt")
        XCTAssertEqual(run("cd ../..").status, 0)
        XCTAssertEqual(directory, "")
        XCTAssertEqual(run("ls").output, "notes/")
        XCTAssertEqual(run("cd missing").status, 1)
        XCTAssertEqual(run("rm notes").status, 1)
        XCTAssertEqual(run("rm -r notes").status, 0)
        XCTAssertEqual(run("ls").output, "")
        XCTAssertEqual(run("vim x").status, 127)
        XCTAssertEqual(WorkspaceShell.words(#"echo "a b" 'c d' e\ f"#), ["echo", "a b", "c d", "e f"])
        XCTAssertEqual(WorkspaceShell.display(""), "~")
    }
}
