import Testing
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NyxCore
@testable import NyxRender

/// End-to-end snapshot test: drives a real zsh through `TerminalSession` into the `Renderer` and
/// reads pixels back from the rendered texture. Unlike the unit tests in `RendererTests.swift`,
/// this exercises the full pipeline (PTY -> parser -> Terminal -> Renderer -> Metal texture) with
/// real programs, which is what caught a glyph-orientation bug that every unit test missed.
///
/// Opt-in only: off by default so `swift test` stays fast and deterministic. Run with:
///   NYX_SNAPSHOT=1 swift test --filter Snapshot
///
/// PNGs land in `build/snapshots/` (git-ignored) for human inspection; the pixel assertions below
/// are what makes the test fail on its own without a human comparing images.
private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/NyxRenderTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
private let outDir = repoRoot.appendingPathComponent("build/snapshots").path

private func readPixels(_ tex: MTLTexture) -> (bytes: [UInt8], width: Int, height: Int) {
    let w = tex.width, h = tex.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (bytes, w, h)
}

private func writePNG(_ bytes: [UInt8], width: Int, height: Int, to path: String) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: cs, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

/// Perceptual brightness (0...255) of a BGRA pixel at (x, y) in `bytes` of a `width`-wide image.
private func luma(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> Int {
    let i = (y * width + x) * 4
    let b = Int(bytes[i]), g = Int(bytes[i + 1]), r = Int(bytes[i + 2])
    return (r * 299 + g * 587 + b * 114) / 1000
}

private func luma(_ c: RGB) -> Int {
    (Int(c.r) * 299 + Int(c.g) * 587 + Int(c.b) * 114) / 1000
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NYX_SNAPSHOT"] != nil))
func liveSessionRendersCorrectly() throws {
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 13, scale: 2)
    let r = try Renderer(device: device, fonts: fonts)
    let cols = 90, rows = 26, pad = 16
    let palette = Palette(
        ansi: [0x1E2129, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xFF7A93, 0xB9F27C, 0xFF9E64, 0x7DA6FF, 0xBB9AF7, 0x0DB9D7, 0xC0CAF5].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xC0CAF5), background: RGB(hex: 0x1A1B26), cursor: RGB(hex: 0xC0CAF5))
    var cfg = SessionConfig.loginShell(cols: cols, rows: rows, palette: palette)
    cfg.environment["PS1"] = "$ "
    cfg.environment["PROMPT"] = "%~ $ "
    let s = try TerminalSession(config: cfg)
    let width = fonts.metrics.width * cols + pad * 2
    let height = fonts.metrics.height * rows + pad * 2
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))

    @discardableResult
    func snap(_ name: String) -> (bytes: [UInt8], width: Int, height: Int) {
        let frame: RenderFrame = s.withTerminal { t in
            RenderFrame(cols: t.cols, rows: t.rows, lines: (0..<t.rows).map { t.viewportRow($0) }, graphemes: t.graphemes, palette: t.palette,
                        cursor: t.modes.showCursor ? t.screen.cursor : nil, cursorShape: t.cursorShape, focused: true, preedit: nil)
        }
        let cb = r.queue.makeCommandBuffer()!
        r.render(frame, to: tex, commandBuffer: cb, padding: pad)
        let blit = cb.makeBlitCommandEncoder()!
        blit.synchronize(resource: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let pixels = readPixels(tex)
        writePNG(pixels.bytes, width: pixels.width, height: pixels.height, to: outDir + "/" + name + ".png")
        return pixels
    }
    func type(_ str: String, wait: UInt32 = 1_000_000) { s.send(Array(str.utf8)); usleep(wait) }

    usleep(1_000_000)

    // 1. Shell prompt with SGR attributes (bold/underline/italic/inverse/strike/24-bit color, 16-color cube).
    type("printf '\\e[1;31mbold red\\e[0m \\e[4:3mcurly\\e[0m \\e[3mitalic\\e[0m \\e[7minverse\\e[0m \\e[9mstrike\\e[0m \\e[38;2;255;160;0mrgb\\e[0m\\n'\n")
    // 2. Cyrillic, CJK, emoji and a combining character.
    type("echo 'привет мир 😀 漢字テスト ─┼│ e\\u0301'\n")
    let shell = snap("1-shell")

    // Non-visual assertion (a): the render is not blank — some pixel differs from the background.
    let bgLuma = luma(palette.background)
    var sawInk = false
    outer: for y in stride(from: 0, to: shell.height, by: 3) {
        for x in stride(from: 0, to: shell.width, by: 3) where abs(luma(shell.bytes, width: shell.width, x: x, y: y) - bgLuma) > 40 {
            sawInk = true
            break outer
        }
    }
    #expect(sawInk, "rendered frame should not be blank")

    // Non-visual assertion (b): a capital "L" has more ink in its lower half than its upper half.
    // This is the orientation check that unit tests missed — a flipped glyph renders as roughly the
    // mirror image (heavier top, e.g. looking like Γ), so this fails loudly if that regresses.
    type("clear; printf 'L'\n", wait: 600_000)
    let lFrame = snap("2-capital-L")
    let m = fonts.metrics
    let cellX0 = pad, cellY0 = pad   // the "L" prints at row 0, col 0 right after `clear`
    var topInk = 0, bottomInk = 0
    for y in 0..<m.height {
        for x in 0..<m.width where abs(luma(lFrame.bytes, width: lFrame.width, x: cellX0 + x, y: cellY0 + y) - bgLuma) > 40 {
            if y < m.height / 2 { topInk += 1 } else { bottomInk += 1 }
        }
    }
    #expect(topInk > 0 || bottomInk > 0, "expected the 'L' glyph to render some ink at all")
    #expect(bottomInk > topInk, "capital L should have more ink in its lower half (base+foot) than its upper half — got top=\(topInk) bottom=\(bottomInk)")

    // 3. Alt-screen editor session (vim).
    type("vim /tmp/nyx-snapshot-test.txt\n", wait: 2_000_000)
    type("ihello from vim\nsecond line\u{1B}", wait: 600_000)
    type(":set number\n", wait: 600_000)
    snap("3-vim")
    type(":q!\n", wait: 1_000_000)
    type("clear\n", wait: 500_000)

    // 4. Resize.
    s.resize(cols: 60, rows: 26)
    usleep(500_000)
    type("echo resized to 60 cols\n", wait: 800_000)
    snap("4-resized-60")

    // 5. Scrollback scroll.
    type("seq 1 300 | tail -3\n", wait: 1_000_000)
    s.withTerminal { $0.scrollViewport(by: 20) }
    snap("5-scrolled-up")

    type("exit\n", wait: 300_000)
}
