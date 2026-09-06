import Testing
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NyxCore
@testable import NyxRender

/// What a lensed response actually looks like, through the real renderer.
///
/// The lens lines are built exactly as the pane builds them -- `LensRendering.lines` into
/// `LensBuffer.row` into the frame's `lines` -- so these pictures fail the same way the pane would:
/// a colour that reads as body text, a fold placeholder that says nothing, a line that runs past
/// the edge. Both built-in palettes, because a lens is the first thing in Nyx to use six theme
/// colours at once.
///
/// Opt-in, like the other snapshots: `NYX_SNAPSHOT=1 swift test --filter LensSnapshot`.
private let lensOutDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("build/snapshots").path

private func lensPNG(_ bytes: [UInt8], width: Int, height: Int, to path: String) {
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                            | CGImageAlphaInfo.noneSkipFirst.rawValue)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// A response with the shapes a reader actually meets: nested objects, an array of them, a null, a
/// number that must keep its spelling, and enough headers to be worth folding.
///
/// `results` is forty numbers so that folding it produces the placeholder the design is specified
/// against -- `▸ […] 40 items` -- next to the object placeholder `▸ {…} 6 keys`. A fixture whose
/// every container held two things would have shown neither plural nor the width the count takes.
private func fixtureExchange(version: String = "1.4.2", total: Double = 0.142) -> HTTPExchange {
    let users = 3
    var body = "{\"page\":1,\"total\":\(users),\"next\":null,\"version\":\"\(version)\","
    body += "\"results\":[" + (1...40).map(String.init).joined(separator: ",") + "],"
    body += "\"users\":["
    body += (0..<users).map { index in
        "{\"id\":\(index + 1),\"name\":\"user-\(index + 1)\",\"active\":\(index % 2 == 0),"
            + "\"score\":1.50,\"tags\":[\"alpha\",\"beta\"],"
            + "\"address\":{\"city\":\"Amsterdam\",\"postcode\":\"1015 CJ\"}}"
    }.joined(separator: ",")
    body += "]}"
    let head = HTTPExchange.Head(version: "2", status: 200, reason: "", headers: [
        .init(name: "content-type", value: "application/json; charset=utf-8"),
        .init(name: "date", value: "Sun, 06 Sep 2026 12:34:56 GMT"),
        .init(name: "server", value: "nginx"),
        .init(name: "x-request-id", value: "9f2a4b6c-8d1e-4c3a-9f2a-4b6c8d1e4c3a"),
        .init(name: "cache-control", value: "no-store"),
    ])
    // One hop, so the `.headers` picture shows the `↪` line rather than only the final head: the
    // dim style beside the header style is the pair that has to stay legible in both appearances.
    let redirect = HTTPExchange.Head(version: "1.1", status: 301, reason: "Moved Permanently",
                                     headers: [.init(name: "Location",
                                                     value: "https://api.example.com/v1/users")])
    let timing = HTTPExchange.Timing(status: 200, total: total, nameLookup: 0.003, connect: 0.015,
                                     appConnect: 0.055, startTransfer: total - 0.022,
                                     sizeDownload: body.utf8.count, numRedirects: 1,
                                     contentType: "application/json")
    return HTTPExchange(redirects: [redirect], final: head, bodyLines: [body], bodyKind: .json,
                        timing: timing)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_SNAPSHOT"] != nil))
func lensesRenderInBothThemes() throws {
    try FileManager.default.createDirectory(atPath: lensOutDir, withIntermediateDirectories: true)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 13, scale: 2)
    let renderer = try Renderer(device: device, fonts: fonts)
    // Tall enough that the pretty lens fits between the command row and its latency line: a
    // picture cut off above the folds and the timings is a picture of the part nobody asked about.
    let cols = 76, rows = 29, pad = 16
    let width = fonts.metrics.width * cols + pad * 2
    let height = fonts.metrics.height * rows + pad * 2
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                              width: width, height: height,
                                                              mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .managed
    let texture = try #require(device.makeTexture(descriptor: descriptor))

    let exchange = fixtureExchange()
    let previous = fixtureExchange(version: "1.4.1", total: 0.310)
    let themes: [(String, Palette)] = [("dark", try #require(Themes.builtin["nyx-dark"])),
                                       ("light", try #require(Themes.builtin["nyx-light"]))]
    // Headers folded as the pane seeds them, `results` folded to an array placeholder, and two of
    // the three users folded to object placeholders: one picture with every fold shape in it.
    let prettyFolds: Set<NodePath> = [ResponseLens.headersNode, NodePath([.key("results")]),
                                      NodePath([.key("users"), .index(1)]),
                                      NodePath([.key("users"), .index(2)])]
    let cases: [(String, ResponseLens, LensInput)] = [
        ("pretty", .pretty, LensInput(exchange: exchange, previous: nil, folded: prettyFolds)),
        ("headers", .headers, LensInput(exchange: exchange)),
        ("filter", .filter(".users[] | .name"), LensInput(exchange: exchange)),
        ("grep", .grep("alpha"), LensInput(exchange: exchange,
                                           folded: [ResponseLens.headersNode])),
        ("diff", .diff(previousCommandID: 1), LensInput(exchange: exchange, previous: previous)),
    ]

    for (themeName, palette) in themes {
        for (name, lens, input) in cases {
            let lines = try #require(LensRendering.lines(for: lens, input: input))
            let buffer = LensBuffer(commandID: 2, lens: lens, lines: lines, contentVersion: 0)
            // The command row above the response, so the picture is a block rather than a slab of
            // text -- exactly what the pane draws.
            var command = Row(cols: cols)
            for (column, scalar) in "$ curl -sSi https://api.example.com/v1/users".unicodeScalars
                .enumerated() where column < cols {
                command.cells[column].content = scalar.value
            }
            var frame = [command]
            // The theme's lens palette, not `.standard`: `dim` is resolved against this
            // background, and `.standard`'s raw `.indexed(8)` measured 1.91:1 in nyx-dark.
            let lensPalette = LensPalette.forTheme(palette)
            frame += (0..<(rows - 1)).map { buffer.row($0, cols: cols, palette: lensPalette) }
            let render = RenderFrame(cols: cols, rows: rows, lines: frame, graphemes: [],
                                     palette: palette, cursor: nil, cursorShape: .block,
                                     focused: true, preedit: nil)
            let buffer2 = renderer.queue.makeCommandBuffer()!
            renderer.render(render, to: texture, commandBuffer: buffer2, padding: pad)
            let blit = buffer2.makeBlitCommandEncoder()!
            blit.synchronize(resource: texture)
            blit.endEncoding()
            buffer2.commit()
            buffer2.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&bytes, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            lensPNG(bytes, width: width, height: height,
                    to: lensOutDir + "/block-lens-\(name)-\(themeName).png")
        }
    }

    // Non-visual: the pretty lens really did fold what it was told to, and the placeholder says how
    // much is behind it. A picture nobody looks at proves nothing; this fails on its own.
    let pretty = try #require(LensRendering.lines(for: .pretty, input: cases[0].2))
    #expect(pretty.first?.text.hasPrefix("\u{25B8} 5 headers") == true)
    #expect(pretty.contains { $0.text.contains("\u{25B8} {…} 6 keys") })
    #expect(pretty.contains { $0.text.contains("\u{25B8} […] 40 items") })
    #expect(pretty.last?.text.hasPrefix("142 ms") == true)
    // The picture is only worth looking at if all of it is in the picture.
    #expect(pretty.count < rows)
}

// MARK: - The display path, drawn

/// The same renderer, fed by `Terminal.displayRows` instead of by hand.
///
/// `lensesRenderInBothThemes` builds its frame from one synthesised command row and a `LensBuffer`,
/// so it pictures the *lens* and nothing around it: no scrollback, no wrapped rows, no wide cells,
/// no fold, no viewport that can be in the wrong place. Every defect the display cursor can produce
/// -- two rows in one slot, a lens line drawn over a raw row, a wide cell's spacer as a glyph, the
/// caret on a lens line -- is invisible to it, because none of that code runs.
///
/// This walks the real path: a `Terminal` with thousands of rows in it, wrapped lines, CJK and
/// emoji, a lens taller than the window, and eight viewport positions from the top of the buffer to
/// the display bottom -- the same call `Pane.render` makes, into the same `RenderFrame`.
private struct LensGrid {
    let device: MTLDevice
    let fonts: FontSet
    let renderer: Renderer
    let texture: MTLTexture
    let cols: Int, rows: Int, pad: Int
    let width: Int, height: Int

    init(cols: Int, rows: Int) throws {
        device = try #require(MTLCreateSystemDefaultDevice())
        fonts = FontSet(family: "Menlo", pointSize: 13, scale: 2)
        renderer = try Renderer(device: device, fonts: fonts)
        self.cols = cols; self.rows = rows; pad = 12
        width = fonts.metrics.width * cols + pad * 2
        height = fonts.metrics.height * rows + pad * 2
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        texture = try #require(device.makeTexture(descriptor: descriptor))
    }

    /// Exactly what `Pane.render` does with a display: rows from the buffer, folds as placeholders,
    /// lens lines from the buffer, and the caret through `DisplayRows.cursorSlot`.
    func draw(_ terminal: Terminal, from cursor: DisplayCursor, folding: OutputFolding,
              lenses: LensChoices, buffers: [UInt32: LensBuffer], palette: Palette,
              named name: String) {
        let display = terminal.displayRows(from: cursor, count: rows, folding: folding,
                                           lenses: lenses, buffers: { buffers[$0] })
        let lensPalette = LensPalette.forTheme(palette)
        // The dim comes from the palette this frame is *rendered* in, exactly as `Pane.render`
        // passes it: an indexed colour is resolved by the renderer against `RenderFrame.palette`,
        // but a resolved one is baked into the cell here, so a fixture terminal built without a
        // theme would otherwise put xterm's bright black on a nyx-dark ground.
        let placeholderDim = LensPalette.dimColour(in: palette)
        var lines = display.map { row -> Row in
            switch row {
            case .row(let absolute): return terminal.absoluteRow(absolute) ?? Row(cols: cols)
            case .fold(_, let hidden, let status):
                return terminal.foldPlaceholderRow(hiddenRows: hidden, status: status,
                                                   dim: placeholderDim)
            case .lens(let id, let index):
                return buffers[id]?.row(index, cols: cols, palette: lensPalette) ?? Row(cols: cols)
            }
        }
        lines += Array(repeating: Row(cols: cols), count: max(0, rows - lines.count))
        let caret = terminal.scrollback.count + terminal.screen.cursor.y
        let cursorSlot = DisplayRows.cursorSlot(absoluteRow: caret, in: display)
            .map { Cursor(x: terminal.screen.cursor.x, y: $0) }
        let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: terminal.graphemes,
                                palette: palette, cursor: cursorSlot, cursorShape: .block,
                                focused: true, preedit: nil)
        let commands = renderer.queue.makeCommandBuffer()!
        renderer.render(frame, to: texture, commandBuffer: commands, padding: pad)
        let blit = commands.makeBlitCommandEncoder()!
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        lensPNG(bytes, width: width, height: height, to: lensOutDir + "/\(name).png")
    }
}

private func displayMark(_ letter: String, _ status: Int32? = nil) -> String {
    "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
}

/// The pane a reader actually has: a long build above, a `curl` with a lens on it, and a prompt
/// below. Wrapped lines and wide glyphs are in the big block on purpose -- a display walk that
/// mishandles either shows it as a doubled row or a spacer drawn as a glyph.
private func displayFixture(cols: Int, rows: Int, bigRows: Int)
    -> (terminal: Terminal, curlID: UInt32, bigID: UInt32) {
    let t = Terminal(cols: cols, rows: rows, scrollbackLimit: 8_000)
    t.feed(displayMark("A") + "$ " + displayMark("B") + "echo hello\r\n" + displayMark("C"))
    t.feed("hello\r\n" + displayMark("D", 0))
    t.feed(displayMark("A") + "$ " + displayMark("B") + "cat build.log\r\n" + displayMark("C"))
    for i in 1...bigRows {
        switch i % 4 {
        case 0:
            // Longer than the pane: the terminal wraps it, and the two rows are one logical line.
            t.feed("line \(i): a message long enough that the terminal has to wrap it onto a "
                   + "second row of the grid, which is the case a display walk gets wrong\r\n")
        case 1: t.feed("line \(i): 日本語のテキストと絵文字 \u{1F680}\u{1F525} wide cells\r\n")
        default: t.feed("line \(i): ordinary output\r\n")
        }
    }
    t.feed(displayMark("D", 0))
    t.feed(displayMark("A") + "$ " + displayMark("B") + "curl -sSi https://api.example.com/v1/users\r\n"
           + displayMark("C"))
    t.feed("HTTP/2 200\r\n{\"page\":1,\"users\":[…]}\r\n" + displayMark("D", 0))
    t.feed(displayMark("A") + "$ " + displayMark("B") + "echo done\r\n" + displayMark("C"))
    t.feed("done\r\n" + displayMark("D", 0))
    t.feed(displayMark("A") + "$ ")
    let curl = t.command(containingAbsoluteRow: t.totalRows - 1)
        .flatMap { t.previousCommand(of: $0) }
        .flatMap { t.previousCommand(of: $0) }
    let big = curl.flatMap { t.previousCommand(of: $0) }
    return (t, curl?.id ?? 0, big?.id ?? 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_SNAPSHOT"] != nil))
func theDisplayPathRendersFromEveryViewportPosition() throws {
    try FileManager.default.createDirectory(atPath: lensOutDir, withIntermediateDirectories: true)
    let cols = 74, rows = 18
    let grid = try LensGrid(cols: cols, rows: rows)
    let (t, curlID, bigID) = displayFixture(cols: cols, rows: rows, bigRows: 1_200)
    #expect(curlID != 0)
    #expect(bigID != 0)
    let curl = try #require(t.promptRow(ofCommand: curlID).flatMap { t.command(containingAbsoluteRow: $0) })
    let lensStart = try #require(curl.outputStart)

    // Sixty lines standing in for two rows: a lens taller than the window, which is the shape that
    // made viewport arithmetic in absolute rows unworkable in the first place.
    var lenses = LensChoices()
    lenses.set(.pretty, for: curlID)
    let lines = (0..<60).map { index -> LensLine in
        LensLine(index == 0 ? "\u{25B8} 5 headers \u{b7} content-type: application/json"
                            : "  \"key\(index)\": \"日本語 value \(index)\",")
    }
    let buffers = [curlID: LensBuffer(commandID: curlID, lens: .pretty, lines: lines,
                                      contentVersion: t.contentVersion)]
    let themes: [(String, Palette)] = [("dark", try #require(Themes.builtin["nyx-dark"])),
                                       ("light", try #require(Themes.builtin["nyx-light"]))]
    let empty = OutputFolding()

    let positions: [(String, DisplayCursor)] = [
        ("top", DisplayCursor(row: 0)),
        ("in-big-output", DisplayCursor(row: lensStart - 600)),
        ("before-lens", DisplayCursor(row: lensStart - 1)),
        ("lens-start", DisplayCursor(row: lensStart)),
        ("lens-middle", DisplayCursor(row: lensStart, line: 30)),
        ("lens-end", DisplayCursor(row: lensStart, line: lines.count - 1)),
        ("after-lens", DisplayCursor(row: curl.endRow + 1)),
        ("display-bottom", t.displayBottomCursor(folding: empty, lenses: lenses,
                                                 viewportRows: rows, buffers: { buffers[$0] })),
    ]
    for (themeName, palette) in themes {
        for (name, cursor) in positions {
            grid.draw(t, from: cursor, folding: empty, lenses: lenses, buffers: buffers,
                      palette: palette, named: "display-\(name)-\(themeName)")
        }
    }

    // Non-visual, so the pictures are not the only thing holding this up: every position produces
    // exactly one display line per slot, and none of them puts two absolute rows in one frame.
    for (label, cursor) in positions {
        let display = t.displayRows(from: cursor, count: rows, folding: empty, lenses: lenses,
                                    buffers: { buffers[$0] })
        // A window's worth, except at the very end of the buffer, where there is less left than a
        // window and the pane pads with blanks -- which is the picture `after-lens` is of.
        #expect(display.count <= rows, "\(label)")
        #expect(!display.isEmpty, "\(label)")
        var seen = Set<Int>()
        for entry in display {
            if case .row(let absolute) = entry {
                #expect(seen.insert(absolute).inserted, "row \(absolute) twice in one frame")
            }
        }
    }
    // The lens really is taller than the window, or none of the middle positions mean anything.
    #expect(lines.count > rows)
    // And the display bottom keeps the shell's prompt on screen rather than the head of the
    // response -- the rule `displayBottomCursor` exists for. It lands inside the lens.
    let bottom = try #require(positions.last?.1)
    #expect(bottom.row == lensStart)
    #expect(bottom.line > 0)
    let fromBottom = t.displayRows(from: bottom, count: rows, folding: empty, lenses: lenses,
                                   buffers: { buffers[$0] })
    #expect(fromBottom.count == rows)
    #expect(fromBottom.last == .row(t.totalRows - 1))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_SNAPSHOT"] != nil))
func theDisplayPathRendersAFoldOpeningAndClosing() throws {
    try FileManager.default.createDirectory(atPath: lensOutDir, withIntermediateDirectories: true)
    let cols = 74, rows = 18
    let grid = try LensGrid(cols: cols, rows: rows)
    let (t, curlID, bigID) = displayFixture(cols: cols, rows: rows, bigRows: 60)
    var lenses = LensChoices()
    lenses.set(.headers, for: curlID)
    let buffers = [curlID: LensBuffer(commandID: curlID, lens: .headers, lines: [
        LensLine("HTTP/2 200"),
        LensLine("content-type: application/json; charset=utf-8"),
        LensLine("\u{21AA} 301 \u{2192} https://api.example.com/v1/users"),
    ], contentVersion: t.contentVersion)]
    var folded = OutputFolding()
    folded.fold(bigID, .all)
    let themes: [(String, Palette)] = [("dark", try #require(Themes.builtin["nyx-dark"])),
                                       ("light", try #require(Themes.builtin["nyx-light"]))]
    // The frame the fold is on and the frame it has just come off, from the same cursor: the
    // second is the transition, where a stale slot would show a placeholder over a real row.
    let big = try #require(t.promptRow(ofCommand: bigID).flatMap { t.command(containingAbsoluteRow: $0) })
    let cursor = DisplayCursor(row: big.promptRow)
    for (themeName, palette) in themes {
        grid.draw(t, from: cursor, folding: folded, lenses: lenses, buffers: buffers,
                  palette: palette, named: "display-folded-\(themeName)")
        grid.draw(t, from: cursor, folding: OutputFolding(), lenses: lenses, buffers: buffers,
                  palette: palette, named: "display-unfolded-\(themeName)")
    }
    let withFold = t.displayRows(from: cursor, count: rows, folding: folded, lenses: lenses,
                                 buffers: { buffers[$0] })
    #expect(withFold.contains { if case .fold = $0 { return true } else { return false } })
    let without = t.displayRows(from: cursor, count: rows, folding: OutputFolding(), lenses: lenses,
                                buffers: { buffers[$0] })
    #expect(!without.contains { if case .fold = $0 { return true } else { return false } })
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_SNAPSHOT"] != nil))
func theDisplayPathRendersAWatchSeries() throws {
    try FileManager.default.createDirectory(atPath: lensOutDir, withIntermediateDirectories: true)
    let cols = 74, rows = 18
    let grid = try LensGrid(cols: cols, rows: rows)
    // Four runs of the same request, the older three folded, a diff lens on the newest: what a
    // watching pane looks like after a minute.
    let t = Terminal(cols: cols, rows: rows, scrollbackLimit: 2_000)
    var ids: [UInt32] = []
    for run in 1...4 {
        t.feed(displayMark("A") + "$ " + displayMark("B")
               + "curl -sSi https://api.example.com/health\r\n" + displayMark("C"))
        t.feed("HTTP/2 \(run == 3 ? 503 : 200)\r\n{\"n\":\(run),\"state\":\"ready\"}\r\n")
        t.feed(displayMark("D", 0))
        if let region = t.command(containingAbsoluteRow: t.totalRows - 1) { ids.append(region.id) }
    }
    t.feed(displayMark("A") + "$ ")
    #expect(ids.count == 4)
    var folding = OutputFolding()
    for id in ids.dropLast() { folding.fold(id, .all) }
    var lenses = LensChoices()
    let newest = try #require(ids.last)
    lenses.set(.diff(previousCommandID: ids[2]), for: newest)
    let buffers = [newest: LensBuffer(commandID: newest, lens: .diff(previousCommandID: ids[2]),
                                      lines: [
        LensLine("1 line changed \u{b7} status 503 \u{2192} 200 \u{b7} 310 ms \u{2192} 142 ms"),
        LensLine("  {"),
        LensLine("-   \"n\": 3,"),
        LensLine("+   \"n\": 4,"),
        LensLine("    \"state\": \"ready\""),
        LensLine("  }"),
    ], contentVersion: t.contentVersion)]
    let themes: [(String, Palette)] = [("dark", try #require(Themes.builtin["nyx-dark"])),
                                       ("light", try #require(Themes.builtin["nyx-light"]))]
    let cursor = t.displayBottomCursor(folding: folding, lenses: lenses, viewportRows: rows,
                                       buffers: { buffers[$0] })
    for (themeName, palette) in themes {
        grid.draw(t, from: cursor, folding: folding, lenses: lenses, buffers: buffers,
                  palette: palette, named: "display-watch-\(themeName)")
    }
    let display = t.displayRows(from: cursor, count: rows, folding: folding, lenses: lenses,
                                buffers: { buffers[$0] })
    #expect(display.filter { if case .fold = $0 { return true } else { return false } }.count == 3)
    #expect(display.contains { if case .lens = $0 { return true } else { return false } })
}

/// The three colours a fold placeholder can be, in one picture, in both themes.
///
/// A placeholder is text, and all three of its states have to be readable on every theme. They were
/// `.indexed(8)`, `.indexed(1)` and `.indexed(3)` handed to the renderer raw: 1.91:1 for the grey
/// on nyx-dark, 2.69 for gruvbox-dark's red, 4.29 for nyx-light's amber. Nothing pictured the red or
/// the amber at all, which is how they stayed that way.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_SNAPSHOT"] != nil))
func theDisplayPathRendersEveryFoldPlaceholderTone() throws {
    try FileManager.default.createDirectory(atPath: lensOutDir, withIntermediateDirectories: true)
    let cols = 74, rows = 12
    let grid = try LensGrid(cols: cols, rows: rows)
    let t = Terminal(cols: cols, rows: rows, scrollbackLimit: 500)
    // Succeeded, failed, and one still running -- a folded build is a live tail, so the amber has
    // to say "this is still going" from the placeholder alone.
    t.feed(displayMark("A") + "$ " + displayMark("B") + "make test\r\n" + displayMark("C"))
    for i in 1...8 { t.feed("test \(i) passed\r\n") }
    t.feed(displayMark("D", 0))
    t.feed(displayMark("A") + "$ " + displayMark("B") + "make lint\r\n" + displayMark("C"))
    for i in 1...8 { t.feed("lint error \(i)\r\n") }
    t.feed(displayMark("D", 1))
    t.feed(displayMark("A") + "$ " + displayMark("B") + "npm install\r\n" + displayMark("C"))
    for i in 1...8 { t.feed("fetching package \(i)\r\n") }

    var folding = OutputFolding()
    var ids: [UInt32] = []
    for promptRow in t.promptRows {
        guard let region = t.command(containingAbsoluteRow: promptRow), region.id != 0 else { continue }
        folding.fold(region.id, .all)
        ids.append(region.id)
    }
    #expect(ids.count == 3)
    let themes: [(String, Palette)] = [("dark", try #require(Themes.builtin["nyx-dark"])),
                                       ("light", try #require(Themes.builtin["nyx-light"]))]
    for (themeName, palette) in themes {
        t.palette = palette
        grid.draw(t, from: DisplayCursor(row: 0), folding: folding, lenses: LensChoices(),
                  buffers: [:], palette: palette, named: "display-fold-tones-\(themeName)")
    }
    let display = t.displayRows(from: DisplayCursor(row: 0), count: rows, folding: folding,
                                lenses: LensChoices(), buffers: { _ in nil })
    let statuses = display.compactMap { row -> BlockStatus? in
        if case .fold(_, _, let status) = row { return status } else { return nil }
    }
    #expect(statuses == [.succeeded, .failed, .running])
}
