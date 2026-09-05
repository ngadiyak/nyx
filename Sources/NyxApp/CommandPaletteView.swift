import AppKit
import NyxCore

/// The list inside the palette panel. A plain drawn view rather than an `NSTableView`: it shows a
/// few dozen rows of two strings each, and the only interesting part -- which characters of a title
/// are highlighted -- is `PaletteResult.positions`, computed in `NyxCore`.
private final class PaletteListView: NSView {
    static let rowHeight: CGFloat = 26

    var onChoose: ((Int) -> Void)?

    private var results: [PaletteResult] = []
    private var selection = 0
    private var palette: Palette

    /// One line, cut off with an ellipsis rather than wrapped: the rows are a fixed height, and a
    /// string that wrapped would draw over the row beneath it.
    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// The same, right-aligned: the detail sits against the row's right edge, so what is cut is
    /// its tail and what survives is the directory and branch a remote row leads with.
    private static let truncatingRight: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .right
        return style
    }()

    init(palette: Palette) {
        self.palette = palette
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Rows are drawn top-down, so the first result is at the top of the scroller.
    override var isFlipped: Bool { true }

    func update(results: [PaletteResult], selection: Int, palette: Palette) {
        self.results = results
        self.selection = selection
        self.palette = palette
        let height = CGFloat(results.count) * PaletteListView.rowHeight
        setFrameSize(NSSize(width: max(frame.width, superview?.bounds.width ?? frame.width), height: height))
        needsDisplay = true
        scrollSelectionIntoView()
    }

    /// Keeps the ↑/↓ selection on screen without moving the list any further than it has to.
    private func scrollSelectionIntoView() {
        guard results.indices.contains(selection) else { return }
        scrollToVisible(rowRect(selection))
    }

    private func rowRect(_ index: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(index) * PaletteListView.rowHeight,
               width: bounds.width, height: PaletteListView.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let titleFont = NSFont.systemFont(ofSize: 13)
        let matchFont = NSFont.boldSystemFont(ofSize: 13)
        let detailFont = NSFont.systemFont(ofSize: 11)
        // Resolved once per draw, not once per row and not once per matched character. Each of
        // these walks the palette -- `accentText` tries five candidates through Lab and chroma,
        // then blends against a contrast floor that itself derives `panelSelectionBackground` --
        // and `accentText` was being recomputed inside the inner loop, so a query matching four
        // characters on thirty rows resolved it a hundred and twenty times a frame.
        let rowSelection = nsColor(palette.panelSelectionBackground, alpha: 1)
        let titleColor = nsColor(palette.foreground, alpha: 1)
        let matchColor = nsColor(palette.accentText, alpha: 1)
        let detailColor = nsColor(palette.foreground, alpha: 0.55)
        for (index, result) in results.enumerated() {
            let rect = rowRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            let isSelected = index == selection
            if isSelected {
                // Inset and rounded: a full-bleed fill runs under the panel's own rounded corners
                // and border, which looks like the highlight escaped rather than like a selection.
                rowSelection.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
            }
            let title = NSMutableAttributedString(
                string: result.item.title,
                attributes: [.font: titleFont, .foregroundColor: titleColor])
            // Bold and in the theme's accent: the characters the query actually matched, which is
            // what tells a user why this row is in the list at all. Not `colors[12]` -- Solarized's
            // bright blue is a grey identical to its foreground, so there the matched characters
            // were bold and nothing else.
            for position in result.positions where position < title.length {
                title.setAttributes([.font: matchFont, .foregroundColor: matchColor],
                                    range: NSRange(location: position, length: 1))
            }
            let detail = NSMutableAttributedString(
                string: result.item.detail,
                attributes: [.font: detailFont, .foregroundColor: detailColor])
            // How much of the row each half may have. Until the Remote section existed every detail
            // was a chord or one word and the two could never collide; a remote session's detail is
            // a sentence, and drawn at its natural width it ran straight through the title.
            let widths = PaletteRowLayout.widths(rowWidth: Double(rect.width) - 24,
                                                 titleWidth: Double(title.size().width),
                                                 detailWidth: Double(detail.size().width))
            title.addAttribute(.paragraphStyle, value: PaletteListView.truncating,
                               range: NSRange(location: 0, length: title.length))
            title.draw(in: NSRect(x: rect.minX + 12, y: rect.minY + 5,
                                  width: CGFloat(widths.title), height: rect.height - 5))

            guard !result.item.detail.isEmpty, widths.detail > 0 else { continue }
            detail.addAttribute(.paragraphStyle, value: PaletteListView.truncatingRight,
                                range: NSRange(location: 0, length: detail.length))
            detail.draw(in: NSRect(x: rect.maxX - 12 - CGFloat(widths.detail), y: rect.minY + 7,
                                   width: CGFloat(widths.detail), height: rect.height - 7))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / PaletteListView.rowHeight)
        guard results.indices.contains(index) else { return }
        onChoose?(index)
    }

    // MARK: - Accessibility
    //
    // Drawn rows are not views, so without this the palette is a text field over an empty box: the
    // list nobody can see is also the list nobody can hear.

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .list }

    override func accessibilityLabel() -> String? { "Results" }

    override func accessibilityChildren() -> [Any]? {
        results.enumerated().map { index, result in
            // The detail is the half that says what a row *is* -- a shortcut, "Theme", "Quick
            // action" -- and reading the title alone leaves three kinds of row sounding identical.
            let detail = result.item.detail.isEmpty ? "" : ", \(result.item.detail)"
            return DrawnControlElement.make(
                label: "\(result.item.title)\(detail), \(index + 1) of \(results.count)",
                role: .row, frame: rowRect(index), in: self,
                value: index == selection ? 1 : 0,
                press: { [weak self] in self?.onChoose?(index) })
        }
    }

    override func accessibilitySelectedChildren() -> [Any]? {
        guard results.indices.contains(selection),
              let children = accessibilityChildren() else { return nil }
        return [children[selection]]
    }
}

