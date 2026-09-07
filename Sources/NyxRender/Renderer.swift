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
    /// A block's summary -- `exit 1 · 8.8s` -- pinned to the right of its command row. Same
    /// treatment as `rowNotes`, in the block's own colour so the status reads without being read.
    public var blockSummaries: [(row: Int, text: String, color: RGB)]
    /// The visible rows of the block under the pointer, tinted as one. nil when nothing is hovered,
    /// which is the state of every frame the mouse is not moving through. Chrome, not a row input:
    /// drawn in `buildChrome`, outside the row cache.
    public var highlightedRows: Range<Int>?
    /// Which visible rows changed since the frame before, indexed like `lines`; this is `Row.dirty`
    /// carried across the module boundary.
    ///
    /// Empty means "assume every row changed", which is what a caller that tracks nothing gets, and
    /// what the view itself sends whenever the rows moved under their slots -- a scrolled-back
    /// viewport, a fold opening -- because then slot *y* no longer holds the row it held last frame
    /// and the flag on the row says nothing about the slot.
    public var dirtyRows: [Bool]

    public init(cols: Int, rows: Int, lines: [Row], graphemes: [String], palette: Palette,
                cursor: Cursor?, cursorShape: CursorShape, focused: Bool, preedit: String?,
                selection: [Range<Int>?] = [], searchMatches: [[Range<Int>]] = [],
                currentSearchMatch: [Range<Int>?] = [], hoveredLink: [Range<Int>?] = [],
                rowNotes: [String?] = [],
                blockSpines: [(rows: Range<Int>, color: RGB)] = [],
                blockSummaries: [(row: Int, text: String, color: RGB)] = [],
                highlightedRows: Range<Int>? = nil,
                dirtyRows: [Bool] = []) {
        self.cols = cols; self.rows = rows; self.lines = lines; self.graphemes = graphemes; self.palette = palette
        self.cursor = cursor; self.cursorShape = cursorShape; self.focused = focused; self.preedit = preedit
        self.selection = selection
        self.searchMatches = searchMatches
        self.currentSearchMatch = currentSearchMatch
        self.rowNotes = rowNotes
        self.blockSpines = blockSpines
        self.blockSummaries = blockSummaries
        self.highlightedRows = highlightedRows
        self.hoveredLink = hoveredLink
        self.dirtyRows = dirtyRows
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

/// What became of a frame handed to the renderer.
public enum FramePresentation: Equatable {
    /// Drawn, and on its way to the screen.
    case presented
    /// Withheld: the application is in the middle of a synchronised update (DECSET 2026). The
    /// caller must keep the frame marked stale -- the content it describes has not been shown.
    case held
    /// The layer had no drawable to hand out. Transient, and the caller retries next tick.
    case noDrawable
}

/// How much of the last frames the renderer actually had to rebuild.
///
/// The per-row cache is a CPU optimisation with no visible effect, which is exactly the kind of
/// claim that goes unchecked. These counters are what a test (and `NYX_RENDER_STATS=1` in the app)
/// asserts on, so "only the changed rows are re-shaped" is a measurement rather than an intention.
public struct RenderStats: Equatable {
    public var frames = 0
    /// Visible rows the renderer walked, summed over `frames`.
    public var rowsSeen = 0
    /// Of those, the ones whose instances had to be built again.
    public var rowsRebuilt = 0
    /// Frames that threw the whole cache away: geometry, palette, focus or the glyph atlas changed.
    public var fullInvalidations = 0
    public init() {}
}

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
    private var rowCache: [RowSlot] = []
    private var frameKey: FrameKey?
    private var syncGate = SyncOutputGate()
    public private(set) var stats = RenderStats()

    /// How long a synchronised update may hold the screen. Settable so a test can drive the timeout
    /// without waiting on it.
    public var syncOutputTimeout: TimeInterval {
        get { syncGate.timeout }
        set { syncGate.timeout = newValue }
    }

    public func resetStats() { stats = RenderStats() }

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

    /// Whether a frame may be put on screen at all right now, asked *before* one is built.
    ///
    /// A held frame is thrown away, and building one walks the grid, the blocks and the marks under
    /// the session lock. The view asks first so a synchronised update costs nothing rather than
    /// costing a frame's work per tick.
    public func canPresent(syncOutput: Bool, now: TimeInterval = CACurrentMediaTime()) -> Bool {
        syncGate.shouldPresent(syncOutput: syncOutput, now: now)
    }

    /// Draws `frame` into the layer's next drawable, unless the application is mid-update.
    ///
    /// `.noDrawable` and `.held` both mean nothing reached the screen, so the caller keeps the frame
    /// marked stale and tries again on the next tick instead of leaving stale pixels up -- and,
    /// since the per-row cache clears `Row.dirty` only on `.presented`, keeps the rows that were
    /// not shown eligible for rebuilding.
    @discardableResult
    public func draw(_ frame: RenderFrame, in layer: CAMetalLayer, padding: Int,
                     syncOutput: Bool = false, now: TimeInterval = CACurrentMediaTime()) -> FramePresentation {
        guard canPresent(syncOutput: syncOutput, now: now) else { return .held }
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return .noDrawable }
        render(frame, to: drawable.texture, commandBuffer: cb, padding: padding)
        cb.present(drawable)
        cb.commit()
        return .presented
    }

    /// The same decision against an offscreen texture: the pixels stop changing while the
    /// application is mid-update. Tests render through this to look at what a reader would see.
    @discardableResult
    public func draw(_ frame: RenderFrame, to texture: MTLTexture, commandBuffer: MTLCommandBuffer,
                     padding: Int, syncOutput: Bool, now: TimeInterval) -> FramePresentation {
        guard canPresent(syncOutput: syncOutput, now: now) else { return .held }
        render(frame, to: texture, commandBuffer: commandBuffer, padding: padding)
        return .presented
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

    // MARK: - Per-row cache
    //
    // §3 of the design promises per-row partial redraw. `Row.dirty` was already maintained on every
    // mutation; what was missing was a consumer. This is it: a row whose cells did not change, and
    // whose highlights and cursor did not change either, keeps the instances built for it last
    // frame instead of being shaped again.
    //
    // What that saves is CPU, not GPU: Metal still draws the whole frame from one buffer in one
    // pass, and it must -- there is a single drawable and a clear on every frame. The work skipped
    // is the per-cell work in `buildRow`, which is the expensive half: two palette resolutions per
    // cell, a `GlyphKey` hashed into the atlas dictionary per glyph, and the quads themselves. On a
    // shell sitting at a prompt with a spinner going, that is every row but one, sixty times a
    // second, on the main thread, in front of the PTY reader waiting for the session lock.

    /// Everything outside the row's own cells that decides how the row is drawn.
    ///
    /// Kept separate from `Row.dirty` because none of it mutates a cell: moving the cursor, dragging
    /// a selection or stepping to the next search hit changes what a row looks like without the
    /// terminal touching it, so a cache keyed only on the dirty flag would leave the old cursor
    /// block painted on the row it left.
    private struct RowKey: Equatable {
        var selection: Range<Int>?
        var currentMatch: Range<Int>?
        var matches: [Range<Int>] = []
        var hoveredLink: Range<Int>?
        var cursorColumn: Int?
    }

    /// One visible row's instances, in the three buckets the frame is assembled from.
    private struct RowSlot {
        var key = RowKey()
        var backgrounds: [Instance] = []
        var glyphs: [Instance] = []
        var decorations: [Instance] = []
        var valid = false
    }

    /// Frame-wide state that changes how *every* row is drawn. A change here empties the cache
    /// rather than trying to work out which rows it touched -- it touched all of them.
    ///
    /// The atlas generation is in here for a reason that is invisible until it bites: when the atlas
    /// fills it repacks from scratch, and every cached quad's texture coordinates then point at
    /// whatever moved into those texels.
    private struct FrameKey: Equatable {
        var cols: Int
        var rows: Int
        var padding: Int
        var palette: Palette
        var focused: Bool
        var cursorShape: CursorShape
        var metrics: CellMetrics
        var atlasGeneration: Int
    }

    /// Palette lookups shared by every row of one frame. Each walks the palette for the blend that
    /// satisfies its contrast rule: nothing at all sixty times a second, absurd two million times.
    private struct FrameColors {
        var matchBackground: RGB
        var currentMatchBackground: RGB
        var matchForeground: RGB
        var noteForeground: RGB
        /// The hovered block's tint. Derived with a search through the palette for a blend that
        /// clears three contrast floors at once, so it belongs with the other once-per-frame
        /// lookups rather than being recomputed inside `buildChrome` on every hovered frame.
        var blockHover: RGB
    }

    private func buildInstances(_ f: RenderFrame, padding: Int) {
        for _ in 0..<2 {
            let gen = atlas.generation
            assemble(f, padding: padding)
            // A glyph rasterised during the pass above can have filled the atlas and repacked it,
            // which moves every glyph already placed. The second pass sees the new generation in
            // the frame key, drops the cache and rebuilds every row against the new layout.
            if atlas.generation == gen { break }
        }
        instances.append(contentsOf: glyphs)
        instances.append(contentsOf: decorations)
    }

    private func assemble(_ f: RenderFrame, padding: Int) {
        instances.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        decorations.removeAll(keepingCapacity: true)

        let visible = min(f.rows, f.lines.count)
        let key = FrameKey(cols: f.cols, rows: f.rows, padding: padding, palette: f.palette,
                           focused: f.focused, cursorShape: f.cursorShape,
                           metrics: fonts.metrics, atlasGeneration: atlas.generation)
        if key != frameKey || rowCache.count != visible {
            frameKey = key
            rowCache = Array(repeating: RowSlot(), count: visible)
            stats.fullInvalidations += 1
        }
        let colors = FrameColors(matchBackground: f.palette.searchMatchBackground,
                                 currentMatchBackground: f.palette.currentMatchBackground,
                                 matchForeground: f.palette.searchMatchForeground,
                                 noteForeground: f.palette.noteForeground,
                                 blockHover: f.palette.blockHoverBackground)
        stats.frames += 1
        stats.rowsSeen += visible

        for y in 0..<visible {
            let rowKey = RowKey(selection: y < f.selection.count ? f.selection[y] : nil,
                                currentMatch: y < f.currentSearchMatch.count ? f.currentSearchMatch[y] : nil,
                                matches: y < f.searchMatches.count ? f.searchMatches[y] : [],
                                hoveredLink: y < f.hoveredLink.count ? f.hoveredLink[y] : nil,
                                cursorColumn: f.cursor.flatMap { $0.y == y ? $0.x : nil })
            // No dirty information at all means "everything changed": a caller that does not track
            // dirt must not get a stale screen for it.
            let changed = f.dirtyRows.isEmpty || y >= f.dirtyRows.count || f.dirtyRows[y]
            if changed || !rowCache[y].valid || rowCache[y].key != rowKey {
                buildRow(f, y: y, padding: padding, colors: colors, into: &rowCache[y])
                rowCache[y].key = rowKey
                rowCache[y].valid = true
                stats.rowsRebuilt += 1
            }
            instances.append(contentsOf: rowCache[y].backgrounds)
            glyphs.append(contentsOf: rowCache[y].glyphs)
            decorations.append(contentsOf: rowCache[y].decorations)
        }

        buildChrome(f, padding: padding, colors: colors)
    }

    /// Shapes one visible row into `slot`. Everything here is a function of the row's cells, the
    /// row key and the frame key -- which is what makes the cache above sound.
    private func buildRow(_ f: RenderFrame, y: Int, padding: Int, colors: FrameColors, into slot: inout RowSlot) {
        let m = fonts.metrics
        let cw = Float(m.width), ch = Float(m.height), thick = Float(m.thickness)
        slot.backgrounds.removeAll(keepingCapacity: true)
        slot.glyphs.removeAll(keepingCapacity: true)
        slot.decorations.removeAll(keepingCapacity: true)

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
                bg = isCurrentMatch ? colors.currentMatchBackground : colors.matchBackground
                if isCurrentMatch { fg = colors.matchForeground }
            }

            let blockCursor = isCursor && f.focused && f.cursorShape == .block
            if blockCursor { bg = f.palette.cursor; fg = f.palette.background }
            if bg != f.palette.background || blockCursor || selected || isMatch {
                slot.backgrounds.append(rect(px, py, w, ch, bg))
            }

            if c.content != 0, !c.attrs.contains(.hidden) {
                let text: GlyphText = c.graphemeIndex.map { .cluster(f.graphemes[$0]) } ?? .scalar(c.content)
                let key = GlyphKey(text: text, bold: c.attrs.contains(.bold), italic: c.attrs.contains(.italic))
                if let g = atlas.glyph(for: key) {
                    slot.glyphs.append(glyphQuad(g, cellX: px, cellY: py, color: fg))
                }
            }

            let ulY = py + Float(m.underlineY)
            let ulColor = c.ul.kind == .default ? fg : f.palette.resolve(c.ul, isForeground: true)
            switch c.underline {
            case .none: break
            case .single: slot.decorations.append(rect(px, ulY, w, thick, ulColor))
            case .double:
                slot.decorations.append(rect(px, ulY - thick, w, thick, ulColor))
                slot.decorations.append(rect(px, ulY + thick, w, thick, ulColor))
            case .curly: slot.decorations.append(rect(px, ulY - thick, w, thick * 3, ulColor, kind: 3))
            case .dotted: slot.decorations.append(rect(px, ulY, w, thick, ulColor, kind: 4))
            case .dashed: slot.decorations.append(rect(px, ulY, w, thick, ulColor, kind: 5))
            }
            if c.attrs.contains(.strike) {
                slot.decorations.append(rect(px, py + Float(m.strikeY), w, thick, fg))
            }
            // A hovered link is underlined in the text's own colour, on the same baseline
            // the SGR underlines use, so a link that is already underlined does not gain a
            // second line in a different place.
            if y < f.hoveredLink.count, f.hoveredLink[y]?.contains(x) ?? false, c.underline == .none {
                slot.decorations.append(rect(px, ulY, w, thick, fg))
            }

            if isCursor {
                let cc = f.palette.cursor
                if !f.focused {
                    slot.decorations.append(rect(px, py, w, thick, cc))
                    slot.decorations.append(rect(px, py + ch - thick, w, thick, cc))
                    slot.decorations.append(rect(px, py, thick, ch, cc))
                    slot.decorations.append(rect(px + w - thick, py, thick, ch, cc))
                } else if f.cursorShape == .bar {
                    slot.decorations.append(rect(px, py, thick, ch, cc))
                } else if f.cursorShape == .underline {
                    slot.decorations.append(rect(px, py + ch - thick * 2, w, thick * 2, cc))
                }
            }
        }
    }

    /// Everything drawn beside the grid rather than in it: spines, summaries, notes, preedit.
    ///
    /// Deliberately outside the row cache. It is a handful of instances on a handful of rows, it is
    /// driven by state the view recomputes each frame anyway, and keeping it out means the cache
    /// key stays small enough to compare honestly.
    private func buildChrome(_ f: RenderFrame, padding: Int, colors: FrameColors) {
        let m = fonts.metrics
        let cw = Float(m.width), ch = Float(m.height)
        // The hovered block's tint: one translucent rect across the grid's width, outside the row
        // cache (nothing per row changed). Inserted at the front of the background bucket, not
        // appended -- `instances` already holds every row's backgrounds by the time chrome runs
        // (the per-row loop in `assemble` ran first), and painting is last-instance-wins. A cell
        // with the theme's own background emits no instance at all (`buildRow` only appends for a
        // non-default background, a selection, a match or a block cursor), so those cells still
        // show the tint underneath; a selected or matched or coloured cell paints over it and stays
        // visible, which is the whole point of a tint that is chrome and not a cell.
        if let rows = f.highlightedRows, !rows.isEmpty {
            let top = Float(padding + max(0, rows.lowerBound) * m.height)
            let height = Float(min(rows.count, f.rows - max(0, rows.lowerBound)) * m.height)
            let width = Float(f.cols * m.width)
            let tint = rect(Float(padding), top, width, height, colors.blockHover)
            instances.insert(tint, at: 0)
        }

        // A command's spine, drawn in the left padding: it says "these rows belong together"
        // without taking a column of text or touching a cell. Nothing about the grid changes,
        // which is what lets vim and htop keep behaving exactly as they did.
        for spine in f.blockSpines {
            guard !spine.rows.isEmpty else { continue }
            let top = Float(padding + spine.rows.lowerBound * m.height)
            let height = Float(spine.rows.count * m.height)
            // The head of this shape is the gutter's cap, drawn by AppKit at the same x and the
            // same width: `CommandBlockChrome` owns both numbers, so a green line with beads on it
            // 1.5 pt apart cannot come back. At `padding = 0` the inset is 0 and the spine takes
            // the first text column's leading 3 pt rather than not being drawn at all -- a block
            // with no spine is a block with no left edge (Addendum 2). The old
            // `guard padding >= 4 else { continue }` goes with this: a block with no left edge is
            // not a quieter block, it is a block with no left edge.
            //
            // In points, then back to pixels: `padding` arrives in *device pixels* (`Pane` passes
            // `padding * contentsScale`), and `spineWidth`/`spineLeadingInset` are the same points
            // the AppKit cap is drawn in. Used raw they made the spine 1.5 pt wide at 2 pt beside a
            // 3 pt cap at 4 pt on every Retina Mac -- the two marks drifting apart again, which is
            // the one thing these two numbers exist to prevent.
            let scale = Float(fonts.scale)
            let inset = CommandBlockChrome.spineLeadingInset(padding: Double(padding) / Double(scale))
            let x = Float(inset) * scale
            instances.append(rect(x, top, Float(CommandBlockChrome.spineWidth) * scale, height,
                                  spine.color))
        }

        // A block's summary, right-aligned on its command row and in the block's own colour --
        // so `exit 1` is read as a failure before it is read as words.
        for summary in f.blockSummaries {
            let characters = Array(summary.text)
            guard summary.row >= 0, summary.row < f.rows else { continue }
            let row = summary.row < f.lines.count ? f.lines[summary.row] : nil
            let lastUsed = row.map { line -> Int in
                var last = -1
                for (column, cell) in line.cells.enumerated() where cell.content != 0 { last = column }
                return last
            } ?? -1
            // Never over the command it describes: a summary that overwrites the end of a long
            // command line has destroyed the more important of the two. `summaryColumns` is the one
            // place that rule lives, so the pane's click target can never disagree with what is
            // actually drawn.
            guard let columns = CommandBlockChrome.summaryColumns(textCount: characters.count, cols: f.cols,
                                                                  lastUsedColumn: lastUsed) else { continue }
            for (offset, character) in characters.enumerated() {
                let px = Float(padding + (columns.lowerBound + offset) * m.width)
                let py = Float(padding + summary.row * m.height)
                let text = String(character)
                let glyphText: GlyphText = text.unicodeScalars.count == 1
                    ? .scalar(text.unicodeScalars.first!.value) : .cluster(text)
                if let g = atlas.glyph(for: GlyphKey(text: glyphText, bold: false, italic: false)) {
                    glyphs.append(glyphQuad(g, cellX: px, cellY: py, color: summary.color))
                }
            }
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
                    glyphs.append(glyphQuad(g, cellX: px, cellY: py, color: colors.noteForeground))
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
    }
}
