import Testing
@testable import NyxCore

/// Where a link is on screen and what it is, once wrapping and OSC 8 are taken into account.
///
/// The two defects these pin were found by driving a real pointer over a real grid; see
/// `.superpowers/sdd/2026-09-07-ux-round/qa-layout-links.md`.
private func hit(_ t: Terminal, row: Int, column: Int) -> LinkHit? {
    t.linkHit(atAbsoluteRow: row, column: column, separators: Config().wordSeparators)
}

// MARK: - A URL that wraps

/// The report's case: in a pane 52 columns wide the URL crossed the margin, hover underlined the
/// visible half, and ⌘-clicking it opened `https://example.com` -- a different page, silently.
@Test func theFirstHalfOfAWrappedURLIsTheWholeURL() {
    let t = makeTerminal(cols: 80, rows: 4, scrollback: 100)
    // 61 characters and a space, so the URL starts at column 62 and its tail wraps at 80.
    t.run(String(repeating: "w", count: 61) + " https://example.com/wrapped/tail?a=1")
    #expect(t.absoluteRow(0)?.wrapped == true)
    let h = hit(t, row: 0, column: 65)
    #expect(h?.text == "https://example.com/wrapped/tail?a=1")
    #expect(h?.kind == .url)
    // Two rows, so hover can underline both halves and a ⌘-click on either opens the same page.
    #expect(h?.spans.count == 2)
    #expect(h?.spans.first?.row == 0)
    #expect(h?.spans.first?.columns == 62..<80)
    #expect(h?.spans.last?.row == 1)
    #expect(h?.spans.last?.columns == 0..<18)
}

@Test func theContinuationRowOfAWrappedURLIsTheSameLink() {
    let t = makeTerminal(cols: 80, rows: 4, scrollback: 100)
    t.run(String(repeating: "w", count: 61) + " https://example.com/wrapped/tail?a=1")
    // Column 5 of row 1 is inside `/wrapped/tail?a=1`, which on its own tokenised as a path that
    // does not exist -- so the second half of the link was not a link at all.
    let h = hit(t, row: 1, column: 5)
    #expect(h?.text == "https://example.com/wrapped/tail?a=1")
    #expect(h?.spans.count == 2)
}

@Test func aLinkOnAnUnwrappedRowStillHasOneSpan() {
    let t = makeTerminal(cols: 80, rows: 4, scrollback: 100)
    t.run("see https://example.com/a?b=1 now")
    let h = hit(t, row: 0, column: 6)
    #expect(h?.text == "https://example.com/a?b=1")
    #expect(h?.spans == [RowSpan(row: 0, columns: 4..<29)])
}

@Test func aWrappedLineDoesNotSwallowTheRowAfterTheOneThatEndsIt() {
    let t = makeTerminal(cols: 30, rows: 5, scrollback: 100)
    t.run(String(repeating: "a", count: 35) + "\r\nhttps://second.example/\r\n")
    // Row 0 wraps into row 1; row 1 does not wrap, so row 2 is a line of its own and its URL is
    // not joined to anything.
    let h = hit(t, row: 2, column: 3)
    #expect(h?.text == "https://second.example/")
    #expect(h?.spans == [RowSpan(row: 2, columns: 0..<23)])
}

@Test func nothingIsUnderAColumnPastTheEndOfTheText() {
    let t = makeTerminal(cols: 40, rows: 3, scrollback: 100)
    t.run("hi")
    #expect(hit(t, row: 0, column: 30) == nil)
}

// MARK: - OSC 8

/// `docs/status.md` advertised OSC 8; the URI reached the model and nothing on the click path read
/// it, so `gh`, `cargo`, `eza --hyperlink` and `delta` showed a label with no way to reach the URL
/// and the URL was not on the row to select either.
@Test func anOSC8HyperlinkIsClickableThroughItsLabel() {
    let t = makeTerminal(cols: 60, rows: 3, scrollback: 100)
    t.run("osc8 \u{1B}]8;;https://example.com/osc\u{1B}\\Click here\u{1B}]8;;\u{1B}\\ done")
    #expect(t.hyperlinks.contains("https://example.com/osc"))
    let h = hit(t, row: 0, column: 8)
    #expect(h?.text == "https://example.com/osc")
    #expect(h?.kind == .url)
    // The whole run, so hover underlines the label end to end rather than a word of it.
    #expect(h?.spans == [RowSpan(row: 0, columns: 5..<15)])
}

