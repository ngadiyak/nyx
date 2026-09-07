import AppKit
import Metal
import NyxCore
import NyxRender

/// The chrome as it is actually seen: drawn over a real terminal grid.
///
/// `UISnapshot` renders each view alone against a flat palette fill, and `Tests/NyxRenderTests`
/// renders the Metal grid with no AppKit view anywhere near it. Between the two, nothing had ever
/// pictured the hover strip, the sticky strip, the gutter, the block tint and spine, the lens field,
/// the search bar or a banner *over the text they sit on* -- which is the only place a person ever
/// sees any of them. Every judgement about that chrome (does the strip's fade eat the command, is
/// the dot beside the row it describes, can the filter box be read over a lensed response) was
/// therefore being made against a picture nobody gets.
///
/// So: a real `Terminal` -- OSC 133 marks, a folded block, a lensed block, wrapped rows, wide cells
/// -- goes through `Terminal.displayRows` into a `RenderFrame`, the offscreen `Renderer` draws it
/// into a texture, and the AppKit chrome is composited over that image at the placement the pane's
/// own rules choose: `CommandBlockChrome.stripPlacement` and `summaryPlacement` for the strip and
/// the summary, `PromptGutter.hitWidth` and the cell height for the gutter, and the same
/// `bounds.height - padding - (row + 1) * cell` arithmetic `Pane.overlayOrigin` uses for everything
/// pinned to a row.
///
/// **Why it lives in NyxApp.** The alternative was a case in `NyxRenderTests` linking the AppKit
/// views, which would put the tab bar and the hover strip on `NyxRender`'s side of the module rule.
/// NyxApp already depends on NyxRender, so composing here costs no new dependency in either
/// direction and `NyxRender` stays ignorant of chrome. It runs in the same `NYX_UI_SNAPSHOT` pass
/// as everything else, so one command produces the whole picture set.
///
/// **What it is not.** It is not `Pane.render`. The pane's frame pass also does selection, links,
/// notes, IME and the watch drain; this builds the parts the chrome is judged against and calls the
/// *same NyxCore rules* for every placement, so a rule that changes moves both. Anything the pane
/// decides in AppKit and this does not (which control the pointer is over, when a field is
/// dismissed) is set explicitly by each case rather than guessed at.
enum GridSnapshot {
    /// Every composite, into `directory`. Named `<case>-<palette>-<appearance>`, because the two
    /// dimensions are independent: a view that paints from the palette must look the same under
    /// both appearances (a differing pair is the Light-Mode bug coming back), and one that lets
    /// AppKit paint any part of itself must be looked at under both.
    static func run(into directory: URL, config: Config) {
        let palettes = [("nyx-dark", Themes.builtin["nyx-dark"] ?? Palette.xtermDefault()),
                        ("nyx-light", Themes.builtin["nyx-light"] ?? Palette.xtermDefault())]
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (paletteName, palette) in palettes {
            guard let canvas = GridCanvas(cols: 84, rows: 20, config: config) else { continue }
            for (appearanceName, appearance) in appearances {
                let suffix = "\(paletteName)-\(appearanceName)"
                // One picture per width class, at `.finished`. Task 8 loops the nine states of
                // §2.6's table over them; the names are what plan 1b's `cmp` compares.
                for width in GridScene.widthClasses {
                    write(canvas: canvas, palette: palette, appearance: appearance,
                          case: .hoverStrip(width, .finished), into: directory,
                          named: "composite-strip-\(name(of: width))-finished-\(suffix)")
                }
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .hoverStrip(.w3, .lensed), into: directory,
                      named: "composite-strip-lens-\(suffix)")
                // The timeline's own width and its `+N` cap: three run counts, because one cell of
                // the state matrix cannot say what thirty circles do to a strip's width.
                for runs in [4, 30, 48] {
                    write(canvas: canvas, palette: palette, appearance: appearance,
                          case: .hoverStripWatching(runs: runs), into: directory,
                          named: "composite-strip-watch-\(runs)-runs-\(suffix)")
                }
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .sticky, into: directory, named: "composite-sticky-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .gutter, into: directory, named: "composite-gutter-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .gutterStates, into: directory,
                      named: "composite-gutter-states-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .lensField(.filter(".users[] | .name")), into: directory,
                      named: "composite-lens-field-\(suffix)")
                // The two lens answers that are a sentence rather than a document, over the field
                // that produced them: a path that matched nothing, and a `.pretty` on a body that
                // is not JSON. Both are one dim line in the grid, and a dim line is exactly what
                // an unreadable one looks like.
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .lensField(.filter(".nothing[] | .here")), into: directory,
                      named: "composite-lens-no-results-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .lensOnHTML(.pretty), into: directory,
                      named: "composite-lens-pretty-not-json-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .lens(.body), into: directory, named: "composite-lens-body-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .search("connection refused"), into: directory,
                      named: "composite-search-\(suffix)")
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .search("zzzznothing"), into: directory,
                      named: "composite-search-no-matches-\(suffix)")
                for kind in BannerKind.allCases {
                    write(canvas: canvas, palette: palette, appearance: appearance,
                          case: .banner(kind), into: directory,
                          named: "composite-banner-\(kind.rawValue)-\(suffix)")
                }
                write(canvas: canvas, palette: palette, appearance: appearance,
                      case: .tui, into: directory, named: "composite-tui-\(suffix)")
            }
        }

        // The two settings that change the shape of every row, at the ends of their ranges. The
        // chrome is placed from `cellSizePoints`, `PromptGutter.hitWidth` and
        // `CommandBlockChrome.spineLeadingInset`, and those have only ever been pictured at their
        // defaults -- so nothing said what a 12 pt row does to a 20 pt pill, or where the mark and
        // the spine land when the padding they used to live in is gone.
        let dark = Themes.builtin["nyx-dark"] ?? Palette.xtermDefault()
        for (label, change) in [("line-height-08", { (c: inout Config) in c.lineHeight = 0.8 }),
                                ("padding-0", { (c: inout Config) in c.padding = 0 })] {
            var tweaked = config
            change(&tweaked)
            guard let canvas = GridCanvas(cols: 84, rows: 20, config: tweaked) else { continue }
            for (name, kind) in [("strip", Case.hoverStrip(.w3, .finished)), ("gutter", Case.gutter)] {
                write(canvas: canvas, palette: dark, appearance: .darkAqua, case: kind,
                      into: directory, named: "composite-\(label)-\(name)-nyx-dark-dark")
            }
        }
    }

    /// Exactly `w3`, `w2`, `w1`, `w0`: §8.5's picture names and plan 1b's `cmp` both spell the
    /// composites `composite-strip-w3-finished-*`, and a prettier word here renames the set.
    private static func name(of width: CommandBlockChrome.WidthClass) -> String {
        switch width {
        case .w3: return "w3"
        case .w2: return "w2"
        case .w1: return "w1"
        case .w0: return "w0"
        }
    }

    /// Which banner a composite shows. All three, because a banner is the one piece of chrome that
    /// only ever appears when something has gone wrong, and the state nobody renders is the state
    /// nobody has looked at.
    enum BannerKind: String, CaseIterable {
        case problems, note, failure
    }

    /// What a composite is a picture of. Each case says which chrome is up and what the pane is
    /// showing under it; the placement is never in here -- that comes from NyxCore.
    enum Case {
        /// The hover strip at one width class, in one of §2.6's states, over a command row that
        /// leaves exactly that much room. The command line's length is computed from the view's own
        /// measured width, so the picture is of `stripPlacement` choosing this class rather than of
        /// it being told to.
        case hoverStrip(CommandBlockChrome.WidthClass, GridScene.StripState)
        /// The strip on a *watched* request, after `runs` runs. The timeline is the widest thing
        /// this chrome can hold, and measuring it alone says nothing about whether a pane has room
        /// for it -- which is what these pictures are for.
        case hoverStripWatching(runs: Int)
        /// Scrolled deep into a long build, so the command that produced it is pinned at the top.
        case sticky
        /// The four gutter marks beside the rows they belong to, nothing else up.
        case gutter
        /// The same, with a command that finished silently and one still running appended: the
        /// `.faded` cap and the `.hollow` ring, each at the head of its own spine.
        case gutterStates
        /// A lens on the request, with the field that types into it over the command row.
        case lensField(ResponseLens)
        /// A lens on the request with no field: what the response reads as through it.
        case lens(ResponseLens)
        /// A lens on a request whose body is HTML.
        case lensOnHTML(ResponseLens)
        /// The search bar over the grid, with the query's hits highlighted in the text under it.
        case search(String)
        case banner(BannerKind)
        /// A full-screen program owning the display. `CommandBlockChrome.isAllowed` is false on the
        /// alternate screen, so every piece of block chrome must step aside -- the rule that keeps
        /// vim, htop and tmux behaving exactly as they did, and the one Warp's blocks do not have.
        case tui
    }

    private static func write(canvas: GridCanvas, palette: Palette, appearance: NSAppearance.Name,
                              case kind: Case, into directory: URL, named name: String) {
        var scene = GridScene(canvas: canvas, palette: palette)
        var chrome: [NSView] = []
        var band: NSView?

        switch kind {
        case .hoverStrip(let width, let state):
            if state == .lensed {
                scene.applyLens(.pretty, toRequest: true)
                scene.hovered = scene.requestID
            } else {
                scene.hovered = scene.commandFitting(width)
            }
        case .hoverStripWatching(let runs):
            scene.watch = GridScene.watchHeader(runs: runs)
            scene.showRequestBlock()
            scene.hovered = scene.requestID
        case .sticky:
            scene.scrollIntoBuild()
        case .gutter:
            break
        case .gutterStates:
            scene.showRunningAndSilentCommands()
        case .lensField(let lens):
            scene.applyLens(lens, toRequest: true)
            scene.showsLensField = true
        case .lens(let lens):
            scene.applyLens(lens, toRequest: true)
        case .lensOnHTML(let lens):
            scene.htmlBody = true
            scene.applyLens(lens, toRequest: true)
        case .search(let query):
            scene.search(query)
        case .banner:
            break
        case .tui:
            scene.enterTUI()
        }

        let built = scene.build()
        guard let image = canvas.grid(built.frame) else { return }

        // The gutter is in every picture, because it is in every pane: chrome judged without it
        // beside it is chrome judged an inch to the left of where it is.
        if let gutter = canvas.gutter(built, palette: palette, appearance: appearance) {
            chrome.append(gutter)
        }
        if let strip = canvas.stickyStrip(built, palette: palette, appearance: appearance) {
            chrome.append(strip)
        }
        if let header = canvas.hoverStrip(built, palette: palette, appearance: appearance,
                                          config: canvas.config) {
            chrome.append(header)
        }
        if scene.showsLensField, let field = canvas.lensField(built, palette: palette,
                                                              appearance: appearance) {
            chrome.append(field)
        }
        if case .search = kind, let bar = canvas.searchBar(built, palette: palette,
                                                           appearance: appearance) {
            chrome.append(bar)
        }
        if case .banner(let bannerKind) = kind {
            band = canvas.banner(bannerKind, appearance: appearance)
        }
        canvas.write(image, chrome: chrome, band: band, named: name, into: directory,
                     background: palette.background)
    }
}

