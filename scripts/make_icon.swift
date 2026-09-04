// Draws Nyx's app icon and writes the PNGs an .icns is built from.
//
// The icon is drawn rather than designed in a graphics editor because there is no editor in this
// toolchain, and because a drawn icon is diffable: changing the mark means changing the code below,
// not committing a new opaque binary nobody can review.
//
// The mark: a night-blue rounded square -- Nyx is the goddess of night -- carrying a prompt chevron
// and the block cursor that follows it. At 16 pt the chevron and the block are all that survive,
// which is the point: it has to read as "a terminal" in the Dock and the ⌘-Tab strip, at a glance.
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

    // macOS icons sit in a rounded square with a margin; these proportions match the system grid.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237
    let body = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Night sky: deep indigo at the top falling to near-black, so the mark stays legible on both
    // light and dark Dock backgrounds without a border.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let colors = [
        CGColor(colorSpace: space, components: [0.16, 0.17, 0.35, 1])!,
        CGColor(colorSpace: space, components: [0.05, 0.05, 0.11, 1])!,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.minY), options: [])
    }

    // A faint sweep of light down from the top edge, the way a glass surface catches it. It has to
    // fade out rather than stop: a flat fill leaves a hard seam across the middle of the icon that
    // reads as a rendering bug.
    let sheenColors = [
        CGColor(colorSpace: space, components: [1, 1, 1, 0.10])!,
        CGColor(colorSpace: space, components: [1, 1, 1, 0])!,
    ] as CFArray
    if let sheen = CGGradient(colorsSpace: space, colors: sheenColors, locations: [0, 1]) {
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: rect.maxY),
                               end: CGPoint(x: 0, y: rect.midY), options: [])
    }
    ctx.restoreGState()

    // The mark, laid out in a box inset from the body so it never crowds the corners.
    let mark = rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.30)
    let stroke = max(1, rect.width * 0.075)

    // The prompt chevron. Drawn as a path rather than set as text so it is identical at every size
    // and needs no font to be installed.
    let chevronWidth = mark.width * 0.42
    let path = CGMutablePath()
    path.move(to: CGPoint(x: mark.minX, y: mark.maxY))
    path.addLine(to: CGPoint(x: mark.minX + chevronWidth, y: mark.midY))
    path.addLine(to: CGPoint(x: mark.minX, y: mark.minY))
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [0.61, 0.80, 1.0, 1])!)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()

    // The block cursor after it, in the warm colour a terminal cursor usually takes, so the two
    // parts of the mark do not read as one shape.
    let blockWidth = mark.width * 0.30
    let blockHeight = mark.height * 0.62
    let block = CGRect(x: mark.maxX - blockWidth, y: mark.midY - blockHeight / 2,
                       width: blockWidth, height: blockHeight)
    ctx.setFillColor(CGColor(colorSpace: space, components: [0.98, 0.76, 0.35, 1])!)
    let blockCorner = min(blockWidth, blockHeight) * 0.18
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
