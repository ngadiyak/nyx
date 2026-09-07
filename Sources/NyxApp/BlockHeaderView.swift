import AppKit
import NyxCore

/// The strip that appears over a hovered block's command row: its readout, its watch timeline and
/// its pills, laid out from one `CommandBlockChrome.StripPlan`.
///
/// Drawn over the row like `StickyPromptView` is drawn over the top row, and for the same reason:
/// the grid is what the shell sized itself to, and a header row inserted into it would resize the
/// session and break under tmux.
///
/// **What survives at each width is not decided here.** `CommandBlockChrome` builds the plan --
/// which pills, how much of the sentence, how many dots -- and this view lays that plan out and
/// measures it. The two used to be separate opinions (`BlockHeader.shows…(at:)` answered here as
/// well as in Core), and the width the placement reserved and the strip that was drawn came apart.
/// Now the only number this view produces is `width(of:font:)`, and it is the same arithmetic
/// `layout()` uses a frame later.
final class BlockHeaderView: NSView {
    var onAction: ((BlockAction, UInt32) -> Void)?
    var onToggleFold: ((UInt32, Bool) -> Void)?
    /// Whether an earlier block ran this same request, asked when the ⋯ menu opens. See
    /// `menuHeader()` for why it is not on the header the frame built.
    var onNeedsPreviousRun: ((UInt32) -> Bool)?

    /// 8 pt of solid ground at each end (§2.3). The leading one is what the two-cell gradient fades
    /// *into*, so the strip never begins hard against a glyph.
    static let edgeInset: CGFloat = 8

    /// The watch series' timeline, oldest run first. Its own view because it is the one thing on
    /// this strip that is neither a label nor a control: see `WatchDotsView`.
    private let dotsView = WatchDotsView(frame: .zero)
    /// `+18`: the runs the thirty-dot cap is not showing. A label in the readout's font rather than
    /// a thirty-first dot, so the cap says how much it is hiding instead of silently dropping it.
    private let overflow = NSTextField(labelWithString: "")
    private let readout = NSTextField(labelWithString: "")
    /// Pooled: the plan changes on any frame, and building four views per frame at 60 Hz to draw
    /// the same four pills is work nobody asked for.
    private var pillViews: [StripPillView] = []
    /// The strip's leading edge: two cells of gradient from the strip's ground to nothing.
    ///
    /// It was a one-point rule, which is right where the strip sits on empty space and wrong where
    /// it does not: a hard edge cut the glyph underneath in half, and a character sliced down the
    /// middle reads as a rendering fault rather than as chrome.
    private let fadeLayer = CAGradientLayer()
    /// How tall the terminal row under this strip is -- what the strip *paints*.
    ///
    /// The strip's frame is `CommandBlockChrome.stripFrameHeight`, taller than one row, because
    /// `hitTest` rejects anything outside the frame and a frame one row tall left a dead sliver
    /// along the top and bottom of every 20 pt pill. The ground stays one row, or a 20 pt opaque
    /// band would clip the descenders of the row above and the ascenders of the row below.
    private var groundHeight: CGFloat = 0
    /// How wide the fade is, in points: two cells of the pane's font. Set from `configure`.
    private var fadeInset: CGFloat = 16
    /// Where the leftmost thing on the strip begins, in points. §2.3 runs 8 pt of *solid* ground
    /// leftwards from there and only then the two-cell gradient, so nothing is ever set on a ground
    /// that is still fading up; the fade stops need that x, and only `layout()` knows it.
    private var contentLeft: CGFloat = 0
    private var header: BlockHeader?
    private var plan: CommandBlockChrome.StripPlan?
    private var palette = Palette.xtermDefault()
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// What one plan's content measures, for one font. The pane asks on every frame it hovers a
    /// block, and in steady state nothing about the answer has changed.
    ///
    /// The readout's *length*, not its text: it is drawn in the pane's monospaced font, so its
    /// width is exactly the character count times one advance, and a running command whose elapsed
    /// time ticks from `12s` to `13s` reuses the entry instead of adding one every second. The
    /// pills carry their own titles, so keying on the list keys on the labels too.
    private struct WidthKey: Hashable {
        let pills: [CommandBlockChrome.Pill]
        let readoutCount: Int
        let dots: Int
        let overflow: String?
        let font: String
        let size: CGFloat
    }
    private var widths: [WidthKey: CGFloat] = [:]
    /// Count-keying already bounds this to a few dozen entries per font; the cap is for the one
    /// thing that can still walk the key space, a user holding ⌘+ through fifty font sizes.
    private static let widthCacheLimit = 64

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The strip's ground *is* the gradient: an opaque background with a fade drawn on top of
        // it would paint over the first characters of the readout, and one drawn underneath would
        // be hidden by it. A sublayer rather than the backing layer, so it can be shorter than the
        // view -- see `groundHeight`. Added before any subview, so it stays under the pills.
        layer?.addSublayer(fadeLayer)
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        isHidden = true
        addSubview(dotsView)
        addSubview(overflow)
        addSubview(readout)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Measuring

