import Foundation
import Testing
@testable import NyxCore

/// A shell that writes two lines with a gap between them, so the tap has to be called more than
/// once and the order of the two calls is observable rather than an accident of buffering.
private func twoLineSession() throws -> TerminalSession {
    let config = SessionConfig(shellPath: "/bin/sh",
                               argv: ["sh", "-c", "printf 'alpha\\n'; sleep 0.15; printf 'beta\\n'; sleep 30"],
                               environment: ["PATH": "/bin:/usr/bin"], cwd: nil,
                               cols: 80, rows: 24, palette: Themes.palette(named: "nyx-dark"))
    return try TerminalSession(config: config)
}

/// Polls rather than sleeps a fixed time: a PTY read can be scheduled late on a loaded machine, and
/// a fixed sleep would either be flaky or slow. Returns whether the condition ever held.
private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

@Test func outputTapReceivesExactlyTheBytesFedInOrder() throws {
    let session = try twoLineSession()
    defer { session.terminate() }
    let lock = NSLock()
    var chunks: [[UInt8]] = []
    session.onOutput = { bytes in
        lock.lock()
        chunks.append(bytes)
        lock.unlock()
    }
    session.start()

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: chunks.flatMap { $0 }, as: UTF8.self)
    }
    #expect(waitUntil { text().contains("beta") })

    // The PTY turns each \n into \r\n; nothing else is written, so the whole tapped stream is
    // knowable exactly -- which is the point: a tap that dropped, duplicated or reordered a chunk
    // would show up here and not in a "contains" check.
    #expect(text() == "alpha\r\nbeta\r\n")
    lock.lock()
    let callCount = chunks.count
    lock.unlock()
    #expect(callCount >= 2)
}

@Test func theOutputCountReadWithTheTerminalCountsEveryTappedChunk() throws {
    let session = try twoLineSession()
    defer { session.terminate() }
    let lock = NSLock()
    var taps = 0
    session.onOutput = { _ in
        lock.lock()
        taps += 1
        lock.unlock()
    }
    session.start()

    // Waits for the tap itself to have been called twice, not for the text to appear in the
    // terminal: the terminal is fed *before* the tap is called, so waiting on the transcript can
    // return in the window between the two and compare a count against a tap that has not run yet.
    func taken() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return taps
    }
    #expect(waitUntil { taken() >= 2 })
    // The count the terminal reports and the number of tap calls must agree once output has
    // stopped: that equality is what lets a remote host say which chunks its snapshot already
    // contains and which are still to come.
    let (transcript, count) = session.withTerminalAndOutputCount { t, n in (t.transcript(options: .plainText), n) }
    #expect(count == UInt64(taken()))
    #expect(transcript.contains("alpha"))
    #expect(transcript.contains("beta"))
}

@Test func aSessionWithNoTapStillRunsAndFeedsItsTerminal() throws {
    let session = try twoLineSession()
    defer { session.terminate() }
    session.start()

    #expect(waitUntil { session.withTerminal { $0.transcript(options: .plainText) }.contains("beta") })
    #expect(session.withTerminalAndOutputCount { _, n in n } > 0)
}

@Test func terminalSessionIsAPaneSession() throws {
    let session = try twoLineSession()
    defer { session.terminate() }
    // The point of the protocol is that `Pane` can hold one of these without knowing which kind it
    // is; if the surface ever drifts from what `Pane` uses, this stops compiling.
    let pane: PaneSession = session
    #expect(pane.pid > 0)
    pane.start()
    #expect(waitUntil { pane.withTerminal { $0.transcript(options: .plainText) }.contains("alpha") })
}
