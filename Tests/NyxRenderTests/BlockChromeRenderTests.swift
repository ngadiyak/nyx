import Testing
@testable import NyxCore
@testable import NyxRender
import Metal

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

/// Primary colours, so a pixel names which rule painted it.
private func blockPalette() -> Palette {
    var colors = [RGB](repeating: RGB(0, 0, 0), count: 16)
    colors[1] = RGB(255, 0, 0)
    colors[2] = RGB(0, 255, 0)
    colors[3] = RGB(255, 255, 0)
    return Palette(ansi: colors, foreground: RGB(255, 255, 255), background: RGB(0, 0, 0),
                   cursor: RGB(0, 0, 255))
}

/// The chrome a command block draws, checked in pixels. The model has tests; these are about what
/// actually reaches the screen — which is where two of this feature's defects lived.
private func render(cols: Int = 8, rows: Int = 3, padding: Int, scale: CGFloat = 1,
                    spines: [(rows: Range<Int>, color: RGB)] = [],
                    summaries: [(row: Int, text: String, color: RGB)] = [],
                    notes: [String?] = [],
                    highlighted: Range<Int>? = nil,
                    selection: [Range<Int>?] = [],
                    lines givenLines: [Row]? = nil,
                    cursor: Cursor? = nil) throws -> (FontSet, Int, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: scale)
    let r = try Renderer(device: device, fonts: fonts)
    let lines = givenLines ?? Array(repeating: Row(cols: cols), count: rows)
    let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: blockPalette(),
                            cursor: cursor, cursorShape: .block, focused: true, preedit: nil,
                            selection: selection,
                            rowNotes: notes, blockSpines: spines, blockSummaries: summaries,
                            highlightedRows: highlighted)
    // `padding` is the *point* padding the user set; the renderer, like `Pane`, is handed it in
    // device pixels.
    let pad = Int(CGFloat(padding) * scale)
    let w = fonts.metrics.width * cols + pad * 2, h = fonts.metrics.height * rows + pad * 2
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h,
                                                        mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: pad)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (fonts, w, { x, y in
        let i = (y * w + x) * 4
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    })
}

private let spineColor = RGB(0, 255, 0)

/// The spine is 3 pt wide at `spineLeadingInset`, which is 4 pt in at the shipping padding -- off
/// the window's resize margin and exactly where the gutter's cap is drawn.
@Test func aSpineIsThreePointsWideBesideItsRows() throws {
    let (fonts, _, px) = try render(padding: 8, spines: [(rows: 0..<2, color: spineColor)])
    let y = 8 + fonts.metrics.height / 2
    #expect(px(4, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(6, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(2, y) != Pixel(r: 0, g: 255, b: 0))
    #expect(px(8, y) != Pixel(r: 0, g: 255, b: 0))
    #expect(px(4, 8 + fonts.metrics.height * 2 + fonts.metrics.height / 2) != Pixel(r: 0, g: 255, b: 0))
}

/// The spine is 3 **points** wide on a Retina display too, not 3 pixels.
///
/// `Renderer.render` is handed its padding in device pixels (`Pane` multiplies by the layer's
/// `contentsScale`), and `spineWidth`/`spineLeadingInset` are points -- the same points the AppKit
/// cap is drawn in. Using them raw made the spine 1.5 pt wide at 2 pt beside a 3 pt cap at 4 pt on
/// every Mac this ships on, which is the "line with beads on it" this whole change exists to
/// remove, wearing a different hat. Only a scale other than 1 can catch it, and every other case
/// here runs at 1.
@Test func theSpineIsThreePointsWideOnARetinaDisplay() throws {
    let (fonts, _, px) = try render(padding: 8, scale: 2, spines: [(rows: 0..<2, color: spineColor)])
    let y = 16 + fonts.metrics.height / 2
    // 4 pt in, 3 pt wide, at two pixels to the point: 8..<14.
    #expect(px(8, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(13, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(6, y) != Pixel(r: 0, g: 255, b: 0))
    #expect(px(14, y) != Pixel(r: 0, g: 255, b: 0))
}

