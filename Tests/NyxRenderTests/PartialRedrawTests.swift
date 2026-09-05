import Testing
import Foundation
import Metal
import NyxCore
@testable import NyxRender

// Per-row partial redraw. The rule is not "the cache works" -- a cache that is never used also
// draws the right picture, and a cache that is wrong draws the wrong one. Two rules together pin
// it down:
//
//   1. the picture is always the picture a renderer that rebuilt everything would have drawn, and
//   2. the work done is proportional to what changed, not to what is on screen.
//
// The first is checked against real pixels through real Metal, driven by a real `Terminal` so the
// dirty flags come from the code that maintains them rather than from the test's idea of them.

private func makeFonts() -> FontSet { FontSet(family: "Menlo", pointSize: 12, scale: 1) }

private func makeTexture(_ device: MTLDevice, cols: Int, rows: Int, fonts: FontSet) throws -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                        width: fonts.metrics.width * cols,
                                                        height: fonts.metrics.height * rows,
                                                        mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    return try #require(device.makeTexture(descriptor: desc))
}

private func pixels(_ r: Renderer, _ frame: RenderFrame, to tex: MTLTexture) throws -> [UInt8] {
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: 0)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
    tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
    return bytes
}

/// The first pixel where two renderings differ, as (x, y). Reported instead of the buffers
/// themselves: a failed comparison of two million bytes is unreadable, and the coordinate is what
/// says which row went wrong.
private func firstDifference(_ a: [UInt8], _ b: [UInt8], width: Int) -> (x: Int, y: Int)? {
    guard a.count == b.count else { return (x: -1, y: -1) }
    for i in 0..<a.count where a[i] != b[i] {
        let pixel = i / 4
        return (x: pixel % width, y: pixel / width)
    }
    return nil
}

/// A frame over the terminal's viewport, carrying the dirty flags exactly as the view does.
private func frame(of t: Terminal, cursor: Cursor? = nil, selection: [Range<Int>?] = [],
                   trackDirty: Bool = true) -> RenderFrame {
    RenderFrame(cols: t.cols, rows: t.rows, lines: (0..<t.rows).map { t.viewportRow($0) },
                graphemes: t.graphemes, palette: t.palette, cursor: cursor ?? t.screen.cursor,
                cursorShape: t.cursorShape, focused: true, preedit: nil, selection: selection,
                dirtyRows: trackDirty ? (0..<t.rows).map { t.screen.rows[$0].dirty } : [])
}

@Test func partialRedrawIsIndistinguishableFromFullRedraw() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let cols = 24, rows = 8
    // Two renderers over identical frames: one told what changed, one told nothing and so obliged
    // to rebuild every row of every frame. Their pixels must never differ.
    let partial = try Renderer(device: device, fonts: fonts)
    let full = try Renderer(device: device, fonts: fonts)
    let a = try makeTexture(device, cols: cols, rows: rows, fonts: fonts)
    let b = try makeTexture(device, cols: cols, rows: rows, fonts: fonts)

    let t = Terminal(cols: cols, rows: rows, scrollbackLimit: 200)
    var selection: [Range<Int>?] = []
    var cursor: Cursor?

    // A session's worth of the things that change a row: typing, a cursor that moves without
    // touching a cell, colour runs, scrolling, an erase, a selection dragged over text, glyphs the
    // atlas has never seen, and a full-screen program taking over.
    let steps: [(name: String, act: () -> Void)] = [
        ("prompt", { t.feed("~/src $ ") }),
        ("typing", { t.feed("git status") }),
        ("newline", { t.feed("\r\n") }),
        ("colours", { t.feed("\u{1B}[32mmodified:\u{1B}[0m Renderer.swift\r\n") }),
        ("cursor moves alone", { cursor = Cursor(x: 3, y: 1) }),
        ("cursor moves back", { cursor = nil }),
        ("selection appears", { selection = Array(repeating: nil, count: rows); selection[1] = 2..<9 }),
        ("selection grows", { selection[1] = 0..<20 }),
        ("selection gone", { selection = [] }),
        ("wide glyphs", { t.feed("漢字 テスト ünïcode\r\n") }),
        ("emoji", { t.feed("build 🎉 done\r\n") }),
        ("underline and bold", { t.feed("\u{1B}[1;4mbold underlined\u{1B}[0m\r\n") }),
        ("erase to end of line", { t.feed("\u{1B}[2;5H\u{1B}[K") }),
        ("scrolling past the bottom", { for i in 0..<12 { t.feed("line \(i)\r\n") } }),
        ("cursor addressing", { t.feed("\u{1B}[3;10Hx") }),
        ("alternate screen", { t.feed("\u{1B}[?1049h\u{1B}[2Jhtop-ish\r\n") }),
        ("back to primary", { t.feed("\u{1B}[?1049l") }),
        ("reverse video row", { t.feed("\u{1B}[7mselected line\u{1B}[0m\r\n") }),
        ("clear", { t.feed("\u{1B}[2J\u{1B}[H") }),
    ]

    for step in steps {
        step.act()
        let tracked = frame(of: t, cursor: cursor, selection: selection)
        var untracked = tracked
        untracked.dirtyRows = []
        let partialPixels = try pixels(partial, tracked, to: a)
        let fullPixels = try pixels(full, untracked, to: b)
        #expect(firstDifference(partialPixels, fullPixels, width: a.width) == nil,
                "\(step.name) drew something a full redraw would not have")
        // The frame reached the screen, so the flags go out -- the same order the view uses.
        t.clearDirty()
    }

    // ...and the whole point: it got there by doing less work.
    #expect(partial.stats.rowsRebuilt < full.stats.rowsRebuilt)
}

