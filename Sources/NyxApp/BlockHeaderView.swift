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

    private let summary = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let moreButton = NSButton(title: "\u{22EF}", target: nil, action: nil)
    private let chevronButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    private let hairline = NSView()
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
        isHidden = true
        for button in [copyButton, moreButton, chevronButton] {
            button.bezelStyle = .inline
            button.controlSize = .small
            button.target = self
            button.setButtonType(.momentaryPushIn)
        }
        copyButton.action = #selector(copyPressed)
        copyButton.toolTip = "Copy this command\u{2019}s output"
        moreButton.action = #selector(morePressed)
        moreButton.toolTip = "More actions for this command"
        moreButton.setAccessibilityLabel("More actions")
        chevronButton.action = #selector(chevronPressed)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 4)
        stack.setViews([summary, copyButton, moreButton, chevronButton], in: .center)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.wantsLayer = true
        addSubview(hairline)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Centred rather than pinned top and bottom: the shipping height is one cell row
            // (~17pt at the default size), shorter than the stack's fitting height with its
            // default insets, and two required edge constraints on a view shorter than its
            // content log a constraint break every frame instead of just centring it.
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.widthAnchor.constraint(equalToConstant: 1),
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
        summary.stringValue = header.summary
        summary.font = font
        summary.isHidden = controls == .minimal || header.summary.isEmpty
        copyButton.isHidden = controls != .full
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
        // theme's running colour is the amber the spine already uses for the same state.
        let summaryColor: RGB = header.failed ? palette.readable(1)
            : (header.isRunning ? palette.readable(3) : palette.noteForeground)
        summary.textColor = nsColor(summaryColor, alpha: 1)
        copyButton.isEnabled = header.hasOutput
        chevronButton.toolTip = header.folded ? "Unfold this command\u{2019}s output" : "Fold this command\u{2019}s output (\u{2325}: hide all of it)"
        chevronButton.setAccessibilityLabel(header.title(for: .toggleFold))
        // `contentTintColor` recolours a *symbol image*, not a titled button's text -- the title
        // paints in the system's `labelColor`, which is black in Light Mode regardless of the
        // pane's own (possibly dark) theme. Colouring the title itself is the only way a themed
        // button reads correctly against a themed background irrespective of the system appearance.
        style(copyButton, title: "Copy", enabled: copyButton.isEnabled)
        style(moreButton, title: "\u{22EF}", enabled: true)
        style(chevronButton, title: header.chevron, enabled: true)
        layer?.backgroundColor = nsColor(palette.background, alpha: 1).cgColor
        hairline.layer?.backgroundColor = nsColor(palette.noteForeground, alpha: 1).cgColor
        isHidden = false
        invalidateIntrinsicContentSize()
    }

    /// Sets a button's title through `attributedTitle` so its colour comes from the pane's palette
    /// rather than the system appearance's `labelColor`, and so a disabled control visibly dims.
    private func style(_ button: NSButton, title: String, enabled: Bool) {
        let color = nsColor(enabled ? palette.foreground : palette.noteForeground, alpha: 1)
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font])
    }

    override var intrinsicContentSize: NSSize { stack.fittingSize }

    @objc private func copyPressed() { if let header { onAction?(.copyOutput, header.id) } }
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

    @objc private func morePressed() {
        guard let header else { return }
        let menu = NSMenu()
        for (index, entry) in header.actions.enumerated() {
            if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: header.title(for: entry.action), action: #selector(menuPressed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = MenuEntry(action: entry.action, id: header.id)
            item.isEnabled = entry.enabled
            if case .notifyWhenDone(let armed) = entry.action { item.state = armed ? .on : .off }
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
