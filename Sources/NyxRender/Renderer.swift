import Metal
import QuartzCore
import NyxCore

/// Everything the renderer needs for one frame. Built by the view under the session lock.
public struct RenderFrame {
    public var cols: Int
    public var rows: Int
    public var lines: [Row]
    public var graphemes: [String]
    public var palette: Palette
    public var cursor: Cursor?
    public var cursorShape: CursorShape
    public var focused: Bool
    public var preedit: String?
    /// Selected column range per visible row, indexed the same way as `lines`. nil means nothing
    /// selected on that row. The view computes these from the absolute selection and the viewport.
    public var selection: [Range<Int>?]
    /// Search hits per visible row, indexed like `selection`; a row can hold several. Produced by
    /// `SearchHighlights.visibleRanges`, which is where the absolute-to-viewport arithmetic lives.
    public var searchMatches: [[Range<Int>]]
    /// The hit the user is standing on, painted in a second colour so it stands out from the rest.
    public var currentSearchMatch: [Range<Int>?]
    /// The link under the pointer, underlined on hover. One range per visible row because a token
    /// never spans rows.
    public var hoveredLink: [Range<Int>?]
    /// Short text pinned to the right edge of a visible row, drawn dim and behind nothing.
    ///
    /// How long a command took belongs *on* the command, visible without hovering, folding or
    /// scrolling. A number that can only be reached by doing something first is a number nobody
    /// reads. Indexed like `selection`; nil on rows with nothing to say.
    public var rowNotes: [String?]
    /// A command's spine: the visible row range it covers, and the colour to draw it in. Painted
    /// down the left margin, over the padding rather than over any text.
    public var blockSpines: [(rows: Range<Int>, color: RGB)]

    public init(cols: Int, rows: Int, lines: [Row], graphemes: [String], palette: Palette,
                cursor: Cursor?, cursorShape: CursorShape, focused: Bool, preedit: String?,
                selection: [Range<Int>?] = [], searchMatches: [[Range<Int>]] = [],
                currentSearchMatch: [Range<Int>?] = [], hoveredLink: [Range<Int>?] = [],
                rowNotes: [String?] = [],
                blockSpines: [(rows: Range<Int>, color: RGB)] = []) {
        self.cols = cols; self.rows = rows; self.lines = lines; self.graphemes = graphemes; self.palette = palette
        self.cursor = cursor; self.cursorShape = cursorShape; self.focused = focused; self.preedit = preedit
        self.selection = selection
        self.searchMatches = searchMatches
        self.currentSearchMatch = currentSearchMatch
        self.rowNotes = rowNotes
        self.blockSpines = blockSpines
        self.hoveredLink = hoveredLink
    }
}

/// Matches `struct Instance` in Shaders.swift: 64 bytes.
struct Instance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var uv0: SIMD2<Float>
    var uv1: SIMD2<Float>
    var color: SIMD4<Float>
    var kind: UInt32
    var p0: UInt32 = 0, p1: UInt32 = 0, p2: UInt32 = 0
}

struct Uniforms {
    var viewport: SIMD2<Float>
    var atlasSize: Float
    var pad: Float = 0
}

public enum RendererError: Error { case noCommandQueue }

