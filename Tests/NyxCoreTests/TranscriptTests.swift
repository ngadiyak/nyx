import Testing
@testable import NyxCore

/// The property that matters: writing a buffer out and reading it back must give the same buffer.
/// Everything else here is a specific way that can fail.
private func roundTrips(_ input: String, cols: Int = 40, rows: Int = 8,
                        sourceLine: Int = #line) -> Bool {
    let original = makeTerminal(cols: cols, rows: rows, scrollback: 100)
    original.feed(input)

    let restored = makeTerminal(cols: cols, rows: rows, scrollback: 100)
    restored.feed(original.transcript())

    for row in 0..<min(original.totalRows, restored.totalRows) {
        guard let a = original.absoluteRow(row), let b = restored.absoluteRow(row) else { continue }
        for column in 0..<min(a.cells.count, b.cells.count) {
            let (x, y) = (a.cells[column], b.cells[column])
            // Blank cells may differ in how emptiness is spelled -- content 0 versus a space --
            // which is not a difference anyone can see.
            let bothBlank = (x.content == 0 || x.scalar == " ") && (y.content == 0 || y.scalar == " ")
            if !bothBlank && x.content != y.content { return false }
            if x.fg != y.fg || x.bg != y.bg { return false }
            let visible: CellAttrs = [.bold, .dim, .italic, .inverse, .strike, .blink, .hidden]
            if x.attrs.intersection(visible) != y.attrs.intersection(visible) { return false }
            if x.underline != y.underline { return false }
        }
    }
    return true
}

// MARK: - Round trips

@Test func plainTextRoundTrips() {
    #expect(roundTrips("hello world\r\nsecond line\r\n"))
}

@Test func colouredTextRoundTrips() {
    #expect(roundTrips("\u{1b}[31mred\u{1b}[32mgreen\u{1b}[0mplain\r\n"))
}

@Test func brightAndIndexedColoursRoundTrip() {
    #expect(roundTrips("\u{1b}[91mbright\u{1b}[38;5;204mindexed\u{1b}[0m\r\n"))
}

@Test func trueColourRoundTrips() {
    #expect(roundTrips("\u{1b}[38;2;10;200;30mtrue colour\u{1b}[0m\r\n"))
}

@Test func backgroundsRoundTrip() {
    #expect(roundTrips("\u{1b}[41mred bg\u{1b}[48;5;27m blue bg \u{1b}[0m\r\n"))
}

@Test func attributesRoundTrip() {
    #expect(roundTrips("\u{1b}[1mbold\u{1b}[3m italic\u{1b}[9m struck\u{1b}[0m\r\n"))
}

/// Turning an attribute off has no single code, so the writer emits a reset and re-applies what
/// survives. Getting that wrong leaves the rest of the line bold.
@Test func turningAnAttributeOffRoundTrips() {
    #expect(roundTrips("\u{1b}[1;31mbold red\u{1b}[22m not bold still red\u{1b}[0m\r\n"))
}

@Test func underlineStylesRoundTrip() {
    #expect(roundTrips("\u{1b}[4:3mcurly\u{1b}[4:1m single\u{1b}[0m\r\n"))
}

@Test func wideGlyphsRoundTrip() {
    #expect(roundTrips("日本語 text\r\nmore 中文\r\n"))
}

@Test func emojiAndCombiningMarksRoundTrip() {
    #expect(roundTrips("hi 👩‍💻 and e\u{301}\r\n"))
}

@Test func scrollbackRoundTrips() {
    #expect(roundTrips((1...30).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n",
                       cols: 20, rows: 5))
}

// MARK: - Shape of the output

/// A background left set at the end of a line would paint every line after it when the transcript
/// is catted or fed back.
@Test func attributesAreClosedAtTheEndOfEachLine() {
    let t = makeTerminal(cols: 20, rows: 4).run("\u{1b}[41mred")
    let text = t.transcript(rows: 0..<1)
    #expect(text.hasSuffix("\u{1b}[0m\r\n"))
}

/// A wrapped command is one logical line. Writing a newline at the wrap point would turn it into
/// two lines that no longer reflow when the window is resized.
@Test func aSoftWrappedLineIsNotBrokenInTwo() {
    let t = makeTerminal(cols: 10, rows: 4)
    t.feed("abcdefghijklmno")          // wraps after ten columns
    let text = t.transcript(rows: 0..<2)
    #expect(text.contains("abcdefghijklmno"))
    #expect(!text.contains("abcdefghij\r\nklmno"))
}

@Test func trailingBlanksAreTrimmed() {
    let t = makeTerminal(cols: 40, rows: 4).run("short")
    #expect(t.transcript(rows: 0..<1) == "short\r\n")
}

/// The plain-text form is for a file someone is going to read, so it carries no escape sequences
/// at all -- not even the ones that would be harmless.
@Test func thePlainTextFormHasNoEscapeSequences() {
    let t = makeTerminal(cols: 30, rows: 4).run("\u{1b}[1;31mred bold\u{1b}[0m and plain")
    let text = t.transcript(options: .plainText)
    #expect(!text.contains("\u{1b}"))
    #expect(text.contains("red bold and plain"))
}

@Test func anEmptyBufferProducesAnEmptyishTranscript() {
    let t = makeTerminal(cols: 20, rows: 3)
    #expect(t.transcript().allSatisfy { $0 == "\r\n" })
}

@Test func askingForRowsPastTheEndIsSafe() {
    let t = makeTerminal(cols: 20, rows: 3).run("hi")
    #expect(!t.transcript(rows: 0..<9999).isEmpty)
    #expect(t.transcript(rows: 500..<600).isEmpty)
}

// MARK: - Cost

/// Ordinary text must not pay for attributes it does not use: this runs on every quit over a
/// scrollback that may be ten thousand lines.
@Test func unstyledTextCostsNothingBeyondItsCharacters() {
    let t = makeTerminal(cols: 40, rows: 4).run("just some ordinary text")
    #expect(t.transcript(rows: 0..<1) == "just some ordinary text\r\n")
}

/// A bare newline moves down without returning to column zero, so a transcript ending its lines
/// with one comes back as a staircase. This is the difference between a restored scrollback and
/// an unreadable one.
@Test func linesEndWithCarriageReturnsWhenTheyWillBeFedBack() {
    let t = makeTerminal(cols: 20, rows: 4).run("one\r\ntwo")
    #expect(t.transcript(rows: 0..<2).contains("\r\n"))
    #expect(!t.transcript(options: .plainText).contains("\r"))
}
