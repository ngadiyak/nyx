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
        CGColor(colorSpace: space, components: [0.19, 0.20, 0.42, 1])!,
        CGColor(colorSpace: space, components: [0.04, 0.04, 0.10, 1])!,
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

    // The mark: a prompt chevron and the block cursor that follows it, laid out as ONE group and
    // then centred. Placing the two independently inside an inset box is what left the previous
    // version sitting low and to the left -- an icon is looked at next to other icons, and being a
    // few percent off centre is visible even when nothing else is.
    let markHeight = rect.height * 0.32
    let stroke = max(1, rect.width * 0.068)
    let chevronWidth = markHeight * 0.52
    let blockWidth = markHeight * 0.32
    // Wide enough that the chevron and the cursor stay two shapes: closer together they merge
    // into one blob at small sizes, which is where the icon is actually seen.
    let gap = markHeight * 0.42
    let markWidth = chevronWidth + gap + blockWidth

    let originX = rect.midX - markWidth / 2
    let midY = rect.midY
    let top = midY + markHeight / 2
    let bottom = midY - markHeight / 2

    // A soft glow behind the mark, so it sits on the surface rather than being painted flat onto
    // it. Barely visible on its own; what it does is stop the icon looking like a sticker.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let glowColors = [
        CGColor(colorSpace: space, components: [0.42, 0.55, 1.0, 0.22])!,
        CGColor(colorSpace: space, components: [0.42, 0.55, 1.0, 0])!,
    ] as CFArray
    if let glow = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: rect.midX, y: midY), startRadius: 0,
                               endCenter: CGPoint(x: rect.midX, y: midY), endRadius: rect.width * 0.45,
                               options: [])
    }
    ctx.restoreGState()

    // The chevron, as a path rather than text: identical at every size, and no font to install.
    let path = CGMutablePath()
    path.move(to: CGPoint(x: originX, y: top))
    path.addLine(to: CGPoint(x: originX + chevronWidth, y: midY))
    path.addLine(to: CGPoint(x: originX, y: bottom))
    ctx.setStrokeColor(CGColor(colorSpace: space, components: [0.55, 0.76, 1.0, 1])!)
    ctx.setLineWidth(stroke)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()

    // The cursor, in the warm colour a terminal cursor takes, so the two halves of the mark do not
    // read as one shape.
    let blockHeight = markHeight * 0.78
    let block = CGRect(x: originX + chevronWidth + gap, y: midY - blockHeight / 2,
                       width: blockWidth, height: blockHeight)
    ctx.setFillColor(CGColor(colorSpace: space, components: [1.0, 0.78, 0.36, 1])!)
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
