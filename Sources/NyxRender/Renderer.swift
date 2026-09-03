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

    public init(cols: Int, rows: Int, lines: [Row], graphemes: [String], palette: Palette,
                cursor: Cursor?, cursorShape: CursorShape, focused: Bool, preedit: String?) {
        self.cols = cols; self.rows = rows; self.lines = lines; self.graphemes = graphemes; self.palette = palette
        self.cursor = cursor; self.cursorShape = cursorShape; self.focused = focused; self.preedit = preedit
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

    public func draw(_ frame: RenderFrame, in layer: CAMetalLayer, padding: Int) {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        render(frame, to: drawable.texture, commandBuffer: cb, padding: padding)
        cb.present(drawable)
        cb.commit()
    }

    public func render(_ frame: RenderFrame, to texture: MTLTexture, commandBuffer: MTLCommandBuffer, padding: Int) {
        buildInstances(frame, padding: padding)
        let bytes = max(instances.count * MemoryLayout<Instance>.stride, 64)
        if instanceBuffer == nil || instanceBuffer!.length < bytes {
            instanceBuffer = device.makeBuffer(length: bytes * 2, options: .storageModeShared)
        }
        if !instances.isEmpty {
            instances.withUnsafeBytes { memcpy(instanceBuffer!.contents(), $0.baseAddress!, $0.count) }
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

                    let blockCursor = isCursor && f.focused && f.cursorShape == .block
                    if blockCursor { bg = f.palette.cursor; fg = f.palette.background }
                    if bg != f.palette.background || blockCursor {
                        instances.append(rect(px, py, w, ch, bg))
                    }

                    if c.content != 0, !c.attrs.contains(.hidden) {
                        let text: GlyphText = c.graphemeIndex.map { .cluster(f.graphemes[$0]) } ?? .scalar(c.content)
                        let key = GlyphKey(text: text, bold: c.attrs.contains(.bold), italic: c.attrs.contains(.italic))
                        if let g = atlas.glyph(for: key) {
                            glyphs.append(Instance(pos: SIMD2(px + Float(g.left), py + Float(g.top)),
                                                   size: SIMD2(Float(g.width), Float(g.height)),
                                                   uv0: SIMD2(Float(g.x), Float(g.y)),
                                                   uv1: SIMD2(Float(g.x + g.width), Float(g.y + g.height)),
                                                   color: rgba(fg), kind: g.isColor ? 2 : 1))
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
                        glyphs.append(Instance(pos: SIMD2(px + Float(g.left), py + Float(g.top)),
                                               size: SIMD2(Float(g.width), Float(g.height)),
                                               uv0: SIMD2(Float(g.x), Float(g.y)),
                                               uv1: SIMD2(Float(g.x + g.width), Float(g.y + g.height)),
                                               color: rgba(f.palette.background), kind: g.isColor ? 2 : 1))
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