/// The `⌘⇧P` panel: a field and a list of everything this window can do.
///
/// It owns no ranking, no ordering and no selection arithmetic -- that is `CommandPalette` in
/// `NyxCore`. This converts keys into `moveSelection`/`setQuery`/"run the selected item" and draws
/// what comes back.
final class CommandPaletteView: NSView, NSTextFieldDelegate {
    /// `⏎` or a click on a row.
    var onRun: ((PaletteItem) -> Void)?
    /// `⎋`.
    var onClose: (() -> Void)?

    static let width: CGFloat = 560
    private static let fieldHeight: CGFloat = 42
    private static let maximumVisibleRows = 10

    private var model: CommandPalette
    private var palette: Palette
    private let field = NSTextField(frame: .zero)
    private let scroller = NSScrollView(frame: .zero)
    /// A hairline between the field and the results, so the two read as separate things.
    private let separator = NSView(frame: .zero)
    private let list: PaletteListView

    init(palette: Palette, items: [PaletteItem]) {
        self.palette = palette
        self.model = CommandPalette(items: items)
        self.list = PaletteListView(palette: palette)
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command palette")
        layer?.backgroundColor = nsColor(palette.background, alpha: 0.98).cgColor
        layer?.borderColor = nsColor(palette.foreground, alpha: 0.25).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        separator.wantsLayer = true
        separator.layer?.backgroundColor = nsColor(palette.foreground, alpha: 0.15).cgColor
        addSubview(separator)

        field.delegate = self
        // Attributed, not `placeholderString`: the plain form takes AppKit's placeholder colour
        // from the *system* appearance, so the one line explaining what the palette is went dark
        // grey on a dark themed panel whenever the theme and the system disagreed.
        field.placeholderAttributedString = NSAttributedString(
            string: "Run a command, pick a theme, switch to a tab",
            attributes: [.foregroundColor: nsColor(palette.foreground, alpha: 0.45),
                         .font: NSFont.systemFont(ofSize: 14)])
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = nsColor(palette.foreground, alpha: 1)
        // The placeholder is the field's only name, and it goes the moment anything is typed.
        field.describeForAccessibility("Command palette", role: .textField,
                                       help: "Type to filter; ↑ and ↓ to choose, ⏎ to run.")
        addSubview(field)

        scroller.hasVerticalScroller = true
        scroller.drawsBackground = false
        scroller.documentView = list
        list.onChoose = { [weak self] index in self?.run(rowAt: index) }
        addSubview(scroller)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// How tall the panel wants to be for what it is showing, so an empty search does not leave a
    /// tall panel of nothing.
    var preferredHeight: CGFloat {
        let rows = min(model.results.count, CommandPaletteView.maximumVisibleRows)
        return CommandPaletteView.fieldHeight + max(PaletteListView.rowHeight, CGFloat(rows) * PaletteListView.rowHeight) + 8
    }

    /// Reports the height the panel now wants, so the owner can resize it as the list narrows.
    var onHeightChange: ((CGFloat) -> Void)?

    func focusField() {
        window?.makeFirstResponder(field)
    }

    /// Opens the panel with something already typed -- `remote_sessions` opens it filtered to the
    /// Remote section. The text goes into the field as well as into the model, so backspacing works
    /// from there rather than from an empty field showing a filtered list.
    func setQuery(_ query: String) {
        field.stringValue = query
        model.setQuery(query)
        refresh()
        // The caret goes after what was typed for us, so the next keystroke narrows the list
        // instead of replacing the word.
        field.currentEditor()?.selectedRange = NSRange(location: query.count, length: 0)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 4
        // The field sat flush against the top edge, so a 14pt line's ascenders were cut off by the
        // panel's own border and rounded corner. It gets its own padding, and the list starts below
        // a hairline rather than running straight into it.
        let fieldPadding: CGFloat = 9
        field.frame = NSRect(x: 14, y: bounds.height - CommandPaletteView.fieldHeight + fieldPadding,
                             width: bounds.width - 28,
                             height: CommandPaletteView.fieldHeight - fieldPadding * 2)
        separator.frame = NSRect(x: 0, y: bounds.height - CommandPaletteView.fieldHeight,
                                 width: bounds.width, height: 1)
        scroller.frame = NSRect(x: inset, y: inset, width: bounds.width - inset * 2,
                                height: max(0, bounds.height - CommandPaletteView.fieldHeight - inset))
        list.setFrameSize(NSSize(width: scroller.contentSize.width, height: list.frame.height))
    }

    private func refresh() {
        list.update(results: model.results, selection: model.selection, palette: palette)
        // The count changes under the field as the query narrows it, and a filter with nothing left
        // in it is the one result a screen reader has no other way to notice.
        field.setAccessibilityValue(model.results.isEmpty
            ? "no matches"
            : "\(model.results.count) \(model.results.count == 1 ? "match" : "matches")")
        onHeightChange?(preferredHeight)
    }

    private func run(rowAt index: Int) {
        guard model.results.indices.contains(index) else { return }
        onRun?(model.results[index].item)
    }

    // MARK: - Events

    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(field.stringValue)
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            model.moveSelection(by: -1)
            refresh()
            return true
        case #selector(NSResponder.moveDown(_:)):
            model.moveSelection(by: 1)
            refresh()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if let item = model.selected { onRun?(item) } else { NSSound.beep() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
