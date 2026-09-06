import AppKit
import NyxCore

/// The strip that appears over a hovered block's command row: its summary, Copy, ⋯ and the chevron.
///
/// Drawn over the row like `StickyPromptView` is drawn over the top row, and for the same reason:
/// the grid is what the shell sized itself to, and a header row inserted into it would resize the
/// session and break under tmux. Real buttons rather than Metal chrome so tooltips, hover feedback
/// and accessibility come from AppKit, and so the snapshot renderer can draw every state.
///
/// What the strip says and which actions it offers is `BlockHeader` in NyxCore. What is here is
/// layout, colours and the click.
final class BlockHeaderView: NSView {
    var onAction: ((BlockAction, UInt32) -> Void)?
    var onToggleFold: ((UInt32, Bool) -> Void)?
    /// Whether an earlier block ran this same request, asked when the ⋯ menu opens. See
    /// `menuHeader()` for why it is not on the header the frame built.
    var onNeedsPreviousRun: ((UInt32) -> Bool)?

    private let summary = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let moreButton = NSButton(title: "\u{22EF}", target: nil, action: nil)
    /// `{ }` -- pretty JSON on, pretty JSON off. Only on a block whose command was a request, and
    /// only where there is room for `Copy`: it is a convenience for a thing the ⋯ menu also does,
    /// and the chevron and the ⋯ are what the strip is for.
    private let lensButton = NSButton(title: "{ }", target: nil, action: nil)
    /// The watch series' timeline, oldest run first. Its own view because it is the one thing on
    /// this strip that is neither a label nor a control: see `WatchDotsView`.
    private let dots = WatchDotsView(frame: .zero)
    /// Ends the series this block's run belongs to. Unlike `⌘.` it has no "is this the latest
    /// block" rule: pressing it names the series.
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let chevronButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    /// The strip's leading edge: two cells of gradient from the terminal's background to nothing.
    ///
    /// It was a one-point rule, which is right where the strip sits on empty space and wrong where
    /// it does not: on a command line with no room anywhere, the strip is placed over the tail of
    /// the text, and a hard edge cut the glyph underneath in half -- a character sliced down the
    /// middle reads as a rendering fault rather than as chrome. A fade lets the last glyph go out
    /// instead of being guillotined.
    private let fadeLayer = CAGradientLayer()
    /// How wide the fade is, in points: two cells of the pane's font. Set from `configure`.
    private var fadeInset: CGFloat = 16
    private var header: BlockHeader?
    private var controls: OverlayControls = .full
    private var palette = Palette.xtermDefault()