@Test func anOSC8RunEndsWhereItsURIChanges() {
    let t = makeTerminal(cols: 60, rows: 3, scrollback: 100)
    t.run("\u{1B}]8;;https://a.example/\u{1B}\\AA\u{1B}]8;;https://b.example/\u{1B}\\BB\u{1B}]8;;\u{1B}\\")
    #expect(hit(t, row: 0, column: 0)?.text == "https://a.example/")
    #expect(hit(t, row: 0, column: 1)?.spans == [RowSpan(row: 0, columns: 0..<2)])
    #expect(hit(t, row: 0, column: 2)?.text == "https://b.example/")
    #expect(hit(t, row: 0, column: 3)?.spans == [RowSpan(row: 0, columns: 2..<4)])
}

@Test func anOSC8RunThatWrapsIsOneLink() {
    let t = makeTerminal(cols: 20, rows: 4, scrollback: 100)
    t.run("\u{1B}]8;;https://example.com/long\u{1B}\\" + String(repeating: "L", count: 30)
          + "\u{1B}]8;;\u{1B}\\")
    let h = hit(t, row: 0, column: 10)
    #expect(h?.text == "https://example.com/long")
    #expect(h?.spans == [RowSpan(row: 0, columns: 0..<20), RowSpan(row: 1, columns: 0..<10)])
}

/// The label wins over whatever the label's *text* looks like: a hyperlink whose label happens to
/// read like another URL opens the one the program named.
@Test func theOSC8URIBeatsThePatternInItsLabel() {
    let t = makeTerminal(cols: 60, rows: 3, scrollback: 100)
    t.run("\u{1B}]8;;https://real.example/page\u{1B}\\https://decoy.example/\u{1B}]8;;\u{1B}\\")
    #expect(hit(t, row: 0, column: 4)?.text == "https://real.example/page")
}

/// An OSC 8 URI in a scheme the app will not hand to the system is text, not a link -- the same
/// rule `LinkResolver` applies to a printed URL, and the reason a program cannot make Nyx open
/// anything it likes with one ⌘-click.
@Test func anUnopenableOSC8SchemeIsNotOpened() {
    let t = makeTerminal(cols: 60, rows: 3, scrollback: 100)
    t.run("\u{1B}]8;;javascript:alert(1)\u{1B}\\Click\u{1B}]8;;\u{1B}\\")
    let h = hit(t, row: 0, column: 2)
    #expect(h?.text == "javascript:alert(1)")
    let target = h.flatMap {
        LinkResolver.target(for: $0.token, home: "/Users/x", workingDirectory: { nil },
                            fileExists: { _ in false })
    }
    #expect(target == nil)
}

// MARK: - Lens rows

/// A pretty-printed JSON body is full of URLs -- `next`, `self`, `html_url` -- and none of them was
/// clickable, while the same URL *was* clickable in the raw rows before the lens was applied. The
/// feature that makes a response readable took its links away.
///
/// A lens line has no absolute row: `Pane.characterPosition` returns nil for its display slot, and
/// correctly so. Its text is its own, so the link detection is too.
private func lensBuffer(_ lines: [String]) -> LensBuffer {
    LensBuffer(commandID: 4, lens: .pretty, lines: lines.map { LensLine($0) }, contentVersion: 1)
}

@Test func aURLInALensLineIsAToken() {
    let buffer = lensBuffer(["{", "  \"next\": \"https://api.example.com/page/2\",", "}"])
    let token = buffer.token(atColumn: 15, line: 1, separators: Config().wordSeparators)
    #expect(token?.text == "https://api.example.com/page/2")
    #expect(token?.kind == .url)
    // Columns of the lens line, which is what the underline and the pointing hand are drawn in.
    #expect(token?.columns == 11..<41)
}

@Test func aLensLineWithNoLinkUnderThePointerGivesTheWord() {
    let buffer = lensBuffer(["  \"name\": \"qa\","])
    #expect(buffer.token(atColumn: 4, line: 0, separators: Config().wordSeparators)?.kind == .word)
    #expect(buffer.token(atColumn: 0, line: 0, separators: Config().wordSeparators) == nil)
}

@Test func aLensTokenIsMeasuredInCellsAndNotInCharacters() {
    // A wide glyph before the URL: the column the hand is drawn at is two cells per character.
    let buffer = lensBuffer(["\u{4E2D}\u{4E2D} https://example.com/x"])
    let token = buffer.token(atColumn: 8, line: 0, separators: Config().wordSeparators)
    #expect(token?.text == "https://example.com/x")
    #expect(token?.columns == 5..<26)
}