    /// The measured width of one plan's content, in points, cached per content and font.
    ///
    /// This is what `Pane` hands to `CommandBlockChrome.stripPlacement`'s `measure`, so it decides
    /// which row of a wrapped command the strip lands on and at which column it begins. Every term
    /// is a number `layout()` uses too.
    func width(of content: CommandBlockChrome.StripContent, font: NSFont) -> CGFloat {
        let key = WidthKey(pills: content.pills, readoutCount: content.readout.count,
                           dots: content.dots.count, overflow: content.overflowDot,
                           font: font.fontName, size: font.pointSize)
        if let cached = widths[key] { return cached }
        let width = BlockHeaderView.edgeInset * 2 + BlockHeaderView.parts(of: content, font: font)
            .enumerated()
            .reduce(0) { $0 + $1.element + ($1.offset > 0 ? StripPillView.gap : 0) }
        if widths.count >= BlockHeaderView.widthCacheLimit { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }

    /// The strip's elements left to right, as widths: `+N`, the dots, the readout, then the pills.
    ///
    /// `+N` leads because it *replaces* the oldest dot (`StripContent` drops the first one when the
    /// cap bites), so it stands where that run would have been.
    private static func parts(of content: CommandBlockChrome.StripContent,
                              font: NSFont) -> [CGFloat] {
        var parts: [CGFloat] = []
        if let overflow = content.overflowDot { parts.append(textWidth(overflow, font: font)) }
        if !content.dots.isEmpty { parts.append(WatchDotsView.width(ofDots: content.dots.count)) }
        if !content.readout.isEmpty { parts.append(textWidth(content.readout, font: font)) }
        parts.append(contentsOf: content.pills.map(StripPillView.width(of:)))
        return parts
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    override var intrinsicContentSize: NSSize {
        guard let plan else { return NSSize(width: 0, height: StripPillView.height) }
        return NSSize(width: width(of: plan.content, font: font), height: StripPillView.height)
    }

    // MARK: - Updating

    /// nil hides the strip. Compared before applied: this is called once per frame.
    func update(header: BlockHeader?, plan: CommandBlockChrome.StripPlan?, palette: Palette,
                font: NSFont, groundHeight: CGFloat) {
        guard let header, let plan else {
            if !isHidden { isHidden = true; self.header = nil; self.plan = nil }
            return
        }
        let changed = header != self.header || plan != self.plan || palette != self.palette
            || self.font != font || self.groundHeight != groundHeight
        let newBlock = header.id != self.header?.id
        self.header = header
        self.plan = plan
        self.palette = palette
        self.font = font
        self.groundHeight = groundHeight
        guard changed else { isHidden = false; return }
        // The strip is painted in the pane's theme, but anything AppKit draws inside it follows the
        // *window's* appearance instead. In Light Mode over a dark theme that dimming lightened a
        // disabled control toward the light-mode background it thought was behind it, landing at
        // 1.13:1 against this strip's actual dark fill -- invisible. Telling the view which
        // appearance it is really sitting in makes both agree with the theme.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        configure(plan, font: font, newBlock: newBlock)
        isHidden = false
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func configure(_ plan: CommandBlockChrome.StripPlan, font: NSFont, newBlock: Bool) {
        // Two cells of the *pane's* font, so the fade is two characters wide whatever the zoom --
        // measured here because this is the one place the strip is told what the grid looks like.
        fadeInset = max(BlockHeaderView.edgeInset,
                        ceil(("0" as NSString).size(withAttributes: [.font: font]).width) * 2)

        readout.stringValue = plan.readout
        readout.font = font
        // A running block used to read exactly like a finished one apart from the digit. The
        // theme's running colour is the amber the spine already uses for the same state, and a
        // request's own colour comes down the same ladder: 2xx green, 3xx amber, 4xx/5xx red, so
        // the strip, the glyphs on the command row and the sticky strip cannot disagree.
        readout.textColor = nsColor(plan.readoutTone.color(in: palette), alpha: 1)
        readout.isHidden = plan.readout.isEmpty

        dotsView.update(dots: plan.dots, palette: palette)
        dotsView.isHidden = plan.dots.isEmpty

        overflow.stringValue = plan.overflowDot ?? ""
        overflow.font = font
        // The dots' own neutral tone, in the readout's font, so `+18` reads as a label rather than
        // as a thirty-first circle nobody can tell the colour of.
        overflow.textColor = nsColor(SummaryTone.plain.color(in: palette), alpha: 1)
        overflow.isHidden = plan.overflowDot == nil
        overflow.setAccessibilityLabel("\(plan.overflowDot.map { String($0.dropFirst()) } ?? "0") earlier runs")

        configurePills(plan, newBlock: newBlock)

        // The row's own hover tint over the terminal's background, not `palette.background`: a
        // background band on a tinted row reads as a floating rectangle (design §2.7).
        // `blockHoverBackground` is the tint already composited over the theme's background -- the
        // same opaque colour the renderer paints across the hovered rows -- so the band matches the
        // row it sits on instead of floating above it.
        //
        // A plan that overlaps the command paints no ground at all: the opaque pill is the ground,
        // and a band there would rub out the tail of the command the pill is sitting on.
        fadeLayer.isHidden = plan.overlapsCommand
        let ground = nsColor(palette.blockHoverBackground, alpha: 1).cgColor
        fadeLayer.colors = [nsColor(palette.blockHoverBackground, alpha: 0).cgColor, ground, ground]
        placeFadeStops()
    }

    private func configurePills(_ plan: CommandBlockChrome.StripPlan, newBlock: Bool) {
        while pillViews.count < plan.pills.count {
            let view = StripPillView(frame: .zero)
            addSubview(view)
            pillViews.append(view)
        }
        for (index, view) in pillViews.enumerated() {
            guard index < plan.pills.count else {
                // Hidden, and at rest: the pointer is not over a view that is not on the screen,
                // and a pill held down as the plan changed under it must not come back pressed.
                view.resetInteraction()
                view.isHidden = true
                view.onPress = nil
                continue
            }
            // A pill that was off the strip, or belonged to another block, starts from rest even
            // when it happens to be the same pill: `configure` alone cannot see either change.
            if newBlock || view.isHidden { view.resetInteraction() }
            let pill = plan.pills[index]
            view.isHidden = false
            view.configure(pill, palette: palette)
            view.onPress = { [weak self] in self?.press(pill) }
        }
    }

    /// What each pill does. One place, so the tooltip, the VoiceOver label and the effect are the
    /// same control described once.
    private func press(_ pill: CommandBlockChrome.Pill) {
        guard let header else { return }
        switch pill {
        case .copy: onAction?(.copyOutput, header.id)
        case .stop: onAction?(.stopWatch, header.id)
        case .fold: onToggleFold?(header.id, NSEvent.modifierFlags.contains(.option))
        case .actions: openActionsMenu()
        case .lens: openLensMenu()
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let painted = min(groundHeight > 0 ? groundHeight : bounds.height, bounds.height)
        fadeLayer.frame = CGRect(x: 0, y: (bounds.height - painted) / 2,
                                 width: bounds.width, height: painted)
        placeFadeStops()
        guard let plan else { return }
        // Right-aligned by hand, from the trailing edge inwards: the sum this walks is exactly the
        // sum `width(of:font:)` returned, so the strip that was measured is the strip that is drawn.
        var x = bounds.width - BlockHeaderView.edgeInset
        defer {
            contentLeft = max(0, x + StripPillView.gap)
            placeFadeStops()
        }
        func place(_ view: NSView, width: CGFloat, height: CGFloat) {
            x -= width
            view.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
            x -= StripPillView.gap
        }
        for (index, view) in pillViews.enumerated().reversed() where index < plan.pills.count {
            place(view, width: StripPillView.width(of: plan.pills[index]),
                  height: StripPillView.height)
        }
        if !readout.isHidden {
            place(readout, width: BlockHeaderView.textWidth(plan.readout, font: font),
                  height: ceil(readout.fittingSize.height))
        }
        if !dotsView.isHidden {
            place(dotsView, width: WatchDotsView.width(ofDots: plan.dots.count),
                  height: WatchDotsView.diameter)
        }
        if !overflow.isHidden {
            place(overflow, width: BlockHeaderView.textWidth(overflow.stringValue, font: font),
                  height: ceil(overflow.fittingSize.height))
        }
    }

    /// §2.3's leading edge, right to left: 8 pt of solid ground before the first glyph, then two
    /// cells of gradient down to nothing.
    ///
    /// Reversing those two -- starting the gradient at the view's own leading edge -- put the first
    /// characters of the readout on a ground that was still coming up, which is the effect the fade
    /// exists to keep *off* the text.
    private func placeFadeStops() {
        guard bounds.width > 0 else { return }
        let solid = max(0, min(bounds.width, contentLeft - BlockHeaderView.edgeInset))
        let start = max(0, solid - fadeInset)
        fadeLayer.locations = [NSNumber(value: Double(start / bounds.width)),
                               NSNumber(value: Double(solid / bounds.width)), 1]
    }

    // MARK: - The ⋯ menu

    /// One entry of the ⋯ menu: which action, on which command. Carried on the item rather than
    /// resolved by index against `self.header` at click time -- the display link keeps calling
    /// `update(header:...)` while this menu is open (it runs in `.common` modes), so output
    /// scrolling in under the pointer can replace `header` with a different command's before the
    /// click lands, sending the action to the wrong id or dropping it if the index no longer exists.
    private final class MenuEntry: NSObject {
        let action: BlockAction
        let id: UInt32
        init(action: BlockAction, id: UInt32) { self.action = action; self.id = id }
    }

    /// The header the ⋯ menu is built from: the one the frame drew, plus the one answer that is too
    /// expensive to have per frame.
    ///
    /// `hasPreviousRun` means parsing every cached command line (`RequestSummaryCache.previousRun`),
    /// so `render` leaves it false and it is asked for here, on the press. Without this the strip's
    /// `Diff with Previous Run` was greyed on every block however many earlier runs there were --
    /// only the right-click menu, which asks the same question at the same moment, ever enabled it.
    private func menuHeader() -> BlockHeader? {
        guard var header else { return nil }
        header.hasPreviousRun = onNeedsPreviousRun?(header.id) ?? false
        return header
    }

    private func openActionsMenu() {
        guard let header = menuHeader() else { return }
        let menu = NSMenu()
        for (index, entry) in header.actions.enumerated() {
            if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: header.title(for: entry.action), action: #selector(menuPressed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = MenuEntry(action: entry.action, id: header.id)
            item.isEnabled = entry.enabled
            item.state = header.isChecked(entry.action) ? .on : .off
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        // Dropped from under the pill it came from. `StripPillView` is flipped, so its bottom-left
        // -- where a menu that drops down should start -- is `(0, height)`, not `(0, 0)`.
        guard let anchor = pillViews.first(where: {
            if case .actions = $0.pill { return true } else { return false }
        }) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    @objc private func menuPressed(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuEntry else { return }
        onAction?(entry.action, entry.id)
    }

    /// The lens rows of the ⋯ menu, on their own, under the chip that names them. Built from
    /// `header.actions` rather than from a second list, so the chip cannot offer a lens the menu
    /// does not -- the failure `BlockHeader.showsLens` and the menu had before them.
    private func lensMenu(for header: BlockHeader) -> NSMenu {
        let menu = NSMenu()
        for entry in header.actions {
            guard case .setLens = entry.action else { continue }
            let item = NSMenuItem(title: header.title(for: entry.action),
                                  action: #selector(menuPressed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuEntry(action: entry.action, id: header.id)
            item.isEnabled = entry.enabled
            item.state = header.isChecked(entry.action) ? .on : .off
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    /// The chip's `▾`: opens the lens rows alone, rather than the whole ⋯ menu -- a chip that
    /// carries one control's own name opens that control's own choices. `menuHeader()` because
    /// `Diff with Previous Run`'s `enabled` is answered late, same as `openActionsMenu`.
    private func openLensMenu() {
        guard let header = menuHeader() ?? header else { return }
        // Dropped from under the pill it came from, same reasoning as `openActionsMenu`:
        // `StripPillView` is flipped, so its bottom-left is `(0, height)`, not `(0, 0)`.
        guard let anchor = pillViews.first(where: {
            if case .lens = $0.pill { return true } else { return false }
        }) else { return }
        lensMenu(for: header).popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height),
                                    in: anchor)
    }

    // MARK: - Snapshots

    /// Puts one pill into its pressed art, by the title it draws. `StateSnapshot` presses a pill
    /// this way: these are drawn views, so there is no `NSButton.highlight(true)` to reach for.
    func setPressedForSnapshot(title: String) -> Bool {
        guard let view = pillViews.first(where: { !$0.isHidden && $0.pill?.title == title })
        else { return false }
        view.setPressedForSnapshot(true)
        return true
    }

    override func isAccessibilityElement() -> Bool { false }   // the pills are the elements
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { header.map { "Command block: \($0.summary)" } }
}