/// `padding = 0` is a setting the settings window ships. The spine takes the first column's leading
/// 3 pt there rather than disappearing: without it a block loses its left edge entirely, which is
/// what the second snapshot pass found (Addendum 2).
@Test func atZeroPaddingTheSpineTakesTheFirstColumnsLeadingEdge() throws {
    let (fonts, _, px) = try render(padding: 0, spines: [(rows: 0..<3, color: spineColor)])
    let y = fonts.metrics.height / 2
    #expect(px(0, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(2, y) == Pixel(r: 0, g: 255, b: 0))
    #expect(px(4, y) != Pixel(r: 0, g: 255, b: 0))
}

/// The tint sits under the glyphs across the block's rows and nowhere else.
@Test func hoveredRowsAreTintedAndOthersAreNot() throws {
    let (fonts, w, px) = try render(padding: 0, highlighted: 0..<2)
    let mid = w / 2
    let tinted = px(mid, fonts.metrics.height / 2)
    let plain = px(mid, fonts.metrics.height * 2 + fonts.metrics.height / 2)
    #expect(tinted != Pixel(r: 0, g: 0, b: 0))
    #expect(plain == Pixel(r: 0, g: 0, b: 0))
}

/// A selection (or a search hit, or a coloured cell, or the block cursor) is a background instance
/// on top of the tint, not under it: it must stay visible on a hovered row, and only the cells with
/// nothing else painted on them show the tint through.
@Test func theTintNeverHidesWhatIsPaintedOnTopOfIt() throws {
    let (fonts, _, px) = try render(padding: 0, highlighted: 0..<1, selection: [0..<2])
    let y = fonts.metrics.height / 2
    let selectedX = fonts.metrics.width / 2
    let plainX = fonts.metrics.width * 4 + fonts.metrics.width / 2
    #expect(px(selectedX, y) == Pixel(r: blockPalette().selectionBackground.r,
                                      g: blockPalette().selectionBackground.g,
                                      b: blockPalette().selectionBackground.b))
    let tint = blockPalette().blockHoverBackground
    #expect(px(plainX, y) == Pixel(r: tint.r, g: tint.g, b: tint.b))
}

/// The summary is drawn to its own last cell, in its own colour. It used to end in a chevron; that
/// chevron was a control and the gutter cap is the control now, so what the renderer is handed here
/// is the sentence and nothing else (§2.4).
@Test func theSummaryIsDrawnToItsLastCell() throws {
    let (fonts, w, px) = try render(cols: 12, padding: 0,
                                    summaries: [(row: 0, text: "8.8s", color: RGB(0, 255, 0))])
    let lastCell = (w - fonts.metrics.width)..<w
    var ink = 0
    for x in lastCell { for y in 0..<fonts.metrics.height where px(x, y).g > 100 { ink += 1 } }
    #expect(ink > 4)
}

