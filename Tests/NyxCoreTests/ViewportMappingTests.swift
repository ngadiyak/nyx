import Testing
@testable import NyxCore

/// Whether per-row dirty flags may be trusted for the next frame.
///
/// The rule is one-sided on purpose: saying "trust them" when the mapping moved leaves a row on
/// screen showing text it is no longer filled from, and nothing catches that — not a pixel test of
/// the drawing, which is correct for the rows it draws, and not a user, who sees a terminal that is
/// occasionally, unreproducibly wrong. Saying "redraw everything" when nothing moved costs one
/// frame. So every test here asks the same question: does this way of moving the mapping stop the
/// flags being trusted?
@Suite("Trusting per-row dirty flags")
struct ViewportMappingTests {

    private func mapping(_ t: Terminal, top: Int? = nil, folded: Bool = false) -> ViewportMapping {
        ViewportMapping(of: t, top: top ?? t.viewportTopRow, folded: folded)
    }

    @Test func anUnmovedLiveViewportTrustsTheFlags() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        t.feed("one\r\n")
        let first = mapping(t)
        t.feed("two")                       // writing into a row does not move the mapping
        #expect(mapping(t).trustsDirtyFlags(after: first))
    }

    /// There is no previous frame to compare against on the very first one.
    @Test func theFirstFrameDrawsEverything() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        #expect(!mapping(t).trustsDirtyFlags(after: nil))
    }

    @Test func scrollingBackDrawsEverything() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 50)
        for i in 0..<10 { t.feed("row\(i)\r\n") }
        let live = mapping(t)
        t.scrollViewport(by: 3)
        let scrolled = mapping(t)
        #expect(!scrolled.trustsDirtyFlags(after: live))
        // ...and it keeps drawing everything while it stays scrolled back: slot y is filled from
        // the scrollback, which has no dirty flag of its own.
        #expect(!mapping(t).trustsDirtyFlags(after: scrolled))
    }

    /// New output while scrolled back moves what each slot shows without touching a screen row.
    @Test func outputArrivingWhileScrolledBackDrawsEverything() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 50)
        for i in 0..<10 { t.feed("row\(i)\r\n") }
        t.scrollViewport(by: 3)
        let before = mapping(t)
        t.feed("more\r\n")
        #expect(!mapping(t).trustsDirtyFlags(after: before))
    }

    @Test func foldingDrawsEverything() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        let plain = mapping(t)
        #expect(!mapping(t, folded: true).trustsDirtyFlags(after: plain))
        // And it goes on drawing everything while a fold is open: rows come out of the middle.
        let folded = mapping(t, folded: true)
        #expect(!mapping(t, folded: true).trustsDirtyFlags(after: folded))
    }

    /// `ED 3` renumbers every absolute row without marking a screen row dirty.
    @Test func clearingTheScrollbackDrawsEverything() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 50)
        for i in 0..<6 { t.feed("row\(i)\r\n") }
        let before = mapping(t)
        t.feed("\u{1b}[3J")
        #expect(!mapping(t).trustsDirtyFlags(after: before))
    }

    /// The ring evicting shifts every absolute row while the generation stays put -- the exact case
    /// a generation counter alone does not catch.
    @Test func theRingTrimmingDrawsEverything() {
        let t = Terminal(cols: 20, rows: 2, scrollbackLimit: 3)
        for i in 0..<4 { t.feed("row\(i)\r\n") }
        let before = mapping(t)
        #expect(t.scrollbackGeneration == before.scrollbackGeneration)
        t.feed("row4\r\nrow5\r\n")
        let after = mapping(t)
        #expect(after.scrollbackGeneration == before.scrollbackGeneration)   // no bump, by design
        #expect(after.evictedRows > before.evictedRows)
        #expect(!after.trustsDirtyFlags(after: before))
    }

    @Test func aResizeDrawsEverything() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        t.feed("hello\r\n")
        let before = mapping(t)
        t.resize(cols: 20, rows: 6)
        #expect(!mapping(t).trustsDirtyFlags(after: before))
    }

    /// Swapping to the alternate screen puts a different buffer under the same slots.
    @Test func theAlternateScreenDrawsEverything() {
        let t = Terminal(cols: 20, rows: 4, scrollbackLimit: 50)
        t.feed("hello\r\n")
        let before = mapping(t)
        t.feed("\u{1b}[?1049h")
        let alt = mapping(t)
        #expect(!alt.trustsDirtyFlags(after: before))
        t.feed("\u{1b}[?1049l")
        #expect(!mapping(t).trustsDirtyFlags(after: alt))
    }
}