@Test func aLineOffTheEndOfTheLensHasNoToken() {
    let buffer = lensBuffer(["a"])
    #expect(buffer.token(atColumn: 0, line: 7, separators: []) == nil)
}

// MARK: - Saying how a link opens

/// Nothing in the app said ⌘. `grep -rn "Open Link\|⌘-click"` over `Sources/` found only code
/// comments: no context-menu item even with the pointer on a link, no tooltip, and
/// `docs/configuration.md` documented `open-file-command` without ever saying how a link is
/// clicked. The only discovery path was "hover, notice the underline, guess a modifier".
@Test func aLinkOffersOpenAndCopy() {
    #expect(LinkMenu.entries(for: .url("https://example.com/a")) == [.open, .copy])
    #expect(LinkMenu.entries(for: .file(path: "/etc/hosts", line: 12, column: 3)) == [.open, .copy])
    #expect(LinkMenu.entries(for: nil).isEmpty)
    #expect(LinkMenu.Entry.open.title == "Open Link")
    #expect(LinkMenu.Entry.copy.title == "Copy Link")
}

@Test func copyingAFileLinkCopiesThePathAndNotAURL() {
    // What a person pastes into an editor or another shell is the path -- not `file://`, and not
    // the `:12:3` a compiler printed after it.
    #expect(LinkMenu.copyText(for: .file(path: "/etc/hosts", line: 12, column: 3)) == "/etc/hosts")
    #expect(LinkMenu.copyText(for: .url("mailto:user@example.com")) == "mailto:user@example.com")
}

@Test func theHoverHintNamesTheModifier() {
    #expect(LinkMenu.hoverHint == "\u{2318}-click to open")
}

// MARK: - Where the underline goes

/// The renderer is handed one range per screen row. A wrapped link has to underline both of its
/// halves -- hover that promises on one row and not the other is hover that lies about one of them
/// -- and a lens line has to be found by the block and line it belongs to, because it has no
/// absolute row to look up.
@Test func aWrappedLinkUnderlinesEveryRowItIsOn() {
    let site = LinkSite.rows([RowSpan(row: 10, columns: 62..<80), RowSpan(row: 11, columns: 0..<18)])
    let ranges = site.visibleRanges(viewportTop: 8, rows: 5, cols: 80)
    #expect(ranges == [nil, nil, 62..<80, 0..<18, nil])
}

@Test func aLinkScrolledOffTheTopUnderlinesNothing() {
    let site = LinkSite.rows([RowSpan(row: 1, columns: 0..<5)])
    #expect(site.visibleRanges(viewportTop: 8, rows: 3, cols: 80) == [nil, nil, nil])
}

@Test func aColumnPastTheRightEdgeIsClamped() {
    let site = LinkSite.rows([RowSpan(row: 0, columns: 70..<120)])
    #expect(site.visibleRanges(viewportTop: 0, rows: 1, cols: 80) == [70..<80])
}

@Test func aWrappedLinkGoesThroughTheDisplayRowsWhenAFoldIsOnScreen() {
    let display: [DisplayRow] = [.row(10), .fold(commandID: 3, hiddenRows: 40, status: .succeeded),
                                 .row(51), .row(52)]
    let site = LinkSite.rows([RowSpan(row: 51, columns: 4..<9), RowSpan(row: 52, columns: 0..<3)])
    #expect(site.visibleRanges(displayRows: display, cols: 40) == [nil, nil, 4..<9, 0..<3])
}

@Test func aLensLinkIsFoundByItsBlockAndLine() {
    let display: [DisplayRow] = [.row(10), .lens(commandID: 4, line: 0), .lens(commandID: 4, line: 1),
                                 .lens(commandID: 5, line: 1)]
    let site = LinkSite.lens(id: 4, line: 1, columns: 11..<41)
    #expect(site.visibleRanges(displayRows: display, cols: 60) == [nil, nil, 11..<41, nil])
    // A viewport with no lens on it draws nothing: the block scrolled away, and the underline goes
    // with it rather than onto whatever took the slot.
    #expect(LinkSite.lens(id: 9, line: 1, columns: 0..<4)
        .visibleRanges(displayRows: display, cols: 60) == [nil, nil, nil, nil])
    #expect(site.visibleRanges(viewportTop: 0, rows: 2, cols: 60) == [nil, nil])
}