@Test func onlyTheRowsThatChangedAreReshaped() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let r = try Renderer(device: device, fonts: fonts)
    let tex = try makeTexture(device, cols: 20, rows: 6, fonts: fonts)
    let t = Terminal(cols: 20, rows: 6, scrollbackLimit: 100)
    for i in 0..<6 { t.feed("\u{1B}[\(i + 1);1Hrow \(i)") }
    t.feed("\u{1B}[4;8H")   // where the cursor sits when the user is typing there
    _ = try pixels(r, frame(of: t), to: tex)
    t.clearDirty()

    // One character lands on one row -- a spinner ticking, a character typed at a prompt. This is
    // the case the whole feature exists for: 59 rows out of 60 must cost nothing.
    r.resetStats()
    t.feed("x")
    _ = try pixels(r, frame(of: t), to: tex)
    #expect(r.stats.rowsSeen == 6)
    #expect(r.stats.rowsRebuilt == 1)

    // A frame with no information about what changed still has to be drawn in full: that is what
    // every caller that tracks nothing -- and the view, whenever the viewport moves -- relies on.
    r.resetStats()
    t.clearDirty()
    var blind = frame(of: t)
    blind.dirtyRows = []
    _ = try pixels(r, blind, to: tex)
    #expect(r.stats.rowsRebuilt == 6)
}

@Test func aCursorThatMovesRepaintsTheRowItLeft() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let partial = try Renderer(device: device, fonts: fonts)
    let full = try Renderer(device: device, fonts: fonts)
    let a = try makeTexture(device, cols: 12, rows: 4, fonts: fonts)
    let b = try makeTexture(device, cols: 12, rows: 4, fonts: fonts)
    let t = Terminal(cols: 12, rows: 4, scrollbackLimit: 10)
    t.feed("abc\r\ndef\r\nghi\r\n")
    _ = try pixels(partial, frame(of: t, cursor: Cursor(x: 0, y: 0)), to: a)
    t.clearDirty()

    // Moving the cursor mutates no cell, so no dirty flag will ever mention it. A cache that
    // believed only the flags would leave the block cursor painted on the row the cursor left.
    partial.resetStats()
    let moved = frame(of: t, cursor: Cursor(x: 1, y: 2))
    #expect(moved.dirtyRows.allSatisfy { !$0 })
    var blind = moved
    blind.dirtyRows = []
    let withCache = try pixels(partial, moved, to: a)
    let rebuiltFromScratch = try pixels(full, blind, to: b)
    #expect(firstDifference(withCache, rebuiltFromScratch, width: a.width) == nil)
    #expect(partial.stats.rowsRebuilt == 2)
}

@Test func aThemeChangeRepaintsEveryRow() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let partial = try Renderer(device: device, fonts: fonts)
    let full = try Renderer(device: device, fonts: fonts)
    let a = try makeTexture(device, cols: 12, rows: 4, fonts: fonts)
    let b = try makeTexture(device, cols: 12, rows: 4, fonts: fonts)
    let t = Terminal(cols: 12, rows: 4, scrollbackLimit: 10)
    t.feed("\u{1B}[31mred\u{1B}[0m text\r\n")
    _ = try pixels(partial, frame(of: t), to: a)
    t.clearDirty()

    // A live config reload swaps the palette under rows that nothing has written to. Every colour
    // on screen is derived from it, and no row is dirty.
    var themed = frame(of: t)
    themed.palette = Palette(ansi: Palette.xtermAnsi16, foreground: RGB(0, 0, 0),
                             background: RGB(255, 255, 255), cursor: RGB(255, 0, 0))
    #expect(themed.dirtyRows.allSatisfy { !$0 })
    var blind = themed
    blind.dirtyRows = []
    let withCache = try pixels(partial, themed, to: a)
    let rebuiltFromScratch = try pixels(full, blind, to: b)
    #expect(firstDifference(withCache, rebuiltFromScratch, width: a.width) == nil)
}