// MARK: - The offscreen pane

/// One offscreen pane: a Metal renderer, a texture the size a pane of this many cells would be, and
/// the point geometry that pane's chrome would be laid out in.
///
/// Every measurement here is the pane's own: `cell` is `Pane.cellSizePoints`, `bounds` is what
/// `Pane.size(forCols:rows:)` gives, and the padding is the config's, so the mark inside the gutter
/// lands where `CommandBlockChrome.spineLeadingInset` puts it at that padding rather than at a
/// number picked for the picture.
struct GridCanvas {
    let config: Config
    let fonts: FontSet
    let renderer: Renderer
    let texture: MTLTexture
    let cols: Int
    let rows: Int
    /// Backing scale. Two, like every Mac this ships on and like `UISnapshot.write`, so the
    /// composite's pixels and the chrome's pixels are the same size.
    static let scale: CGFloat = 2

    init?(cols: Int, rows: Int, config: Config) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.config = config
        self.cols = cols
        self.rows = rows
        // Built exactly as `Pane` builds it, including the system-monospaced base font, so the cell
        // the chrome is placed against is the cell the user's pane has.
        fonts = FontSet(family: config.fontFamily, pointSize: CGFloat(config.fontSize),
                        scale: GridCanvas.scale, lineHeight: CGFloat(config.lineHeight),
                        baseFont: Pane.systemMonospacedFont(for: config.fontFamily))
        guard let renderer = try? Renderer(device: device, fonts: fonts) else { return nil }
        self.renderer = renderer
        let pixelWidth = fonts.metrics.width * cols + Int(config.padding * Double(GridCanvas.scale)) * 2
        let pixelHeight = fonts.metrics.height * rows + Int(config.padding * Double(GridCanvas.scale)) * 2
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: pixelWidth,
                                                                  height: pixelHeight,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        self.texture = texture
    }

    var padding: CGFloat { CGFloat(config.padding) }
    /// `Pane.cellSizePoints`.
    var cell: NSSize {
        NSSize(width: CGFloat(fonts.metrics.width) / GridCanvas.scale,
               height: CGFloat(fonts.metrics.height) / GridCanvas.scale)
    }
    /// What `Pane.bounds` would be at this size: the chrome's coordinate space, unflipped, exactly
    /// as AppKit hands it to the views.
    var bounds: NSRect {
        NSRect(x: 0, y: 0,
               width: cell.width * CGFloat(cols) + padding * 2,
               height: cell.height * CGFloat(rows) + padding * 2)
    }

    /// `Pane.overlayOrigin(forHeaderRow:)`: the top-right corner of a visible row.
    func overlayOrigin(forHeaderRow row: Int) -> NSPoint {
        NSPoint(x: bounds.width - padding,
                y: bounds.height - padding - CGFloat(row + 1) * cell.height)
    }

    /// The grid, drawn by the real renderer and read back.
    func grid(_ frame: RenderFrame) -> CGImage? {
        guard let commands = renderer.queue.makeCommandBuffer() else { return nil }
        renderer.render(frame, to: texture, commandBuffer: commands,
                        padding: Int(padding * GridCanvas.scale))
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Grid first, then every chrome view at its own frame, then the PNG.
    ///
    /// `band` is drawn *above* the grid rather than over it, at the full width, because that is
    /// where the window puts it: `TerminalWindowController` pins the config banner to the top of
    /// the container and constrains the pane below it, so a banner composited over the text would
    /// picture a layout that cannot happen.
    func write(_ image: CGImage, chrome: [NSView], band: NSView?, named name: String,
               into directory: URL, background: RGB) {
        let scale = GridCanvas.scale
        let bandHeight = band?.bounds.height ?? 0
        let pointWidth = bounds.width
        let pointHeight = bounds.height + bandHeight
        let pixelWidth = Int(pointWidth * scale)
        let pixelHeight = Int(pointHeight * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.setFillColor(red: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255,
                             blue: CGFloat(background.b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        // The grid sits under the band, in an unflipped context whose origin is bottom left -- the
        // same space AppKit gives a view -- so a chrome frame can be drawn at its own coordinates.
        context.draw(image, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        for view in chrome { draw(view, at: view.frame, in: context) }
        if let band {
            draw(band, at: NSRect(x: 0, y: bounds.height, width: bounds.width, height: bandHeight),
                 in: context)
        }
        guard let composed = context.makeImage() else { return }
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString,
                                                                1, nil) else { return }
        CGImageDestinationAddImage(destination, composed, nil)
        CGImageDestinationFinalize(destination)
    }

    /// The layer's ground first, then the view over it.
    ///
    /// `cacheDisplay` alone was wrong here, and wrong in a way that made a picture accuse the wrong
    /// control. It renders the *view* -- `draw(_:)` and every subview's -- and not the **layer**, so
    /// a ground that is a `layer.backgroundColor` is simply absent from the bitmap. Over a flat fill
    /// (`UISnapshot.write`) that is invisible, because the fill is the same colour the ground would
    /// have been. Over a real grid it is not: the search bar came out with the terminal's text
    /// reading straight through it, and the design review measured 3.85:1 against a bar that
    /// `SearchBarView.apply` paints at `background @ 0.96`.
    ///
    /// In the window there is no choice to make: these views are layer-backed subviews of a pane
    /// whose own layer is a `CAMetalLayer`, and Core Animation composites their layers over it. The
    /// layer tree *is* what the user sees, so the ground is drawn from the layer -- fill, corner
    /// radius and border, plus any sublayer that is pure geometry, which is how `BlockHeaderView`'s
    /// leading fade (a `CAGradientLayer`) reaches the picture at all.
    ///
    /// Not `layer.render(in:)` for the whole thing: it re-enters the view's drawing through the
    /// layer delegate and loses what `cacheDisplay` is here for -- AppKit's own control art, the
    /// `.inline` button bezels on the hover strip and `NSTabView`'s segmented strip, which paint
    /// through CoreUI. Ground from the layer, content from `cacheDisplay`: both halves come from the
    /// path that really draws them.
    private func draw(_ view: NSView, at rect: NSRect, in context: CGContext) {
        ChromeGround.draw(view, at: rect, in: context)
    }
}

/// Draws a chrome view the way the window server does: its **layer's** ground, then the view.
///
/// Shared by both snapshot paths, because the mistake was the same in both. `UISnapshot.write`
/// draws each control on a flat fill of the terminal's background, so a missing ground is invisible
/// there whenever the ground *is* that background -- which is true of the lens field (0.97) and the
/// search bar (0.96) and false of the sticky strip (`foreground @ 0.10`) and the hover strip's
/// fade. `GridSnapshot` draws them over real text, where every one of those is visible.
enum ChromeGround {
    static func draw(_ view: NSView, at rect: NSRect, in context: CGContext) {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        if let layer = view.layer {
            context.saveGState()
            context.translateBy(x: rect.origin.x, y: rect.origin.y)
            paintGround(of: layer, in: context, size: rect.size)
            context.restoreGState()
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        context.draw(image, in: rect)
    }

    /// A layer's own painting -- background, corner radius, border, and the gradient sublayers the
    /// chrome uses for its fades -- in the layer's frame, recursively.
    ///
    /// Deliberately not a general CA renderer: it draws the properties Nyx's chrome actually sets,
    /// and nothing else. A layer that grows a shadow or a mask and is not seen in a picture is a
    /// bug in this function, which is why the list is short enough to check against the views.
    static func paintGround(of layer: CALayer, in context: CGContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: min(layer.cornerRadius, size.width / 2),
                          cornerHeight: min(layer.cornerRadius, size.height / 2), transform: nil)
        if let fill = layer.backgroundColor {
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setFillColor(fill)
            context.fill(rect)
            context.restoreGState()
        }
        if let gradient = layer as? CAGradientLayer, let colors = gradient.colors as? [CGColor],
           colors.count > 1 {
            let locations = (gradient.locations ?? []).map { CGFloat(truncating: $0) }
            let space = colors[0].colorSpace ?? CGColorSpaceCreateDeviceRGB()
            if let ramp = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                     locations: locations.count == colors.count ? locations : nil) {
                context.saveGState()
                context.addPath(path)
                context.clip()
                context.drawLinearGradient(
                    ramp,
                    start: CGPoint(x: rect.minX + gradient.startPoint.x * rect.width,
                                   y: rect.minY + gradient.startPoint.y * rect.height),
                    end: CGPoint(x: rect.minX + gradient.endPoint.x * rect.width,
                                 y: rect.minY + gradient.endPoint.y * rect.height),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
        }
        if layer.borderWidth > 0, let border = layer.borderColor {
            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(border)
            context.setLineWidth(layer.borderWidth)
            context.strokePath()
            context.restoreGState()
        }
        for sublayer in layer.sublayers ?? [] {
            // Only the layers the chrome adds itself. A layer AppKit made to back a subview is that
            // subview's business, and `cacheDisplay` is about to draw it properly.
            guard sublayer.delegate == nil else { continue }
            context.saveGState()
            context.translateBy(x: sublayer.frame.origin.x, y: sublayer.frame.origin.y)
            paintGround(of: sublayer, in: context, size: sublayer.frame.size)
            context.restoreGState()
        }
    }
}

// MARK: - The chrome, placed

extension GridCanvas {
    /// The gutter: a fixed `PromptGutter.hitWidth` column the full height of the pane, fed the caps
    /// the frame pass built from the same headers the summaries came from. Never nil now -- the
    /// gutter no longer disappears with the padding, because its mark is drawn at
    /// `spineLeadingInset` rather than inside a padding that may be zero.
    func gutter(_ built: GridScene.Built, palette: Palette,
                appearance: NSAppearance.Name) -> NSView? {
        let view = PromptGutterView(frame: NSRect(x: 0, y: 0, width: CGFloat(PromptGutter.hitWidth),
                                                  height: bounds.height))
        view.appearance = NSAppearance(named: appearance)
        _ = view.update(caps: built.gutterCaps, labels: built.gutterLabels, palette: palette,
                        cellHeight: cell.height, padding: padding, topPadding: padding)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The pinned command line, one row tall over the first row, clear of the gutter -- the frame
    /// `Pane.layoutStickyStrip` gives it.
    func stickyStrip(_ built: GridScene.Built, palette: Palette,
                     appearance: NSAppearance.Name) -> NSView? {
        guard let sticky = built.sticky else { return nil }
        let left = max(padding, CGFloat(PromptGutter.hitWidth))
        let width = max(0, bounds.width - left - padding)
        let view = StickyPromptView(frame: NSRect(x: left, y: bounds.height - padding - cell.height,
                                                  width: width, height: cell.height))
        view.appearance = NSAppearance(named: appearance)
        view.update(text: sticky.text, summary: sticky.summary, tone: sticky.tone,
                    failed: sticky.failed, palette: palette,
                    font: .monospacedSystemFont(ofSize: CGFloat(config.fontSize), weight: .regular))
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The hover strip, beginning at the column `stripPlacement` chose and running to the pane's
    /// right edge -- `Pane.blockHeaderChanged`'s frame exactly, including the height it takes from
    /// `CommandBlockChrome.stripFrameHeight` so the pills are hit-testable and unclipped.
    func hoverStrip(_ built: GridScene.Built, palette: Palette, appearance: NSAppearance.Name,
                    config: Config) -> NSView? {
        guard let placed = built.strip else { return nil }
        let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: cell.height))
        view.appearance = NSAppearance(named: appearance)
        let height = CGFloat(CommandBlockChrome.stripFrameHeight(cellHeight: Double(cell.height)))
        view.update(header: placed.header, plan: placed.plan, palette: palette,
                    font: .monospacedSystemFont(ofSize: CGFloat(config.fontSize), weight: .regular),
                    groundHeight: CGFloat(CommandBlockChrome.stripGroundHeight(cellHeight: Double(cell.height))))
        let top = bounds.height - padding - CGFloat(placed.slot + 1) * cell.height
        view.frame = NSRect(x: padding + CGFloat(placed.plan.firstColumn) * cell.width,
                            y: top - (height - cell.height) / 2,
                            width: CGFloat(cols - placed.plan.firstColumn) * cell.width,
                            height: height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// `Pane.lensFieldFrame`: 360 points wide, hung under the command row its block belongs to.
    func lensField(_ built: GridScene.Built, palette: Palette,
                   appearance: NSAppearance.Name) -> NSView? {
        guard let field = built.lensField else { return nil }
        let view = LensFieldView(frame: NSRect(x: 0, y: 0, width: 360, height: 58))
        view.appearance = NSAppearance(named: appearance)
        view.show(caption: field.caption, text: field.text, palette: palette)
        view.setMessage(field.message, offersJq: field.offersJq)
        let size = view.intrinsicContentSize
        let y = bounds.height - padding - CGFloat(field.slot + 1) * cell.height - size.height
        view.frame = NSRect(x: max(padding, bounds.width - padding - 360), y: max(padding, y),
                            width: 360, height: size.height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// `Pane.layoutSearchBar`: top right, eight points in from both edges.
    func searchBar(_ built: GridScene.Built, palette: Palette,
                   appearance: NSAppearance.Name) -> NSView? {
        guard let search = built.search else { return nil }
        let bar = SearchBarView(palette: palette)
        bar.appearance = NSAppearance(named: appearance)
        let width = min(SearchBarView.preferredWidth, max(200, bounds.width - 16))
        bar.frame = NSRect(x: bounds.width - width - 8, y: bounds.height - SearchBarView.height - 8,
                           width: width, height: SearchBarView.height)
        // Typed into, not set through a back door: the field is the control, and what it renders
        // when it holds text is the thing being looked at.
        if let field = bar.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
            field.stringValue = search.query
        }
        bar.setReadout(search.readout)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// The banner in its opened state, full width, as tall as the window gives it.
    func banner(_ kind: GridSnapshot.BannerKind, appearance: NSAppearance.Name) -> NSView {
        let banner = ConfigBanner()
        banner.appearance = NSAppearance(named: appearance)
        switch kind {
        case .problems:
            banner.showProblems([
                ConfigDiagnostic(line: 12, message: "invalid value for 'font-size': 'eighteen'"),
                ConfigDiagnostic(line: 30, message: "unknown key 'cursor-blink-rate'"),
            ])
        case .note:
            banner.showNote("The new font size applies to windows opened from now on.")
        case .failure:
            banner.showFailure("Quick action \u{201C}Deploy\u{201D} failed: ./deploy.sh: No such file or directory")
        }
        // The slide-in animates a height constraint from zero and there is no run loop here, so an
        // unopened banner renders as an empty strip -- which is why neither had been looked at
        // before `UISnapshot` started forcing the constant.
        for constraint in banner.constraints
        where constraint.firstAttribute == .height && constraint.firstItem === banner {
            constraint.constant = 32
        }
        banner.translatesAutoresizingMaskIntoConstraints = true
        banner.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        banner.layoutSubtreeIfNeeded()
        return banner
    }
}

// MARK: - The pane under the chrome

/// A terminal with a day's work in it, and the frame pass that turns it into pixels.
///
/// The fixture is deliberately not minimal: a build with a thousand rows behind it, a wrapped
/// command line, a row of CJK and emoji, a failed command, a `curl` whose response can be lensed,
/// and a prompt at the bottom. Every one of those is a case some piece of chrome gets wrong -- a
/// spine that stops at a fold, a strip placed on a row whose wide cells it miscounts, a gutter mark
/// beside the wrong line -- and a fixture of three short commands pictures none of them.
struct GridScene {
    let canvas: GridCanvas
    let palette: Palette
    let terminal: Terminal
    /// The `curl` block: the only one that can carry a lens or a `{ }`.
    let requestID: UInt32
    /// The long build, folded in every picture: a fold on screen is what makes display slots and
    /// absolute rows different numbers, which is where chrome placement goes wrong.
    let buildID: UInt32
    private let commandIDs: [CommandBlockChrome.WidthClass: UInt32]

    var folding = OutputFolding()
    var lenses = LensChoices()
    var buffers: [UInt32: LensBuffer] = [:]
    var cursor: DisplayCursor
    var hovered: UInt32?
    var showsLensField = false
    var htmlBody = false
    /// A watch on the request block, so the timeline is placed by `stripPlacement` against a real
    /// command row rather than measured in isolation.
    var watch: WatchHeader?
    /// Whether a full-screen program has taken the display. Not a flag the frame pass reads
    /// directly -- it asks `CommandBlockChrome.isAllowed`, exactly as `Pane.render` does.
    private(set) var altScreen = false
    private var searchSession = SearchSession()
    private var searchQuery = ""

    /// Everything one composite needs, in the order a `Pane` produces it.
    struct Built {
        var frame: RenderFrame
        var gutterCaps: [Int: CommandBlockChrome.GutterCap]
        var gutterLabels: [Int: String]
        var strip: (slot: Int, plan: CommandBlockChrome.StripPlan, header: BlockHeader)?
        var sticky: (text: String, summary: String, tone: SummaryTone, failed: Bool)?
        var lensField: (slot: Int, caption: String, text: String, message: String?, offersJq: Bool)?
        var search: (query: String, readout: String)?
    }

    init(canvas: GridCanvas, palette: Palette) {
        self.canvas = canvas
        self.palette = palette
        let cols = canvas.cols
        let terminal = Terminal(cols: cols, rows: canvas.rows, scrollbackLimit: 4_000)
        terminal.palette = palette
        // A fixed clock, so a duration in a picture is the same duration next week. `now` is the
        // terminal's own hook, which is what makes command timings testable at all.
        var clock = 1_000.0
        terminal.now = { clock }

        func mark(_ letter: String, _ status: Int32? = nil) -> String {
            "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
        }
        func run(_ command: String, output: [String], status: Int32, seconds: Double) -> UInt32 {
            terminal.feed(mark("A") + "$ " + mark("B") + command + "\r\n" + mark("C"))
            for line in output { terminal.feed(line + "\r\n") }
            clock += seconds
            terminal.feed(mark("D", status))
            clock += 1
            return terminal.command(containingAbsoluteRow: terminal.totalRows - 1)?.id ?? 0
        }

        _ = run("echo hello", output: ["hello"], status: 0, seconds: 0.1)
        // Twelve hundred rows, wrapped lines and wide cells among them: the block the fold and the
        // sticky strip are about.
        var buildOutput: [String] = []
        for index in 1...1_200 {
            switch index % 4 {
            case 0:
                buildOutput.append("[\(index)/1200] a message long enough that the terminal has to "
                                   + "wrap it onto a second row of the grid, which is the case a "
                                   + "display walk gets wrong")
            case 1:
                buildOutput.append("[\(index)/1200] 日本語のテキストと絵文字 \u{1F680}\u{1F525} wide cells")
            default:
                buildOutput.append("[\(index)/1200] Compiling NyxCore Terminal.swift")
            }
        }
        let build = run("swift build -c release 2>&1 | tee build.log", output: buildOutput,
                        status: 0, seconds: 42.7)
        _ = run("make lint", output: ["Sources/NyxApp/Pane.swift:2210:9: warning: unused result",
                                      "make: *** [lint] Error 1"], status: 1, seconds: 2.4)

        // One command per width class. The class is read from the *free* columns after the
        // command's last glyph, and the shell's own `$ ` is two of them: a length that forgets the
        // prompt leaves two columns too few, which is exactly enough to move a picture into the
        // next class down. Never less room than the strip actually measures, or the picture named
        // after a class would show the class below it.
        let promptColumns = 2
        var byWidth: [CommandBlockChrome.WidthClass: UInt32] = [:]
        for width in GridScene.widthClasses {
            // Exactly the band's own free columns, never `max(…, what the strip measures)`: taking
            // the wider of the two lifted a row into the class *above* the one the picture is named
            // after, so `composite-strip-w1-…` would have shown a W2 strip. A class the strip does
            // not fit is not a broken fixture -- the placement steps down, which is the picture.
            let free = GridScene.freeColumns(for: width)
            let length = max(8, cols - free - promptColumns)
            byWidth[width] = run(GridScene.commandLine(ofLength: length),
                                 output: ["ok  \(width) \u{b7} 3 files changed"],
                                 status: 0, seconds: 8.8)
        }
        commandIDs = byWidth

        let request = run("curl -sSi https://api.example.com/v1/users",
                          output: ["HTTP/2 200",
                                   "content-type: application/json; charset=utf-8",
                                   "",
                                   "{\"page\":1,\"total\":3,\"users\":[…]}"],
                          status: 0, seconds: 0.142)
        terminal.feed(mark("A") + "$ ")
        requestID = request
        buildID = build
        self.terminal = terminal
        // Folded from the start: the long build is scrollback nobody wants, and a fold on screen is
        // the condition every placement rule here has to survive.
        folding.fold(build, .all)
        cursor = terminal.displayBottomCursor(folding: folding, lenses: lenses,
                                              viewportRows: canvas.rows, buffers: { _ in nil })
    }

    /// A `curl` cut or padded to exactly `length` columns. Real text, because a row of `x`s would
    /// not show whether the strip's fade lands on a word.
    private static func commandLine(ofLength length: Int) -> String {
        let base = "curl -sS -X POST -H 'content-type: application/json' "
            + "-d '{\"service\":\"web\",\"ref\":\"main\",\"wait\":true}' "
            + "https://api.example.com/v2/deployments/organisations/acme/projects/nyx"
        if base.count >= length { return String(base.prefix(length)) }
        return base + String(repeating: " ", count: length - base.count - 1) + "."
    }

    /// Which row of section 2.6's table a composite is a picture of.
    enum StripState: String, CaseIterable {
        case finished, failed, running, folded, http, lensed
        case watchRunning = "watch-running", watchFinished = "watch-finished", noOutput = "no-output"
    }

    /// The four bands, richest first -- the order the pictures are written in.
    static let widthClasses: [CommandBlockChrome.WidthClass] = [.w3, .w2, .w1, .w0]

    /// Free columns to leave after the command's last glyph for a picture of `width`: comfortably
    /// inside each band (W3 >= 34, W2 18-33, W1 8-17, W0 < 8), never on a boundary.
    static func freeColumns(for width: CommandBlockChrome.WidthClass) -> Int {
        switch width {
        case .w3: return 40
        case .w2: return 24
        case .w1: return 12
        case .w0: return 4
        }
    }

    /// The block whose command row leaves exactly enough room for `width` and no more.
    func commandFitting(_ width: CommandBlockChrome.WidthClass) -> UInt32? { commandIDs[width] }

    /// Puts `lens` on the request and builds its buffer the way `Pane.rebuildLens` does.
    mutating func applyLens(_ lens: ResponseLens, toRequest: Bool) {
        guard toRequest else { return }
        let exchange = htmlBody ? GridScene.htmlExchange() : GridScene.jsonExchange()
        let input = LensInput(exchange: exchange, previous: nil,
                              folded: [ResponseLens.headersNode])
        guard let lines = LensRendering.lines(for: lens, input: input) else { return }
        lenses.set(lens, for: requestID)
        buffers[requestID] = LensBuffer(commandID: requestID, lens: lens, lines: lines,
                                        contentVersion: terminal.contentVersion)
        // Three rows of context above the command, not `displayBottomCursor`. A lens is usually
        // taller than the window, so the bottom of the display is somewhere in the middle of the
        // response -- with the command row off the top the block has no header, `stripPlacement`
        // is never asked, and the picture named after the strip has no strip in it.
        let promptRow = terminal.promptRow(ofCommand: requestID) ?? 0
        cursor = DisplayCursor(row: max(0, promptRow - 3))
    }

    /// Switches to the alternate screen and draws something that looks like a TUI on it.
    ///
    /// DECSET 1049 is what `vim`, `htop` and `less` send, and it is the condition
    /// `CommandBlockChrome.isAllowed` refuses on: no spines, no summaries, no gutter marks, no
    /// hover strip. Drawn with a status line and a selected row so the picture shows a program's
    /// own interface rather than an empty screen -- chrome drawn over *that* is the bug.
    mutating func enterTUI() {
        folding = OutputFolding()
        lenses = LensChoices()
        buffers = [:]
        terminal.feed("\u{1b}[?1049h\u{1b}[2J\u{1b}[H")
        terminal.feed("\u{1b}[7m  1 \u{1b}[0m import AppKit\r\n")
        terminal.feed("  2  import NyxCore\r\n  3 \r\n")
        terminal.feed("  4  /// The terminal view: a CAMetalLayer, an NSTextInputClient, and\r\n")
        terminal.feed("  5  /// every event a pane can be handed.\r\n")
        terminal.feed("  6  final class Pane: NSView {\r\n")
        terminal.feed("  7      private let renderer: Renderer\r\n")
        terminal.feed("  8      private var folding = OutputFolding()\r\n")
        terminal.feed("  9  \r\n 10      override func keyDown(with event: NSEvent) {\r\n")
        terminal.feed(" 11          guard let bytes = encoder.bytes(for: event) else { return }\r\n")
        terminal.feed(" 12          session.send(bytes)\r\n 13      }\r\n 14  }\r\n")
        for row in 15...(canvas.rows - 2) { terminal.feed("\u{1b}[34m~\u{1b}[0m  \(row)\r\n") }
        terminal.feed("\u{1b}[7m Pane.swift                          14,1        Top \u{1b}[0m")
        altScreen = true
        cursor = DisplayCursor(row: terminal.scrollback.count)
    }

    /// Puts the request block's command row on screen with room under it, for the cases whose
    /// chrome hangs off that row.
    mutating func showRequestBlock() {
        let promptRow = terminal.promptRow(ofCommand: requestID) ?? 0
        cursor = DisplayCursor(row: max(0, promptRow - 3))
    }

    /// A series of `runs` finished requests: the header a watched block would carry.
    static func watchHeader(runs: Int) -> WatchHeader {
        var series = WatchSeries(plan: WatchPlan(interval: 5, stop: .never),
                                 command: "curl -sSi https://api.example.com/v1/users", startedAt: 0)
        var clock = 0.0
        for index in 0..<max(1, runs) {
            let id = UInt32(index + 1)
            series.runStarted(id: id, at: clock)
            clock += 0.142
            series.runFinished(id: id, status: index % 4 == 3 ? 503 : 200, exitStatus: 0,
                               timeTotal: 0.1 + Double(index % 10) * 0.01, body: "", at: clock)
            clock += 5
        }
        series.runStarted(id: 9_999, at: clock)
        return series.header()
    }

    /// Scrolls into the middle of the folded build's own output, which is where a sticky strip
    /// exists at all: the command that produced what is on screen is far above it.
    /// Two more commands after everything else: one that finished having printed only a blank
    /// line, and one still running with output under it.
    ///
    /// The rest of the scene has no example of either, and they are exactly the two caps a spine
    /// drawn over the prompt row used to paint out -- `.faded`'s 40 % and `.hollow`'s ring are
    /// filled in by a bar of the same colour at the same x. `CommandBlockChrome.spineRows` keeps
    /// the prompt row for the cap; this is the picture that says so.
    mutating func showRunningAndSilentCommands() {
        func mark(_ letter: String, _ status: Int32? = nil) -> String {
            "\u{1b}]133;\(status.map { "\(letter);\($0)" } ?? letter)\u{7}"
        }
        // The scene already left a bare prompt at the bottom, so this continues it rather than
        // emitting a second `$ ` on the same row.
        terminal.feed(mark("B") + "echo\r\n" + mark("C") + "\r\n" + mark("D", 0))
        terminal.feed(mark("A") + "$ " + mark("B") + "tail -f build.log\r\n" + mark("C"))
        terminal.feed("[1201/1200] Linking Nyx\r\n[1202/1200] Signing build/Nyx.app\r\n")
        terminal.feed(mark("A") + "$ ")
        cursor = terminal.displayBottomCursor(folding: folding, lenses: lenses,
                                              viewportRows: canvas.rows, buffers: { _ in nil })
    }

    mutating func scrollIntoBuild() {
        folding = OutputFolding()
        guard let region = terminal.promptRow(ofCommand: buildID)
            .flatMap({ terminal.command(containingAbsoluteRow: $0) }),
              let start = region.outputStart else { return }
        _ = terminal.scrollToAbsoluteRow(start + 400)
        cursor = DisplayCursor(row: terminal.viewportTopRow)
    }

    /// Runs the real search session, so the readout in the bar and the highlights in the grid are
    /// one answer rather than two.
    mutating func search(_ query: String) {
        // Something to find: the failed lint command's own output carries the phrase in the
        // everyday case, and nothing carries the miss.
        terminal.feed("connection refused: api.example.com:443\r\n")
        terminal.feed("retrying, connection refused again\r\n")
        folding = OutputFolding()
        cursor = DisplayCursor(row: max(0, terminal.totalRows - canvas.rows))
        _ = terminal.scrollToAbsoluteRow(cursor.row)
        searchQuery = query
        searchSession.update(query: query, in: terminal, viewportTop: terminal.viewportTopRow)
    }

    /// The frame, and everything the chrome is placed from. A reduced `Pane.render`: same display
    /// walk, same NyxCore rules, no selection, links or IME.
    func build() -> Built {
        let cols = terminal.cols, rows = canvas.rows
        let display = terminal.displayRows(from: cursor, count: rows, folding: folding,
                                           lenses: lenses, buffers: { buffers[$0] })
        let lensPalette = LensPalette.forTheme(palette)
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
        let pad = max(0, rows - lines.count)
        lines += Array(repeating: Row(cols: cols), count: pad)

        var notes = terminal.durationNotes(onDisplayRows: display)
            + Array(repeating: nil, count: pad)

        // Which slot an absolute row landed in, through the folds and lenses this frame applied --
        // the map the text itself went through, and the only correct way to place chrome beside it.
        let slotOfRow = DisplayRows.indexByAbsoluteRow(display)
        let windowTop = max(0, cursor.row)
        let lastOnScreen = slotOfRow.keys.max() ?? (windowTop + rows - 1)
        // The same gate `Pane.render` uses: block chrome is drawn over an unmodified grid, so it
        // steps aside entirely when a full-screen program owns the display or the mouse.
        let chromeAllowed = CommandBlockChrome.isAllowed(altScreen: terminal.modes.altScreen,
                                                         mouseReporting: terminal.modes.mouse != .none,
                                                         hasMarks: terminal.shellEmitsPromptMarks)
        let blocks = chromeAllowed ? terminal.visibleBlocks(from: windowTop, through: lastOnScreen)
                                   : []

        let failedColor = palette.readable(1)
        let runningColor = palette.readable(3)
        let doneColor = palette.readable(2)
        let spines = blocks.compactMap { block -> (rows: Range<Int>, color: RGB)? in
            guard block.region.outputStart != nil else { return nil }
            guard let placed = DisplayRows.slots(coveredBy: block.visibleRows,
                                                 commandID: block.region.id, in: display,
                                                 viewportTop: windowTop),
                  let spine = CommandBlockChrome.spineRows(placed: placed,
                                                           headOnScreen: block.showsHeader)
            else { return nil }
            return (rows: spine,
                    color: block.failed ? failedColor : (block.isRunning ? runningColor : doneColor))
        }

        let overlayFont = NSFont.monospacedSystemFont(ofSize: CGFloat(canvas.config.fontSize),
                                                      weight: .regular)
        let probe = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
        var strip: (slot: Int, plan: CommandBlockChrome.StripPlan, header: BlockHeader)?
        var summaries: [(row: Int, text: String, color: RGB)] = []
        var lensFieldSlot: Int?
        // The caps, from the same headers the summaries come from -- `Pane.render`'s order exactly.
        var gutterCaps: [Int: CommandBlockChrome.GutterCap] = [:]
        var gutterLabels: [Int: String] = [:]

        for block in blocks {
            guard block.showsHeader, let promptSlot = slotOfRow[block.region.promptRow] else { continue }
            let isRequest = block.region.id == requestID
            let header = block.header(now: terminal.now(), folding: folding, notifyArmed: false,
                                      anyFolds: !folding.isEmpty,
                                      hasOutput: terminal.commandHasOutput(atAbsoluteRow: block.region.promptRow),
                                      // The summary the block header would carry for *this*
                                      // response. A green `… json` over an HTML body would be a
                                      // picture of a bug this fixture invented.
                                      httpSummary: isRequest
                                        ? (htmlBody
                                           ? HTTPSummary(text: "301 \u{b7} 42 ms \u{b7} 232 B \u{b7} html",
                                                         tone: .redirect)
                                           : HTTPSummary(text: "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json",
                                                         tone: .success))
                                        : nil,
                                      isHTTP: isRequest,
                                      lens: lenses.lens(of: block.region.id),
                                      bodyIsJSON: isRequest && !htmlBody,
                                      watch: isRequest ? watch : nil)
            if isRequest { lensFieldSlot = promptSlot }
            if let cap = CommandBlockChrome.gutterCap(
                    header,
                    hasStarted: terminal.commandDidStart(atAbsoluteRow: block.region.promptRow),
                    hovered: hovered == block.region.id) {
                gutterCaps[promptSlot] = cap
                gutterLabels[promptSlot] = GutterMarkLabel.text(
                    mark: block.failed ? .failed : (block.isRunning ? .running : .succeeded),
                    folded: header.folded, hasOutput: header.hasOutput, line: promptSlot + 1)
            }
            // Every row of the command line is a candidate, not just the prompt row: a pasted
            // `curl` wraps, and the row with room is usually the last.
            let lastCommandRow = block.region.outputStart.map { $0 - 1 } ?? block.region.promptRow
            var candidates: [(absoluteRow: Int, lastUsedColumn: Int)] = []
            if lastCommandRow >= block.region.promptRow {
                for absolute in block.region.promptRow...lastCommandRow {
                    guard let slot = slotOfRow[absolute], slot < lines.count else { continue }
                    candidates.append((absoluteRow: absolute,
                                       lastUsedColumn: CommandBlockChrome.lastUsedColumn(of: lines[slot])))
                }
            }
            let text = header.summaryWithChevron
            let summaryHere = text.isEmpty ? nil : CommandBlockChrome.summaryPlacement(
                commandRows: candidates, textCount: text.count,
                chevronCount: header.chevron.count, cols: cols)
            let placedSummary: CommandBlockChrome.PlacedSummary? = summaryHere.map {
                (row: $0.row, text: $0.text == .full ? header.summary : "")
            }
            if hovered == block.region.id,
               let placement = CommandBlockChrome.stripPlacement(
                    header, commandRows: candidates, cols: cols, summary: placedSummary,
                    measure: { Int((probe.width(of: $0, font: overlayFont) / canvas.cell.width)
                        .rounded(.up)) }),
               let slot = slotOfRow[placement.row] {
                strip = (slot: slot, plan: placement.plan, header: header)
                notes[slot] = nil
                if notes.indices.contains(promptSlot) { notes[promptSlot] = nil }
                // The summary gives way only to a strip on its own row that repeats it word for
                // word, exactly as `Pane.render` decides it.
                if CommandBlockChrome.suppressesSummary(placement.plan, stripRow: placement.row,
                                                        summary: placedSummary) {
                    continue
                }
            }
            guard !text.isEmpty else { continue }
            guard let placement = summaryHere,
                  let slot = slotOfRow[placement.row] else { continue }
            summaries.append((row: slot, text: placement.text == .full ? text : header.chevron,
                              color: header.tone.color(in: palette)))
            notes[slot] = nil
            if notes.indices.contains(promptSlot) { notes[promptSlot] = nil }
        }

        var sticky: (text: String, summary: String, tone: SummaryTone, failed: Bool)?
        if let pinned = terminal.stickyPrompt(viewportTop: windowTop),
           let region = terminal.command(containingAbsoluteRow: pinned.row) {
            let block = CommandBlock(region: region, visibleRows: 0..<0, showsHeader: true)
            let header = block.header(now: terminal.now(), folding: folding, notifyArmed: false,
                                      anyFolds: !folding.isEmpty,
                                      hasOutput: terminal.commandHasOutput(atAbsoluteRow: region.promptRow))
            sticky = (StickyPromptLabel.text(command: terminal.commandText(of: region),
                                             exitStatus: pinned.exitStatus, columns: cols),
                      header.summary, header.tone, pinned.failed)
        }

        var matches = [[Range<Int>]](repeating: [], count: rows)
        var current = [Range<Int>?](repeating: nil, count: rows)
        var search: (query: String, readout: String)?
        if !searchQuery.isEmpty {
            matches = SearchHighlights.visibleRanges(searchSession.matches, displayRows: display,
                                                     cols: cols)
                + Array(repeating: [], count: pad)
            current = SearchHighlights.visibleRange(onAbsoluteRow: searchSession.current?.row ?? 0,
                                                    columns: searchSession.current?.columns,
                                                    displayRows: display, cols: cols)
                + Array(repeating: nil, count: pad)
            search = (searchQuery, searchSession.readout)
        }

        let caret = terminal.scrollback.count + terminal.screen.cursor.y
        let cursorSlot = DisplayRows.cursorSlot(absoluteRow: caret, in: display)
            .map { Cursor(x: terminal.screen.cursor.x, y: $0) }
        var field: (slot: Int, caption: String, text: String, message: String?, offersJq: Bool)?
        if showsLensField, let slot = lensFieldSlot {
            switch lenses.lens(of: requestID) {
            case .filter(let path):
                let body = htmlBody ? nil : LensRendering.bodyValue(GridScene.jsonExchange())
                let problem = LensRendering.filterError(path, body: body)
                field = (slot, "Filter", path, problem, problem == JSONPath.unsupportedMessage)
            case .grep(let needle):
                field = (slot, "Find in Body", needle, nil, false)
            default:
                field = nil
            }
        }

        let frame = RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: terminal.graphemes,
                                palette: palette, cursor: cursorSlot,
                                cursorShape: terminal.cursorShape, focused: true, preedit: nil,
                                searchMatches: matches, currentSearchMatch: current,
                                rowNotes: notes, blockSpines: spines, blockSummaries: summaries,
                                highlightedRows: hovered.flatMap { id in
                                    blocks.first { $0.region.id == id }.flatMap {
                                        DisplayRows.slots(coveredBy: $0.visibleRows,
                                                          commandID: id, in: display,
                                                          viewportTop: windowTop)
                                    }
                                })
        return Built(frame: frame, gutterCaps: gutterCaps, gutterLabels: gutterLabels,
                     strip: strip, sticky: sticky, lensField: field, search: search)
    }

    /// The response the lens cases are of: nested objects, an array long enough to fold to a
    /// counted placeholder, a null, and headers worth folding.
    static func jsonExchange() -> HTTPExchange {
        var body = "{\"page\":1,\"total\":3,\"next\":null,\"version\":\"1.4.2\","
        body += "\"results\":[" + (1...40).map(String.init).joined(separator: ",") + "],"
        body += "\"users\":["
        body += (0..<3).map { index in
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
        let timing = HTTPExchange.Timing(status: 200, total: 0.142, nameLookup: 0.003,
                                         connect: 0.015, appConnect: 0.055, startTransfer: 0.120,
                                         sizeDownload: body.utf8.count, numRedirects: 0,
                                         contentType: "application/json")
        return HTTPExchange(redirects: [], final: head, bodyLines: [body], bodyKind: .json,
                            timing: timing)
    }

    /// The same request answering with HTML: what `.pretty` has nothing to pretty-print.
    static func htmlExchange() -> HTTPExchange {
        let body = ["<!doctype html>", "<html><head><title>Moved</title></head>",
                    "<body><h1>301 Moved Permanently</h1>",
                    "<p>The document has moved <a href=\"/v1/users\">here</a>.</p>",
                    "</body></html>"]
        let head = HTTPExchange.Head(version: "1.1", status: 301, reason: "Moved Permanently",
                                     headers: [.init(name: "content-type", value: "text/html"),
                                               .init(name: "location",
                                                     value: "https://api.example.com/v1/users")])
        let timing = HTTPExchange.Timing(status: 301, total: 0.042, nameLookup: 0.003,
                                         connect: 0.012, appConnect: 0.030, startTransfer: 0.038,
                                         sizeDownload: body.joined().utf8.count, numRedirects: 0,
                                         contentType: "text/html")
        return HTTPExchange(redirects: [], final: head, bodyLines: body, bodyKind: .text,
                            timing: timing)
    }
}
