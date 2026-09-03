import Testing
import Foundation
@testable import NyxCore

private func config(_ script: String, cols: Int = 40, rows: Int = 5) -> SessionConfig {
    SessionConfig(shellPath: "/bin/sh", argv: ["sh", "-c", script], environment: ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color"],
                  cwd: nil, cols: cols, rows: rows, scrollbackLimit: 100, palette: .xtermDefault())
}

/// Captures `onExit` before the session is started, so the child cannot exit before anyone is listening.
private final class ExitWatcher {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var code: Int32?

    func attach(to s: TerminalSession) {
        s.onExit = { [self] c in
            lock.lock(); code = c; lock.unlock()
            sem.signal()
        }
    }

    func wait(timeout: TimeInterval = 5) -> Int32? {
        _ = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return code
    }
}

/// Builds a session, wires the callbacks, and only then starts the reader thread.
private func startSession(_ script: String, cols: Int = 40, rows: Int = 5,
                          onEvent: ((TerminalEvent) -> Void)? = nil) throws -> (TerminalSession, ExitWatcher) {
    let s = try TerminalSession(config: config(script, cols: cols, rows: rows))
    let watcher = ExitWatcher()
    s.onEvent = onEvent
    watcher.attach(to: s)
    s.start()
    return (s, watcher)
}

@Test func sessionFeedsOutputIntoTerminal() throws {
    let (s, exit) = try startSession("printf 'a\\nb'; printf '\\033[1mbold'")
    #expect(exit.wait() == 0)
    s.withTerminal { t in
        #expect(t.text()[0] == "a")
        #expect(t.text()[1] == "bbold")
        #expect(t.cell(1, 1).attrs.contains(.bold))
    }
}

@Test func sessionSendsInputAndAnswersReports() throws {
    let (s, exit) = try startSession("printf '\\033[6n'; read -r reply; printf '%s' \"$reply\" | od -c | head -1; echo got:$reply")
    // CPR reply is written by the session automatically. The pty is in canonical mode and the
    // CPR bytes carry no trailing newline, so they sit in the child's input queue until the
    // newline-terminated "hello" we type below completes the line; `reply` ends up holding both.
    usleep(300_000)
    s.send(Array("hello\n".utf8))
    #expect(exit.wait() == 0)
    let lines = s.withTerminal { $0.text() }
    #expect(lines.contains { $0.contains("033   [   1   ;   1   R") })
    #expect(lines.contains { $0.contains("got:hello") })
}

@Test func sessionResizeReachesChild() throws {
    let (s, exit) = try startSession("sleep 0.3; stty size")
    s.resize(cols: 66, rows: 22)
    _ = exit.wait()
    let lines = s.withTerminal { $0.text() }
    #expect(lines.contains("22 66"))
    #expect(s.withTerminal { ($0.cols, $0.rows) } == (66, 22))
}

@Test func sessionDeliversEvents() throws {
    var events: [TerminalEvent] = []
    let lock = NSLock()
    let (_, exit) = try startSession("printf '\\033]0;hi\\007'") { e in
        lock.lock(); events.append(e); lock.unlock()
    }
    _ = exit.wait()
    lock.lock(); defer { lock.unlock() }
    #expect(events == [.titleChanged("hi")])
}

@Test func sessionReportsExitCode() throws {
    let (s, exit) = try startSession("exit 3")
    #expect(exit.wait() == 3)
    #expect(s.exitCode == 3)
}

@Test func terminateEndsSession() throws {
    let (s, exit) = try startSession("sleep 30")
    usleep(100_000)
    s.terminate()
    #expect(exit.wait() != nil)
}

@Test func sessionSurvivesDroppingLastReferenceUntilChildExits() throws {
    let watcher = ExitWatcher()
    do {
        let s = try TerminalSession(config: config("exit 5"))
        watcher.attach(to: s)
        s.start()
    }
    #expect(watcher.wait() == 5)
}

/// Regression: the reader thread used to start inside `init`, so a child that exited before the
/// caller finished wiring its callbacks lost `onExit` entirely. `TerminalView.init` does a pile of
/// AppKit work between the two, which is exactly the delay simulated here.
@Test func exitCallbackWiredAfterConstructionStillFires() throws {
    let s = try TerminalSession(config: config("exit 5"))
    usleep(20_000)
    let watcher = ExitWatcher()
    watcher.attach(to: s)
    s.start()
    #expect(watcher.wait() == 5)
    #expect(s.exitCode == 5)
}

@Test func loginShellConfigUsesEnvironment() {
    let c = SessionConfig.loginShell(cols: 80, rows: 24, palette: .xtermDefault())
    #expect(c.argv.first?.hasPrefix("-") == true)
    #expect(c.environment["TERM"] == "xterm-256color")
    #expect(c.environment["COLORTERM"] == "truecolor")
    #expect(c.environment["TERM_PROGRAM"] == "Nyx")
}
