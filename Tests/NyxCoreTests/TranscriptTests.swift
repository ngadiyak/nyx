import Foundation
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

// MARK: - Saving it to a file
//
// The extension is the whole interface for choosing a format, so what it decides is worth pinning
// down: a save panel hands back whatever the user typed, in whatever case they typed it.

@Test func aTxtNameMeansPlainText() {
    let options = Transcript.options(forFileNamed: "build.txt")
    #expect(!options.includeAttributes)
    #expect(!options.carriageReturns)
}

@Test func anythingElseKeepsTheColours() {
    #expect(Transcript.options(forFileNamed: "build.ans").includeAttributes)
    #expect(Transcript.options(forFileNamed: "build").includeAttributes)
    #expect(Transcript.options(forFileNamed: "build.log").includeAttributes)
}

/// A save panel will happily hand back `Build.TXT`, and the user meant plain text.
@Test func theExtensionIsMatchedWithoutRegardToCase() {
    #expect(!Transcript.options(forFileNamed: "Build.TXT").includeAttributes)
}

/// A file whose name merely contains "txt" is not a text file.
@Test func onlyTheExtensionCounts() {
    #expect(Transcript.options(forFileNamed: "txt-notes.ans").includeAttributes)
}

@Test func thePanelSaysWhichFormTheNameWillProduce() {
    #expect(Transcript.formatDescription(forFileNamed: "a.txt").contains("plain text"))
    #expect(Transcript.formatDescription(forFileNamed: "a.ans").contains("ANSI"))
    // The one that keeps colours has to say how to get the other, or the choice is invisible.
    #expect(Transcript.formatDescription(forFileNamed: "a.ans").contains(".txt"))
}

// MARK: - The name offered

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int,
                  _ second: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour,
                                              minute: minute, second: second))!
}

/// `.ans`, not `.txt`: the default keeps colours, and a file full of escape sequences called
/// `.txt` is a small lie that `cat` tells on.
@Test func theOfferedNameCarriesTheTabTitleAndASortableStamp() {
    let name = Transcript.defaultFileName(title: "build", date: date(2026, 9, 4, 13, 5, 7),
                                          timeZone: TimeZone(identifier: "UTC")!)
    #expect(name == "build-2026-09-04-130507.ans")
}

@Test func anUntitledTabStillGetsAName() {
    let name = Transcript.defaultFileName(title: "", date: date(2026, 1, 2, 3, 4, 5),
                                          timeZone: TimeZone(identifier: "UTC")!)
    #expect(name == "nyx-2026-01-02-030405.ans")
}

/// A tab title is whatever the shell felt like setting: a path, a command line, a directory.
@Test func aTitleWithSlashesInItDoesNotBecomeAPath() {
    let name = Transcript.defaultFileName(title: "~/projects/nyx", date: date(2026, 1, 2, 3, 4, 5),
                                          timeZone: TimeZone(identifier: "UTC")!)
    #expect(!name.contains("/"))
    #expect(name.hasPrefix("projects-nyx-"))
}

@Test func theSlugCollapsesRunsAndTrimsTheEnds() {
    #expect(Transcript.fileNameSlug("  make   test  ") == "make-test")
    #expect(Transcript.fileNameSlug("!!!") == "")
    #expect(Transcript.fileNameSlug("a_b-c") == "a_b-c")
}

@Test func aVeryLongTitleIsCutShortOfWhatAFilesystemRefuses() {
    let slug = Transcript.fileNameSlug(String(repeating: "a", count: 300))
    #expect(slug.count == 40)
}

/// The round trip the ANSI form exists for: what is written back can be fed to the parser that is
/// already there, and comes back looking the same.
@Test func aSavedTranscriptFeedsBackIntoATerminal() {
    let original = makeTerminal(cols: 20, rows: 3)
    original.feed("\u{1b}[31mred\u{1b}[0m plain\r\nsecond\r\n")
    let text = original.transcript(options: Transcript.options(forFileNamed: "session.ans"))

    let restored = makeTerminal(cols: 20, rows: 3)
    restored.feed(text)
    #expect(restored.rowText(absoluteRow: 0).text.hasPrefix("red plain"))
    #expect(restored.absoluteRow(0)?.cells[0].fg == .indexed(1))
    // The reset after "red" has to survive too, or a saved transcript paints the rest of the line.
    #expect(restored.absoluteRow(0)?.cells[4].fg == .default)
}

@Test func aPlainTextTranscriptCarriesNoEscapes() {
    let t = makeTerminal(cols: 20, rows: 3)
    t.feed("\u{1b}[31mred\u{1b}[0m\r\n")
    let text = t.transcript(options: Transcript.options(forFileNamed: "session.txt"))
    #expect(!text.contains("\u{1b}"))
    #expect(!text.contains("\r"))
    #expect(text.contains("red"))
}

// MARK: - Prompt marks survive a relaunch

private func mark(_ letter: String, _ status: Int32? = nil) -> String {
    let payload = status.map { "\(letter);\($0)" } ?? letter
    return "\u{1b}]133;\(payload)\u{7}"
}

@Test func promptMarksRoundTripThroughTheTranscript() {
    let original = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    original.feed(mark("A") + "$ " + mark("B") + "make\r\n" + mark("C") + "ok\r\n" + mark("D", 3))
    original.feed(mark("A") + "$ ")
    let restored = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    restored.feed(original.transcript())

    #expect(restored.shellEmitsPromptMarks)
    #expect(restored.promptMarks(atAbsoluteRow: 0) == [.promptStart, .commandStart])
    #expect(restored.absoluteRow(0)?.inputStartColumn == 2)
    #expect(restored.promptMarks(atAbsoluteRow: 1).contains(.outputStart))
    let region = restored.command(containingAbsoluteRow: 0)
    #expect(region?.exitStatus == 3)
    #expect(region?.outputRows == 1..<2)
    #expect(region?.id == 1)
}

@Test func aPlainTextTranscriptCarriesNoMarks() {
    let t = makeTerminal(cols: 40, rows: 8, scrollback: 100)
    t.feed(mark("A") + "$ " + mark("B") + "ls\r\n" + mark("C") + "a\r\n" + mark("D", 0) + mark("A") + "$ ")
    #expect(!t.transcript(options: .plainText).contains("133;"))
}
