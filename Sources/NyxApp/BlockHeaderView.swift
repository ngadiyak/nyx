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
    private var palette = Palette.xtermDefault()

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
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// nil hides the strip. Compared before applied: this is called once per frame.
    func update(header: BlockHeader?, palette: Palette, font: NSFont) {
        guard let header else {
            if !isHidden { isHidden = true; self.header = nil }
            return
        }
        let changed = header != self.header || palette != self.palette || summary.font != font
        self.header = header
        self.palette = palette
        guard changed else { isHidden = false; return }
        summary.stringValue = header.summary
        summary.font = font
        let failed: Bool = { if case .failed = header.state { return true } else { return false } }()
        summary.textColor = nsColor(failed ? palette.readable(1) : palette.noteForeground, alpha: 1)
        summary.isHidden = header.summary.isEmpty
        copyButton.isEnabled = header.hasOutput
        chevronButton.title = header.chevron
        chevronButton.isHidden = !header.hasOutput
        chevronButton.toolTip = header.folded ? "Unfold this command\u{2019}s output" : "Fold this command\u{2019}s output (\u{2325}: hide all of it)"
        chevronButton.setAccessibilityLabel(header.title(for: .toggleFold))
        for button in [copyButton, moreButton, chevronButton] { button.contentTintColor = nsColor(palette.foreground, alpha: 1) }
        layer?.backgroundColor = nsColor(palette.background, alpha: 1).cgColor
        hairline.layer?.backgroundColor = nsColor(palette.noteForeground, alpha: 1).cgColor
        isHidden = false
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { stack.fittingSize }

    @objc private func copyPressed() { if let header { onAction?(.copyOutput, header.id) } }
    @objc private func chevronPressed() {
        guard let header else { return }
        onToggleFold?(header.id, NSEvent.modifierFlags.contains(.option))
    }

    @objc private func morePressed() {
        guard let header else { return }
        let menu = NSMenu()
        for (index, entry) in header.actions.enumerated() {
            if index > 0 && entry.action.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: header.title(for: entry.action), action: #selector(menuPressed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = entry.enabled
            if case .notifyWhenDone(let armed) = entry.action { item.state = armed ? .on : .off }
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.height), in: moreButton)
    }

    @objc private func menuPressed(_ sender: NSMenuItem) {
        guard let header, header.actions.indices.contains(sender.tag) else { return }
        onAction?(header.actions[sender.tag].action, header.id)
    }

    override func isAccessibilityElement() -> Bool { false }   // the buttons are the elements
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { header.map { "Command block: \($0.summary)" } }
}