public final class Renderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let atlas: GlyphAtlas
    public private(set) var fonts: FontSet

    private let pipeline: MTLRenderPipelineState
    private var instances: [Instance] = []
    private var glyphs: [Instance] = []
    private var decorations: [Instance] = []
    private var instanceBuffer: MTLBuffer?

    public init(device: MTLDevice, fonts: FontSet) throws {
        self.device = device
        self.fonts = fonts
        guard let q = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        queue = q
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "nyx_vertex")
        desc.fragmentFunction = library.makeFunction(name: "nyx_fragment")
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        atlas = GlyphAtlas(device: device, fonts: fonts)
    }

    public func setFonts(_ f: FontSet) {
        fonts = f
        atlas.setFonts(f)
    }

    /// Returns false when the layer had no drawable to hand out, so the caller can keep the frame
    /// marked stale and try again on the next tick instead of leaving stale pixels on screen.
    @discardableResult
    public func draw(_ frame: RenderFrame, in layer: CAMetalLayer, padding: Int) -> Bool {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return false }
        render(frame, to: drawable.texture, commandBuffer: cb, padding: padding)
        cb.present(drawable)
        cb.commit()
        return true
    }

    public func render(_ frame: RenderFrame, to texture: MTLTexture, commandBuffer: MTLCommandBuffer, padding: Int) {
        buildInstances(frame, padding: padding)
        let bytes = max(instances.count * MemoryLayout<Instance>.stride, 64)
        if instanceBuffer == nil || instanceBuffer!.length < bytes {
            instanceBuffer = device.makeBuffer(length: bytes * 2, options: .storageModeShared)
        }
        if !instances.isEmpty {
            _ = instances.withUnsafeBytes { memcpy(instanceBuffer!.contents(), $0.baseAddress!, $0.count) }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = frame.palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        var uniforms = Uniforms(viewport: SIMD2<Float>(Float(texture.width), Float(texture.height)), atlasSize: Float(GlyphAtlas.size))
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(atlas.texture, index: 0)
        if !instances.isEmpty {
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        enc.endEncoding()
    }

    // MARK: - Instance building

    private func rgba(_ c: RGB) -> SIMD4<Float> {
        SIMD4<Float>(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, 1)
    }

    private func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ color: RGB, kind: UInt32 = 0) -> Instance {
        Instance(pos: SIMD2(x, y), size: SIMD2(w, h), uv0: .zero, uv1: .zero, color: rgba(color), kind: kind)
    }

    /// One textured quad for `g`, positioned by the glyph's own bearings relative to the cell origin.
    private func glyphQuad(_ g: Glyph, cellX: Float, cellY: Float, color: RGB) -> Instance {
        Instance(pos: SIMD2(cellX + Float(g.left), cellY + Float(g.top)),
                 size: SIMD2(Float(g.width), Float(g.height)),
                 uv0: SIMD2(Float(g.x), Float(g.y)),
                 uv1: SIMD2(Float(g.x + g.width), Float(g.y + g.height)),
                 color: rgba(color), kind: g.isColor ? 2 : 1)
    }

    private func resolve(_ c: Cell, _ p: Palette) -> (fg: RGB, bg: RGB) {
        var fg = c.fg
        if c.attrs.contains(.bold), fg.kind == .indexed, fg.index < 8 { fg = .indexed(fg.index + 8) }
        var f = p.resolve(fg, isForeground: true)
        var b = p.resolve(c.bg, isForeground: false)
        if c.attrs.contains(.inverse) { swap(&f, &b) }
        if c.attrs.contains(.dim) { f = f.scaled(0.6) }
        return (f, b)
    }

    private func buildInstances(_ f: RenderFrame, padding: Int) {
        let m = fonts.metrics
        let cw = Float(m.width), ch = Float(m.height), thick = Float(m.thickness)
        for _ in 0..<2 {
            let gen = atlas.generation
            instances.removeAll(keepingCapacity: true)
            glyphs.removeAll(keepingCapacity: true)
            decorations.removeAll(keepingCapacity: true)

            for y in 0..<min(f.rows, f.lines.count) {
                let row = f.lines[y]
                for x in 0..<min(f.cols, row.cells.count) {
                    let c = row.cells[x]
                    if c.attrs.contains(.wideSpacer) { continue }
                    let isCursor = f.cursor.map { $0.x == x && $0.y == y } ?? false
                    var (fg, bg) = resolve(c, f.palette)
                    let wide = c.attrs.contains(.wide)
                    let px = Float(padding + x * m.width), py = Float(padding + y * m.height)
                    let w = wide ? cw * 2 : cw

                    let selected = y < f.selection.count && (f.selection[y]?.contains(x) ?? false)
                    let isCurrentMatch = y < f.currentSearchMatch.count
                        && (f.currentSearchMatch[y]?.contains(x) ?? false)
                    let isMatch = isCurrentMatch
                        || (y < f.searchMatches.count && f.searchMatches[y].contains { $0.contains(x) })
                    // The selection wins over a search hit: it is the thing the user just made,
                    // and ⌘C acts on it. A hit under the selection is still highlighted everywhere
                    // else on screen, which is what a search bar has to show.
                    if selected {
                        bg = f.palette.selectionBackground
                        if let sf = f.palette.selectionForeground { fg = sf }
                    } else if isMatch {
                        // The current hit is painted at full strength with contrasting text; the
                        // rest are a tint behind unchanged text. Painting all of them the same way
                        // makes a page of matches into a page of yellow, and hides the one hit that
                        // the user is actually standing on.
                        bg = isCurrentMatch ? f.palette.currentMatchBackground : f.palette.searchMatchBackground
                        if isCurrentMatch { fg = f.palette.searchMatchForeground }
                    }

                    let blockCursor = isCursor && f.focused && f.cursorShape == .block
                    if blockCursor { bg = f.palette.cursor; fg = f.palette.background }
                    if bg != f.palette.background || blockCursor || selected || isMatch {
                        instances.append(rect(px, py, w, ch, bg))
                    }

                    if c.content != 0, !c.attrs.contains(.hidden) {
                        let text: GlyphText = c.graphemeIndex.map { .cluster(f.graphemes[$0]) } ?? .scalar(c.content)
                        let key = GlyphKey(text: text, bold: c.attrs.contains(.bold), italic: c.attrs.contains(.italic))
                        if let g = atlas.glyph(for: key) {
                            glyphs.append(glyphQuad(g, cellX: px, cellY: py, color: fg))
                        }
                    }

                    let ulY = py + Float(m.underlineY)
                    let ulColor = c.ul.kind == .default ? fg : f.palette.resolve(c.ul, isForeground: true)
                    switch c.underline {
                    case .none: break
                    case .single: decorations.append(rect(px, ulY, w, thick, ulColor))
                    case .double:
                        decorations.append(rect(px, ulY - thick, w, thick, ulColor))
                        decorations.append(rect(px, ulY + thick, w, thick, ulColor))
                    case .curly: decorations.append(rect(px, ulY - thick, w, thick * 3, ulColor, kind: 3))
                    case .dotted: decorations.append(rect(px, ulY, w, thick, ulColor, kind: 4))
                    case .dashed: decorations.append(rect(px, ulY, w, thick, ulColor, kind: 5))
                    }
                    if c.attrs.contains(.strike) {
                        decorations.append(rect(px, py + Float(m.strikeY), w, thick, fg))
                    }
                    // A hovered link is underlined in the text's own colour, on the same baseline
                    // the SGR underlines use, so a link that is already underlined does not gain a
                    // second line in a different place.
                    if y < f.hoveredLink.count, f.hoveredLink[y]?.contains(x) ?? false, c.underline == .none {
                        decorations.append(rect(px, ulY, w, thick, fg))
                    }

                    if isCursor {
                        let cc = f.palette.cursor
                        if !f.focused {
                            decorations.append(rect(px, py, w, thick, cc))
                            decorations.append(rect(px, py + ch - thick, w, thick, cc))
                            decorations.append(rect(px, py, thick, ch, cc))
                            decorations.append(rect(px + w - thick, py, thick, ch, cc))
                        } else if f.cursorShape == .bar {
                            decorations.append(rect(px, py, thick, ch, cc))
                        } else if f.cursorShape == .underline {
                            decorations.append(rect(px, py + ch - thick * 2, w, thick * 2, cc))
                        }
                    }
                }
            }

            // A command's spine, drawn in the left padding: it says "these rows belong together"
            // without taking a column of text or touching a cell. Nothing about the grid changes,
            // which is what lets vim and htop keep behaving exactly as they did.
            for spine in f.blockSpines {
                guard !spine.rows.isEmpty else { continue }
                let top = Float(padding + spine.rows.lowerBound * m.height)
                let height = Float(spine.rows.count * m.height)
                let x = Float(max(0, padding - 6))
                instances.append(rect(x, top, 2, height, spine.color))
            }

            // Right-aligned notes: how long a command took, on the command's own row, dim enough
            // to ignore and present enough to read without doing anything first.
            for (y, note) in f.rowNotes.enumerated() {
                guard let note, !note.isEmpty, y < f.rows else { continue }
                let characters = Array(note)
                let start = f.cols - characters.count
                guard start > 0 else { continue }
                // Never over the text: a note that overwrites the end of a long command line is
                // worse than no note at all.
                let row = y < f.lines.count ? f.lines[y] : nil
                let lastUsed = row.map { line -> Int in
                    var last = -1
                    for (column, cell) in line.cells.enumerated() where cell.content != 0 { last = column }
                    return last
                } ?? -1
                guard lastUsed < start - 1 else { continue }

                for (offset, character) in characters.enumerated() {
                    let px = Float(padding + (start + offset) * m.width), py = Float(padding + y * m.height)
                    let text = String(character)
                    let glyphText: GlyphText = text.unicodeScalars.count == 1
                        ? .scalar(text.unicodeScalars.first!.value) : .cluster(text)
                    if let g = atlas.glyph(for: GlyphKey(text: glyphText, bold: false, italic: false)) {
                        glyphs.append(glyphQuad(g, cellX: px, cellY: py, color: f.palette.noteForeground))
                    }
                }
            }

            if let pre = f.preedit, !pre.isEmpty, let cur = f.cursor {
                var x = cur.x
                for character in pre {
                    let s = String(character)
                    let width = CharWidth.width(of: s)
                    guard width > 0, x + width <= f.cols else { break }
                    let px = Float(padding + x * m.width), py = Float(padding + cur.y * m.height)
                    let w = Float(width) * cw
                    instances.append(rect(px, py, w, ch, f.palette.foreground))
                    let text: GlyphText = s.unicodeScalars.count == 1 ? .scalar(s.unicodeScalars.first!.value) : .cluster(s)
                    if let g = atlas.glyph(for: GlyphKey(text: text, bold: false, italic: false)) {
                        glyphs.append(glyphQuad(g, cellX: px, cellY: py, color: f.palette.background))
                    }
                    x += width
                }
            }

            if atlas.generation == gen { break }
        }
        instances.append(contentsOf: glyphs)
        instances.append(contentsOf: decorations)
    }
}
