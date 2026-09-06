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
            frame += (0..<(rows - 1)).map { buffer.row($0, cols: cols, palette: .standard) }
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