    /// What one control set measures, for one header and one font. Measuring is an Auto Layout
    /// pass; the pane asks for all three sets on every frame it hovers a block, and in steady state
    /// nothing about the answer has changed.
    /// The summary's *length*, not its text: it is drawn in the pane's monospaced font, so its
    /// width is exactly the character count times one advance, and a running command whose elapsed
    /// time ticks from `12s` to `13s` reuses the entry instead of adding one every second. The
    /// buttons are system-font and fixed per control set, and the chevron's two glyphs are kept
    /// apart because that one *is* proportional.
    private struct WidthKey: Hashable {
        let controls: OverlayControls
        let summaryCount: Int
        let chevron: String
        let hasOutput: Bool
        let lens: Bool
        /// How many dots and whether Stop is up: both change the strip's width, and a width cached
        /// without them would tell `overlayPlacement` a watch header fits where it does not.
        let dots: Int
        let stop: Bool
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
        // it would paint over the first characters of the summary, and one drawn underneath would
        // be hidden by it.
        layer = fadeLayer
        isHidden = true
        for button in [copyButton, lensButton, stopButton, moreButton, chevronButton] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.target = self
            button.setButtonType(.momentaryPushIn)
        }
        copyButton.action = #selector(copyPressed)
        copyButton.toolTip = "Copy this command\u{2019}s output"
        lensButton.action = #selector(lensPressed)
        lensButton.setAccessibilityLabel("Toggle pretty response")
        stopButton.action = #selector(stopPressed)
        stopButton.toolTip = "Stop watching this request"
        stopButton.setAccessibilityLabel("Stop watching")
        moreButton.action = #selector(morePressed)
        moreButton.toolTip = "More actions for this command"
        moreButton.setAccessibilityLabel("More actions")
        chevronButton.action = #selector(chevronPressed)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 4)
        stack.setViews([dots, summary, copyButton, lensButton, stopButton, moreButton, chevronButton],
                       in: .center)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Centred rather than pinned top and bottom: the shipping height is one cell row
            // (~17pt at the default size), shorter than the stack's fitting height with its
            // default insets, and two required edge constraints on a view shorter than its
            // content log a constraint break every frame instead of just centring it.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point)
    }

    /// The strip's width in points for one control set, so `CommandBlockChrome.overlayPlacement`
    /// can be told what it is choosing between.
    ///
    /// Measured rather than estimated: the summary is a themed label in the pane's own font and the
    /// buttons are system-font `.inline` bezels, so a guess would be wrong by the amount that
    /// decides whether the strip covers a glyph. The configuration is put back afterwards, because
    /// `update` skips its work when nothing changed and would otherwise leave the strip showing
    /// whatever the last measurement configured.
    func width(for controls: OverlayControls, header: BlockHeader, font: NSFont) -> CGFloat {
        let key = WidthKey(controls: controls, summaryCount: header.summary.count,
                           chevron: header.chevron, hasOutput: header.hasOutput,
                           lens: header.showsLens(at: controls),
                           dots: header.showsTimeline(at: controls) ? header.watch?.dots.count ?? 0 : 0,
                           stop: header.showsStop(at: controls),
                           font: font.fontName, size: font.pointSize)
        if let cached = widths[key] { return cached }
        let previousHeader = self.header
        let previousControls = self.controls
        configure(header: header, controls: controls, font: font)
        let width = stack.fittingSize.width
        // `configure` touches only the subviews, never `self.header`, so a measurement before the
        // first `update` cannot make that `update` think nothing changed and skip its styling.
        if let previousHeader { configure(header: previousHeader, controls: previousControls, font: font) }
        if widths.count >= BlockHeaderView.widthCacheLimit { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }

    /// Which of the strip's parts are shown. Not a rule of its own: `overlayPlacement` decides, and
    /// this obeys, so what is measured and what is drawn cannot come apart.
    private func configure(header: BlockHeader, controls: OverlayControls, font: NSFont) {
        // Two cells of the *pane's* font, so the fade is two characters wide whatever the zoom --
        // measured here because this is the one place the strip is told what the grid looks like.
        let cell = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
        let fade = max(8, cell * 2)
        if fadeInset != fade {
            fadeInset = fade
            stack.edgeInsets = NSEdgeInsets(top: 0, left: fade + 4, bottom: 0, right: 4)
            needsLayout = true
        }
        // Every one of these rules is `BlockHeader`'s, in NyxCore where it is tested. Answering
        // them here as well is how the strip and `width(for:)` came apart -- and `width(for:)` is
        // what `overlayPlacement` reserves room from.
        summary.stringValue = header.summary
        summary.font = font
        summary.isHidden = !header.showsSummary(at: controls)
        copyButton.isHidden = !header.showsCopy(at: controls)
        lensButton.isHidden = !header.showsLens(at: controls)
        let timeline = header.showsTimeline(at: controls) ? (header.watch?.dots ?? []) : []
        dots.update(dots: timeline, palette: palette)
        dots.isHidden = timeline.isEmpty
        stopButton.isHidden = !header.showsStop(at: controls)
        chevronButton.isHidden = !header.hasOutput
    }

    /// nil hides the strip. Compared before applied: this is called once per frame.
    func update(header: BlockHeader?, controls: OverlayControls, palette: Palette, font: NSFont) {
        guard let header else {
            if !isHidden { isHidden = true; self.header = nil }
            return
        }
        let changed = header != self.header || controls != self.controls
            || palette != self.palette || summary.font != font
        self.header = header
        self.controls = controls
        self.palette = palette
        guard changed else { isHidden = false; return }
        // The strip is painted in the pane's theme, but two things inside it are drawn by AppKit and
        // follow the *window's* appearance instead: the `.inline` bezel's own fill, and the dimming
        // NSButtonCell applies to a disabled control. In Light Mode over a dark theme that dimming
        // lightened the disabled Copy toward the light-mode background it thought was behind it,
        // landing at 1.13:1 against this strip's actual dark fill -- invisible. Telling the view
        // which appearance it is really sitting in makes both agree with the theme.
        appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua)
        configure(header: header, controls: controls, font: font)
        // A running block used to read exactly like a finished one apart from the digit. The
        // theme's running colour is the amber the spine already uses for the same state, and a
        // request's own colour comes down the same ladder: 2xx green, 3xx amber, 4xx/5xx red, so
        // the strip, the glyphs on the command row and the sticky strip cannot disagree.
        summary.textColor = nsColor(header.tone.color(in: palette), alpha: 1)
        copyButton.isEnabled = header.hasOutput
        chevronButton.toolTip = header.folded ? "Unfold this command\u{2019}s output" : "Fold this command\u{2019}s output (\u{2325}: hide all of it)"
        chevronButton.setAccessibilityLabel(header.title(for: .toggleFold))
        // `contentTintColor` recolours a *symbol image*, not a titled button's text -- the title
        // paints in the system's `labelColor`, which is black in Light Mode regardless of the
        // pane's own (possibly dark) theme. Colouring the title itself is the only way a themed
        // button reads correctly against a themed background irrespective of the system appearance.
        style(copyButton, title: "Copy", enabled: copyButton.isEnabled)
        style(moreButton, title: "\u{22EF}", enabled: true)
        style(stopButton, title: "Stop", enabled: true, tint: palette.readable(1))
        style(chevronButton, title: header.chevron, enabled: true)
        // `{ }` is a toggle, and a toggle drawn identically in both its states is a button that
        // lies about what pressing it will do. The accent is the colour this theme already paints a
        // running toggle and a selected row in, so a response being read through a lens says so the
        // way everything else in Nyx says "on". It also has to go through `style` at all: an
        // unstyled title paints in the system's `labelColor`, which on a dark theme under Light
        // Mode is black on near-black -- the mistake the comment above was written for.
        let lensOn = header.lens != nil
        style(lensButton, title: "{ }", enabled: true,
              tint: lensOn ? palette.accent : palette.foreground)
        lensButton.toolTip = lensOn ? "Show this response as it arrived"
                                    : "Show this response as pretty JSON"
        lensButton.setAccessibilityLabel(lensOn ? "Show raw response" : "Show pretty response")
        // Left to right: nothing, then the strip's own ground, held to the right-hand edge. The
        // stops are placed in `layout()`, where the width is known.
        let ground = nsColor(palette.background, alpha: 1).cgColor
        fadeLayer.colors = [nsColor(palette.background, alpha: 0).cgColor, ground, ground]
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
        placeFadeStops()
        isHidden = false
        invalidateIntrinsicContentSize()
    }

    /// Sets a button's title through `attributedTitle` so its colour comes from the pane's palette
    /// rather than the system appearance's `labelColor`, and so a disabled control visibly dims.
    private func style(_ button: NSButton, title: String, enabled: Bool, tint: RGB? = nil) {
        let color = nsColor(enabled ? (tint ?? palette.foreground) : palette.noteForeground,
                            alpha: 1)
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font])
    }

    override func layout() {
        super.layout()
        placeFadeStops()
    }

    /// Where the fade ends: two cells in from the leading edge, as a fraction of the width.
    private func placeFadeStops() {
        guard bounds.width > 0 else { return }
        let end = min(1, fadeInset / bounds.width)
        fadeLayer.locations = [0, NSNumber(value: Double(end)), 1]
    }

    override var intrinsicContentSize: NSSize { stack.fittingSize }

    @objc private func copyPressed() { if let header { onAction?(.copyOutput, header.id) } }
    @objc private func lensPressed() {
        guard let header else { return }
        onAction?(.toggleLens, header.id)
    }

    @objc private func stopPressed() { if let header { onAction?(.stopWatch, header.id) } }

    @objc private func chevronPressed() {
        guard let header else { return }
        onToggleFold?(header.id, NSEvent.modifierFlags.contains(.option))
    }

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

    @objc private func morePressed() {
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
        // The view is unflipped, so (0, 0) is its bottom-left -- where a menu that drops down from
        // under the button should start. `moreButton.bounds.height` put the origin a button's
        // height above that, floating the menu a row higher than the button it came from.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: moreButton)
    }

    @objc private func menuPressed(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? MenuEntry else { return }
        onAction?(entry.action, entry.id)
    }

    override func isAccessibilityElement() -> Bool { false }   // the buttons are the elements
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { header.map { "Command block: \($0.summary)" } }
}
