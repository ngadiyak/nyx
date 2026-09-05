// Draws Nyx's app icon and writes the PNGs an .icns is built from.
//
// The icon is drawn rather than designed in a graphics editor because there is no editor in this
// toolchain, and because a drawn icon is diffable: changing the mark means changing the code below,
// not committing a new opaque binary nobody can review.
//
// The mark: on a near-black rounded tile, one bold light-grey stroke traces a cursor's path -- up
// the left stem, then diagonally down to the right -- and the right stem is finished as a solid
// amber block, the shape of a terminal's block cursor. Read together, the stroke and the block form
// an "N" (Nyx) without spelling the name or drawing a literal glyph: a prompt cursor moving is
// already the terminal's own vocabulary, and a chevron-and-cursor pairing (the previous icon) reads
// as generic "any terminal" once every other emulator uses the same cliche. One accent colour,
// one stroke weight, no glow or glass on the mark itself, so the silhouette is what survives at 16pt.
//
// Usage: swift scripts/make_icon.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make_icon.swift <output-directory>\n".data(using: .utf8)!)
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func draw(size: Int) -> CGImage? {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    let space = CGColorSpaceCreateDeviceRGB()

    // macOS icons sit in a rounded square with a margin; these proportions match the system grid.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237
    let body = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Near-black tile with a faint top-to-bottom fall-off, so the mark stays legible on both light
    // and dark Dock backgrounds without needing a border.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let tileColors = [
        CGColor(colorSpace: space, components: [0.09, 0.10, 0.15, 1])!,
        CGColor(colorSpace: space, components: [0.04, 0.04, 0.07, 1])!,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: tileColors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.minY), options: [])
    }
    // A faint sweep of light down from the top edge, the way a glass surface catches it. It has to
    // fade out rather than stop: a flat fill leaves a hard seam across the middle of the icon that
    // reads as a rendering bug.
    let sheenColors = [
        CGColor(colorSpace: space, components: [1, 1, 1, 0.08])!,
        CGColor(colorSpace: space, components: [1, 1, 1, 0])!,
    ] as CFArray
    if let sheen = CGGradient(colorsSpace: space, colors: sheenColors, locations: [0, 1]) {
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.midY), options: [])
    }
    ctx.restoreGState()

    // A 1-unit inner rim: lighter at the top than the bottom, so the tile reads as a slightly
    // raised surface rather than a flat cutout. Subtle on purpose -- it should not compete with
    // the mark.
    ctx.saveGState()
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.07])!)
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: s * 0.003, dy: s * 0.003),
                       cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    // The mark, as one group then centred as a whole: an "N" read from a cursor's own path (stem
    // up, diagonal down-right) with its second stem finished as the block cursor. The stem's
    // stroke extends stroke/2 to its own left, which the block's fill does not on its right, so
    // centring the nominal path width (rather than the true stroke-inclusive bounding box) leaves
    // the mark sitting stroke/4 left of true centre -- that correction, `+ stroke / 4`, is the
    // fix for centring, not an aesthetic choice. `opticalNudge` is a separate, small, deliberate
    // push toward the lighter (grey) side: the amber block is a solid fill and reads heavier than
    // the stroke next to it, so without it the icon looks faintly right-heavy in the Dock even
    // once the box is genuinely centred.
    let markWidth = rect.width * 0.50
    let markHeight = rect.height * 0.46
    let stroke = max(1, rect.width * 0.105)
    let opticalNudge = rect.width * 0.006
    let originX = rect.midX - markWidth / 2 + stroke / 4 - opticalNudge
    let baseline = rect.midY - markHeight / 2
    let top = baseline + markHeight

    let blockWidth = stroke * 1.18
    let blockHeight = markHeight * 0.60
    let blockLeft = originX + markWidth - blockWidth
    let blockBottom = baseline

    // Left stem up, then the diagonal down to the right -- the path a cursor takes -- ending well
    // inside the amber block's silhouette. The block is drawn afterwards on top, so whatever the
    // diagonal's stroke covers there is hidden entirely; what stays visible is a clean cut exactly
    // where the stroke crosses the block's top edge, with nothing poking out to the block's right.
    // The cap is `.butt`, not `.round`: a round cap on the stem's bottom would bulge stroke/2 below
    // the baseline the block's flat bottom sits on, so the two legs would not share a floor. Butt
    // cuts the stem off flat exactly at the baseline; the join at the top corner and the (hidden)
    // end of the diagonal are unaffected, since line cap only touches the two ends of the path.
    let diagonalEndX = blockLeft + blockWidth * 0.5
    let diagonalEndY = blockBottom + blockHeight * 0.32
    let path = CGMutablePath()
    path.move(to: CGPoint(x: originX, y: baseline))
    path.addLine(to: CGPoint(x: originX, y: top))
    path.addLine(to: CGPoint(x: diagonalEndX, y: diagonalEndY))
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [0.85, 0.87, 0.92, 1])!)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.butt)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()

    // The right stem is the block cursor, rising from the same baseline as the left stem, in the
    // one accent colour the mark uses.
    let block = CGRect(x: blockLeft, y: blockBottom, width: blockWidth, height: blockHeight)
    ctx.setFillColor(CGColor(colorSpace: space, components: [0.961, 0.647, 0.141, 1])!)
    let blockCorner = min(block.width, block.height) * 0.22
    ctx.addPath(CGPath(roundedRect: block, cornerWidth: blockCorner, cornerHeight: blockCorner,
                       transform: nil))
    ctx.fillPath()

    return ctx.makeImage()
}

for size in sizes {
    guard let image = draw(size: size) else {
        FileHandle.standardError.write("failed to draw \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = outputDirectory.appendingPathComponent("icon_\(size).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { exit(1) }
}
print("wrote \(sizes.count) sizes to \(outputDirectory.path)")
