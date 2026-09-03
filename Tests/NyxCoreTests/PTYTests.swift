import Testing
import Foundation
@testable import NyxCore

private func drain(_ pty: PTY) -> String {
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBytes { pty.read(into: $0) }
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

@Test func ptySpawnsShellAndReadsOutput() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "echo hello"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: nil, cols: 80, rows: 24)
    let text = drain(pty)
    #expect(text == "hello\r\n")
    #expect(pty.wait() == 0)
}

@Test func ptyReportsWindowSizeAndCwd() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "stty size; pwd"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: "/private/tmp", cols: 100, rows: 30)
    let text = drain(pty)
    _ = pty.wait()
    #expect(text.contains("30 100"))
    #expect(text.contains("/private/tmp"))
}

@Test func ptyResizeIsVisibleToChild() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "sleep 0.3; stty size"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: nil, cols: 80, rows: 24)
    pty.resize(cols: 120, rows: 40)
    let text = drain(pty)
    _ = pty.wait()
    #expect(text.contains("40 120"))
}

@Test func ptyWriteReachesChild() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "read line; echo got:$line"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: nil, cols: 80, rows: 24)
    #expect(pty.write(Array("ping\n".utf8)))
    let text = drain(pty)
    _ = pty.wait()
    #expect(text.contains("got:ping"))
}

@Test func ptyExecFailureExitsWith127() throws {
    let pty = try PTY(path: "/nonexistent/binary", argv: ["x"], environment: [:], cwd: nil, cols: 80, rows: 24)
    _ = drain(pty)
    #expect(pty.wait() == 127)
}