/// What the per-row cache is actually worth, in milliseconds of main thread, on the two workloads
/// that matter: a mostly still screen (a prompt, a spinner, a progress line) and a screen being
/// scrolled by bulk output. Opt-in, because a timing assertion on a shared machine is a flake:
///
///     NYX_RENDER_BENCH=1 swift test -c release --filter renderCostPerFrame
///
/// The counters it also prints are the part that holds without a stopwatch.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_RENDER_BENCH"] != nil))
func renderCostPerFrame() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let cols = 200, rows = 50, frames = 300
    let tex = try makeTexture(device, cols: cols, rows: rows, fonts: fonts)

    func measure(_ name: String, tracked: Bool, change: (Terminal, Int) -> Void) throws {
        let r = try Renderer(device: device, fonts: fonts)
        let t = Terminal(cols: cols, rows: rows, scrollbackLimit: 2_000)
        for i in 0..<rows { t.feed("\u{1B}[32m\(i)\u{1B}[0m ~/src/nyx/Sources/NyxRender/Renderer.swift:\(i):7 rebuilt instances\r\n") }
        // Warm the atlas and the caches: the first frame of a session is not the frame we are
        // asking about.
        _ = try pixels(r, frame(of: t, trackDirty: tracked), to: tex)
        t.clearDirty()
        r.resetStats()
        let start = DispatchTime.now()
        for i in 0..<frames {
            change(t, i)
            let f = frame(of: t, trackDirty: tracked)
            let cb = try #require(r.queue.makeCommandBuffer())
            r.render(f, to: tex, commandBuffer: cb, padding: 0)
            cb.commit()
            t.clearDirty()
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        let s = r.stats
        let line = String(format: "%@: %.3f ms/frame, %d/%d rows rebuilt\n", name,
                          ms / Double(frames), s.rowsRebuilt, s.rowsSeen)
        FileHandle.standardError.write(Data(line.utf8))
    }

    // A spinner on one row: what a terminal does while a build runs, and where a full rebuild is
    // pure waste.
    let spinner = Array("|/-\\")
    try measure("spinner, per-row", tracked: true) { t, i in
        t.feed("\u{1B}[\(rows);1H\(spinner[i % 4])")
    }
    try measure("spinner, full rebuild", tracked: false) { t, i in
        t.feed("\u{1B}[\(rows);1H\(spinner[i % 4])")
    }
    // Bulk output: every row changes every frame, so this is where per-row redraw must cost nothing
    // rather than gain anything.
    try measure("bulk output, per-row", tracked: true) { t, i in
        for j in 0..<10 { t.feed("cat line \(i * 10 + j) of some long file with a path Sources/NyxRender/Renderer.swift\r\n") }
    }
    try measure("bulk output, full rebuild", tracked: false) { t, i in
        for j in 0..<10 { t.feed("cat line \(i * 10 + j) of some long file with a path Sources/NyxRender/Renderer.swift\r\n") }
    }
}

@Test func flagsSurviveAFrameThatNeverReachedTheScreen() {
    // The other half of the same promise, and the reason the view clears the flags after the frame
    // rather than before it: a frame can be dropped (no drawable) or withheld (synchronised
    // output), and the renderer skips exactly the rows the flags do not name.
    let t = Terminal(cols: 10, rows: 3, scrollbackLimit: 0)
    t.feed("hello")
    let version = t.contentVersion
    // The PTY reader got in between building the frame and presenting it: those writes were not in
    // the frame, so their flags must stand.
    t.feed("world")
    let clearedAfterAWrite = t.clearDirty(ifContentVersionIs: version)
    #expect(!clearedAfterAWrite)
    #expect(t.screen.rows[0].dirty)

    let cleared = t.clearDirty(ifContentVersionIs: t.contentVersion)
    #expect(cleared)
    #expect(!t.screen.rows[0].dirty)
}
