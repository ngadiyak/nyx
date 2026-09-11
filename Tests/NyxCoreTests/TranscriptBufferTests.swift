import Testing
@testable import NyxCore

/// A shell with prompt marks, four commands deep, and then a full-screen program on top of it --
/// which is what a host looks like at the moment somebody attaches to the Mac an agent is running
/// on. `\u{1b}[?1049h` is the switch every such program makes.
private func hostInVim() -> Terminal {
    let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 500)
    for command in ["one", "two", "three"] {
        t.feed("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}\(command)\r\n\u{1b}]133;C\u{7}")
        t.feed("out-\(command)\r\n\u{1b}]133;D;0\u{7}")
    }
    t.feed("\u{1b}]133;A\u{7}$ \u{1b}]133;B\u{7}vim x\r\n\u{1b}]133;C\u{7}")
    t.feed("\u{1b}[?1049h\u{1b}[H~\r\n~\r\n\"x\" [New]")
    return t
}

/// The bug, in one assertion. `absoluteRow` is the scrollback followed by the *active* screen, and
/// on the alternate screen the primary one is not in it at all -- so a snapshot taken with it lost
/// every block still on the host's screen (seven on the host, one on the client) and put vim's
/// tildes in the client's primary buffer, where the program's exit had nothing to restore.
@Test func theActiveTranscriptLosesThePrimaryScreenWhileTheAltScreenIsUp() {
    let t = hostInVim()
    #expect(t.modes.altScreen)
    let active = t.transcript(rows: 0..<t.rowCount(of: .active), buffer: .active)
    #expect(active.contains("~"))
    #expect(!active.contains("vim x"))          // the command that is still on the host's screen
}

@Test func thePrimaryTranscriptKeepsTheScreenTheProgramCoveredAndItsMarks() {
    let t = hostInVim()
    let primary = t.transcript(rows: 0..<t.rowCount(of: .primary), buffer: .primary)
    for command in ["one", "two", "three", "vim x"] {
        #expect(primary.contains(command))
    }
    #expect(primary.contains("\u{1b}]133;A\u{7}"))   // the marks the client's blocks are built from
    #expect(!primary.contains("\"x\" [New]"))        // and nothing of the program on top
}

@Test func theAlternateTranscriptIsTheProgramsScreenAlone() {
    let t = hostInVim()
    let alt = t.transcript(rows: 0..<t.rowCount(of: .alternate), buffer: .alternate)
    #expect(alt.contains("\"x\" [New]"))
    #expect(!alt.contains("out-one"))
}

/// Off the alternate screen the three buffers agree, so a caller that always asks for `.primary`
/// is not a caller with two code paths.
@Test func onThePrimaryScreenTheBuffersAgree() {
    let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 500)
    t.feed("hello\r\n")
    #expect(t.rowCount(of: .active) == t.rowCount(of: .primary))
    #expect(t.transcript(rows: 0..<t.rowCount(of: .active), buffer: .active)
        == t.transcript(rows: 0..<t.rowCount(of: .primary), buffer: .primary))
}

@Test func aRowOutsideABufferIsNil() {
    let t = hostInVim()
    #expect(t.row(-1, in: .primary) == nil)
    #expect(t.row(t.rowCount(of: .primary), in: .primary) == nil)
    #expect(t.row(t.rowCount(of: .alternate), in: .alternate) == nil)
}
