import Testing
import Foundation
@testable import NyxCore

private func config(_ script: String, cols: Int = 40, rows: Int = 5) -> SessionConfig {
    SessionConfig(shellPath: "/bin/sh", argv: ["sh", "-c", script], environment: ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color"],
                  cwd: nil, cols: cols, rows: rows, scrollbackLimit: 100, palette: .xtermDefault())
}

private func waitForExit(_ s: TerminalSession, timeout: TimeInterval = 5) -> Int32? {
    let sem = DispatchSemaphore(value: 0)
    var code: Int32?
    s.onExit = { code = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + timeout)
    return code
}

@Test func sessionFeedsOutputIntoTerminal() throws {
    let s = try TerminalSession(config: config("printf 'a\\nb'; printf '\\033[1mbold'"))
    let code = waitForExit(s)
    #expect(code == 0)
    s.withTerminal { t in
        #expect(t.text()[0] == "a")
        #expect(t.text()[1] == "bbold")
        #expect(t.cell(1, 1).attrs.contains(.bold))
    }
}

@Test func sessionSendsInputAndAnswersReports() throws {
    let s = try TerminalSession(config: config("printf '\\033[6n'; read -r reply; printf '%s' \"$reply\" | od -c | head -1; echo got:$reply"))
    // CPR reply is written by the session automatically. The pty is in canonical mode and the
    // CPR bytes carry no trailing newline, so they sit in the child's input queue until the
    // newline-terminated "hello" we type below completes the line; `reply` ends up holding both.
    usleep(300_000)
    s.send(Array("hello\n".utf8))
    let code = waitForExit(s)
    #expect(code == 0)
    let lines = s.withTerminal { $0.text() }
    #expect(lines.contains { $0.contains("033   [   1   ;   1   R") })
    #expect(lines.contains { $0.contains("got:hello") })
}

@Test func sessionResizeReachesChild() throws {
    let s = try TerminalSession(config: config("sleep 0.3; stty size"))
    s.resize(cols: 66, rows: 22)
    _ = waitForExit(s)
    let lines = s.withTerminal { $0.text() }
    #expect(lines.contains("22 66"))
    #expect(s.withTerminal { ($0.cols, $0.rows) } == (66, 22))
}

@Test func sessionDeliversEvents() throws {
    var events: [TerminalEvent] = []
    let lock = NSLock()
    let s = try TerminalSession(config: config("printf '\\033]0;hi\\007'"))
    s.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
    _ = waitForExit(s)
    lock.lock(); defer { lock.unlock() }
    #expect(events == [.titleChanged("hi")])
}

@Test func sessionReportsExitCode() throws {
    let s = try TerminalSession(config: config("exit 3"))
    #expect(waitForExit(s) == 3)
    #expect(s.exitCode == 3)
}

@Test func terminateEndsSession() throws {
    let s = try TerminalSession(config: config("sleep 30"))
    usleep(100_000)
    s.terminate()
    let code = waitForExit(s)
    #expect(code != nil)
}

@Test func loginShellConfigUsesEnvironment() {
    let c = SessionConfig.loginShell(cols: 80, rows: 24, palette: .xtermDefault())
    #expect(c.argv.first?.hasPrefix("-") == true)
    #expect(c.environment["TERM"] == "xterm-256color")
    #expect(c.environment["COLORTERM"] == "truecolor")
    #expect(c.environment["TERM_PROGRAM"] == "Nyx")
}