/// The caret with a fold on screen.
///
/// `Pane.render()` used to hand the renderer `screen.cursor` — a *screen* row — while every line in
/// the frame is a display slot. With a fold hiding rows above the prompt those are different
/// numbers, and the block cursor was drawn as many rows below the prompt as the fold had hidden
/// above it: nine, in the product manager's session. This builds the frame exactly the way the pane
/// does, mapping the caret's absolute row through the same display rows the lines came from.
@Test func theBlockCursorLandsOnThePromptWhenAFoldIsOnScreen() throws {
    let cols = 12, rows = 6
    let t = Terminal(cols: cols, rows: rows, scrollbackLimit: 200)
    func mark(_ letter: String, _ status: Int32? = nil) -> String {
        "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
    }
    t.feed(mark("A") + "$ " + mark("B") + "build\r\n" + mark("C"))
    for i in 1...8 { t.feed("out \(i)\r\n") }
    t.feed(mark("D", 0))
    t.feed(mark("A") + "$ ")

    var folding = OutputFolding()
    folding.fold(try #require(t.command(containingAbsoluteRow: 0)).id, .all)
    let top = t.viewportTopRow
    let display = t.displayRows(from: top, count: rows, folding: folding)
    let lines = display.map { entry -> Row in
        switch entry {
        case .row(let absolute): return t.absoluteRow(absolute) ?? Row(cols: cols)
        case .fold(_, let hidden, let status): return t.foldPlaceholderRow(hiddenRows: hidden, status: status)
        case .lens: return Row(cols: cols)      // no lens is set on this terminal
        }
    } + Array(repeating: Row(cols: cols), count: max(0, rows - display.count))

    let caretAbsolute = t.scrollback.count + t.screen.cursor.y
    let slot = try #require(DisplayRows.cursorSlot(absoluteRow: caretAbsolute, in: display))
    let promptSlot = try #require(display.firstIndex { $0 == .row(caretAbsolute) })
    #expect(slot == promptSlot)
    // The defect it replaces: the raw screen row is a different slot entirely.
    #expect(t.screen.cursor.y != slot)

    let (fonts, _, px) = try render(cols: cols, rows: rows, padding: 4,
                                    lines: lines, cursor: Cursor(x: t.screen.cursor.x, y: slot))
    let m = fonts.metrics
    let cursorCell = { (slot: Int) -> Pixel in
        px(4 + t.screen.cursor.x * m.width + m.width / 2, 4 + slot * m.height + m.height / 2)
    }
    #expect(cursorCell(slot) == Pixel(r: 0, g: 0, b: 255))            // the palette's cursor colour
    #expect(cursorCell(t.screen.cursor.y) != Pixel(r: 0, g: 0, b: 255))
}

/// A request's summary reaches the grid in the colour its status class earns.
///
/// The colour travels from `BlockHeader.tone` through `RenderFrame.blockSummaries`, which is the
/// only channel the Metal pass has for it -- a tone the pane forgot to convert would draw the same
/// grey a plain `8.8s` draws, and a 404 that reads as "fine" is the defect this whole summary
/// exists to prevent. Checked in pixels rather than in the model for exactly that reason.
@Test func aRequestSummaryIsDrawnInItsStatusColour() throws {
    let palette = blockPalette()
    func inkAt(row: Int, text: String, tone: SummaryTone) throws -> (red: Int, green: Int, yellow: Int) {
        let (fonts, w, px) = try render(cols: 20, rows: 2, padding: 0,
                                        summaries: [(row: row, text: text,
                                                     color: tone.color(in: palette))])
        var red = 0, green = 0, yellow = 0
        for x in 0..<w {
            for y in (row * fonts.metrics.height)..<((row + 1) * fonts.metrics.height) {
                let p = px(x, y)
                // The palette's 1/2/3 are pure primaries, so one channel pattern names each.
                if p.r > 100 && p.g > 100 { yellow += 1 } else if p.r > 100 { red += 1 } else if p.g > 100 { green += 1 }
            }
        }
        return (red, green, yellow)
    }

    // Palette index 3 -- amber -- for a redirect.
    let redirect = try inkAt(row: 0, text: "301 \u{b7} 31 ms \u{25BE}", tone: .redirect)
    #expect(redirect.yellow > 20)
    #expect(redirect.red == 0)
    #expect(redirect.green == 0)

    // Palette index 1 -- red -- for a failed request, even though the command itself exited 0.
    let failure = try inkAt(row: 0, text: "500 \u{b7} 1.4 s \u{25BE}", tone: .failure)
    #expect(failure.red > 20)
    #expect(failure.green == 0)
    #expect(failure.yellow == 0)

    // And index 2 for a 2xx, which is what makes the other two mean anything.
    let success = try inkAt(row: 0, text: "200 \u{b7} 142 ms \u{25BE}", tone: .success)
    #expect(success.green > 20)
    #expect(success.red == 0)
}
