import Testing
import Foundation
import Metal
import NyxCore
@testable import NyxRender

// DECSET 2026, synchronised output. The rule an application is buying when it sends BSU is "nobody
// sees this update half-finished", and the rule a user is owed in return is "a program that never
// says it is finished cannot freeze my terminal". Both are asserted here: the first against real
// pixels, because a boolean saying "held" proves nothing about what is on the screen.

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

private func readPixels(_ r: Renderer, _ tex: MTLTexture) throws -> [UInt8] {
    let cb = try #require(r.queue.makeCommandBuffer())
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
    tex.getBytes(&bytes, bytesPerRow: tex.width * 4, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
    return bytes
}

/// Draws through the gated entry point -- the one the view uses -- and hands back what the texture
/// holds afterwards, which is what a reader would be looking at.
@discardableResult
private func present(_ r: Renderer, _ frame: RenderFrame, to tex: MTLTexture,
                     syncOutput: Bool, at now: TimeInterval) throws -> FramePresentation {
    let cb = try #require(r.queue.makeCommandBuffer())
    let outcome = r.draw(frame, to: tex, commandBuffer: cb, padding: 0, syncOutput: syncOutput, now: now)
    cb.commit()
    cb.waitUntilCompleted()
    return outcome
}

private func filled(cols: Int, rows: Int, with scalar: UInt32) -> RenderFrame {
    var lines = Array(repeating: Row(cols: cols), count: rows)
    for y in 0..<rows { for x in 0..<cols { lines[y].cells[x].content = scalar } }
    return RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: .xtermDefault(),
                       cursor: nil, cursorShape: .block, focused: true, preedit: nil)
}

@Test func screenDoesNotChangeWhileAnUpdateIsInFlight() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let r = try Renderer(device: device, fonts: fonts)
    let tex = try makeTexture(device, cols: 4, rows: 2, fonts: fonts)
    let before = filled(cols: 4, rows: 2, with: 0x41)   // 'A'
    let during = filled(cols: 4, rows: 2, with: 0x42)   // 'B'

    #expect(try present(r, before, to: tex, syncOutput: false, at: 100) == .presented)
    let shown = try readPixels(r, tex)

    // The application has begun an update. Everything it draws now is half a picture.
    #expect(try present(r, during, to: tex, syncOutput: true, at: 100.01) == .held)
    #expect(try readPixels(r, tex) == shown)
    #expect(try present(r, during, to: tex, syncOutput: true, at: 100.02) == .held)
    #expect(try readPixels(r, tex) == shown)
}

@Test func theFinishedUpdateIsShownWhenTheApplicationSaysSo() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let r = try Renderer(device: device, fonts: fonts)
    let tex = try makeTexture(device, cols: 4, rows: 2, fonts: fonts)
    let before = filled(cols: 4, rows: 2, with: 0x41)
    let after = filled(cols: 4, rows: 2, with: 0x42)

    try present(r, before, to: tex, syncOutput: false, at: 0)
    let firstPicture = try readPixels(r, tex)
    try present(r, after, to: tex, syncOutput: true, at: 0.01)
    // ESU: the update is complete, and what it built goes up in one piece.
    #expect(try present(r, after, to: tex, syncOutput: false, at: 0.02) == .presented)
    #expect(try readPixels(r, tex) != firstPicture)
}

@Test func anUpdateThatNeverEndsStopsHoldingTheScreen() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = makeFonts()
    let r = try Renderer(device: device, fonts: fonts)
    let tex = try makeTexture(device, cols: 4, rows: 2, fonts: fonts)
    let before = filled(cols: 4, rows: 2, with: 0x41)
    let after = filled(cols: 4, rows: 2, with: 0x42)

    try present(r, before, to: tex, syncOutput: false, at: 0)
    let firstPicture = try readPixels(r, tex)
    // The application sent BSU and then died, was stopped, or simply forgot ESU: the mode stays set
    // for as long as anyone asks. The screen must come back to life on its own.
    #expect(try present(r, after, to: tex, syncOutput: true, at: 0) == .held)
    #expect(try readPixels(r, tex) == firstPicture)
    #expect(try present(r, after, to: tex, syncOutput: true, at: r.syncOutputTimeout * 2) == .presented)
    #expect(try readPixels(r, tex) != firstPicture)
    // And it stays alive: one frame per timeout is a stutter, not a recovery.
    #expect(try present(r, before, to: tex, syncOutput: true, at: r.syncOutputTimeout * 2 + 0.001) == .presented)
    #expect(try readPixels(r, tex) == firstPicture)
}

// MARK: - The gate itself

@Test func nothingIsHeldWhileTheModeIsOff() {
    var gate = SyncOutputGate()
    var presented = gate.shouldPresent(syncOutput: false, now: 0)
    #expect(presented)
    presented = gate.shouldPresent(syncOutput: false, now: 10)
    #expect(presented)
    #expect(!gate.isHolding)
}

@Test func askingTwiceInOneTickAnswersTheSameThing() {
    var gate = SyncOutputGate()
    let first = gate.shouldPresent(syncOutput: true, now: 5)
    let second = gate.shouldPresent(syncOutput: true, now: 5)
    #expect(first == second)
    #expect(!first)
}

@Test func theHoldLastsExactlyUntilTheTimeout() {
    var gate = SyncOutputGate(timeout: 0.15)
    var presented = gate.shouldPresent(syncOutput: true, now: 1)
    #expect(!presented)
    presented = gate.shouldPresent(syncOutput: true, now: 1 + 0.149)
    #expect(!presented)
    #expect(gate.isHolding)
    presented = gate.shouldPresent(syncOutput: true, now: 1 + 0.151)
    #expect(presented)
    #expect(!gate.isHolding)
}

@Test func aNewUpdateAfterTheLastOneEndedIsHeldAgain() {
    var gate = SyncOutputGate(timeout: 0.15)
    // An update that ran out of patience does not poison the ones after it: tmux redrawing a status
    // line once a second must be honoured every second, not only the first time.
    _ = gate.shouldPresent(syncOutput: true, now: 0)
    var presented = gate.shouldPresent(syncOutput: true, now: 1)
    #expect(presented)
    presented = gate.shouldPresent(syncOutput: false, now: 2)
    #expect(presented)
    presented = gate.shouldPresent(syncOutput: true, now: 3)
    #expect(!presented)
}

@Test func aHoldNeverOutlivesItsTimeoutByMoreThanATick() {
    // The number itself is a judgement call, but its order of magnitude is not: a terminal that can
    // be frozen for a second by a crashed program is worse than one that tears.
    let gate = SyncOutputGate()
    #expect(gate.timeout <= 0.25)
    #expect(gate.timeout >= 0.05)
}
