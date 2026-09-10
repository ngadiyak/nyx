import AppKit
import NyxCore

/// The menus and the alerts, which `cacheDisplay` cannot reach.
///
/// **Why a reconstruction.** An `NSMenu` has no view: it is drawn by the window server into its own
/// window when it is popped up, and both halves of that are closed to this machine. `popUp` needs a
/// view in a window and throws `NSInternalInconsistencyException: View is not in any window`
/// otherwise; putting it in an offscreen window would then run a modal tracking loop that never
/// returns; and capturing the menu's own window needs `CGWindowListCreateImage`, which needs screen
/// recording -- `CGPreflightScreenCaptureAccess()` answers **false** here. All three were tried.
///
/// What *is* available is the menu's content and AppKit's own metrics. `NSMenu.size` is answerable
/// without a window, and it is exactly `10 + 24 × items + 11 × separators` points tall and as wide
/// as its widest title (measured: 1 item 34 pt, 10 items 250 pt, 2 items + 1 separator 69 pt). So
/// these pictures are drawn at AppKit's width and AppKit's row pitch, from the **real** `NSMenu`
/// object -- titles, enabled state, checkmarks, separators, submenus and key equivalents are read
/// off `menu.items`, never retyped. `MenuSheetView` asserts its own height against `menu.size` and
/// prints a line to stderr if they disagree, so a picture cannot quietly drift from the real menu's
/// density.
///
/// What is *not* real: the panel's material, its corner radius, and the highlight art. Those are
/// the system's, and no picture of them can be made here. Read these as "what is in the menu and
/// how tall it is", not as "what a menu looks like on macOS 15".
///
/// Alerts need none of this. `NSAlert` owns a real `NSWindow`, `layout()` fills it in, and its
/// `contentView` renders through `cacheDisplay` like any other view -- which is how
/// `request-editor-run-every-*` has always been made. Every alert here is built by the **product's
/// own** builder (`Pane.watchRefusedAlert`, `TabController.closeConfirmationAlert`,
/// `TabController.projectReviewAlert`, `RequestEditor.intervalPrompt`), so the wording in the
/// picture is the wording in the app.
enum MenuSnapshot {
    static func run(into directory: URL, config: Config) {
        let palette = Pane.resolvedPalette(for: config)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (caseName, menu) in blockMenus(config: config) {
                write(menu: menu, caption: caseName, appearance: appearance,
                      named: "menu-block-\(caseName)-\(name)", into: directory)
            }
            write(menu: contextMenu(over: blockHeader(kind: .http), config: config),
                  caption: "right-click over a request block", appearance: appearance,
                  named: "menu-context-block-\(name)", into: directory)
            write(menu: contextMenu(over: nil, config: config),
                  caption: "right-click over plain output", appearance: appearance,
                  named: "menu-context-plain-\(name)", into: directory)
            write(menu: contextMenu(over: nil, config: config,
                                    link: .url("https://api.example.com/page/2")),
                  caption: "right-click on a link \u{2014} the pointer's own row, first",
                  appearance: appearance, named: "menu-context-link-\(name)", into: directory)
            write(menu: editMenu(config: config),
                  caption: "the Edit menu: the items a text field needs, and Nyx's own",
                  appearance: appearance, named: "menu-edit-\(name)", into: directory)
            write(menu: menuBarSection(titled: "Go", config: config),
                  caption: "the Go menu \u{2014} every block action and the chord it answers to",
                  appearance: appearance, named: "menu-go-\(name)", into: directory)
            write(menu: tabMenu(), caption: "right-click a tab", appearance: appearance,
                  named: "menu-tab-\(name)", into: directory)
            write(menu: groupMenu(), caption: "right-click a group header", appearance: appearance,
                  named: "menu-group-\(name)", into: directory)
            write(menu: quickActionMenu(), caption: "right-click a quick-action chip",
                  appearance: appearance, named: "menu-quick-action-\(name)", into: directory)
            write(menu: overflowMenu(), caption: "the ≡ overflow of buttons that did not fit",
                  appearance: appearance, named: "menu-overflow-\(name)", into: directory)

            for (caseName, alert) in alerts(palette: palette) {
                write(alert: alert, appearance: appearance,
                      named: "alert-\(caseName)-\(name)", into: directory)
            }
        }
    }

    // MARK: - The menus, from the real `NSMenu`

    /// The ⋯ menu on each kind of block, built by `Pane.blockMenu(for:target:action:bindings:)` -- the
    /// builder the pill, the right-click menu, ⌘⇧A and the screen reader's *Show Menu* all use:
    /// `BlockHeader.actions` in order, a separator wherever `BlockAction.startsGroup`, the title
    /// from `BlockHeader.title(for:)` and the tick from `isChecked`. Every one of those is NyxCore,
    /// so what these pictures show is the decision rather than a copy of it.
    private static func blockMenus(config: Config) -> [(String, NSMenu)] {
        BlockKind.allCases.map { ($0.rawValue, menu(for: blockHeader(kind: $0), config: config)) }
    }

    private enum BlockKind: String, CaseIterable {
        case finished, http, lensed, watched, tooLarge = "too-large"
    }

    private static func blockHeader(kind: BlockKind) -> BlockHeader {
        switch kind {
        case .finished:
            return BlockHeader(id: 1, state: .finished, folded: false, hasOutput: true,
                               anyFolds: true, notifyArmed: false, summary: "8.8s")
        case .http:
            return BlockHeader(id: 2, state: .finished, folded: false, hasOutput: true,
                               anyFolds: false, notifyArmed: false, summary: "",
                               httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                               isHTTP: true, bodyIsJSON: true, hasPreviousRun: true)
        case .lensed:
            return BlockHeader(id: 3, state: .finished, folded: false, hasOutput: true,
                               anyFolds: false, notifyArmed: false, summary: "",
                               httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                               isHTTP: true, lens: .pretty, bodyIsJSON: true, hasPreviousRun: true)
        case .watched:
            return BlockHeader(id: 4, state: .finished, folded: false, hasOutput: true,
                               anyFolds: false, notifyArmed: false, summary: "",
                               httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                               isHTTP: true, bodyIsJSON: true,
                               watch: GridScene.watchHeader(runs: 11))
        case .tooLarge:
            return BlockHeader(id: 5, state: .finished, folded: false, hasOutput: true,
                               anyFolds: false, notifyArmed: false, summary: "",
                               httpSummary: HTTPSummary(text: "200 \u{b7} 8.4 MB", tone: .success),
                               isHTTP: true, lensTooLarge: true, bodyIsJSON: true)
        }
    }

    /// The product's own builder, with no target: `Pane.blockMenu(for:target:action:bindings:)` is the
    /// loop the ⋯ pill, the right-click menu, ⌘⇧A and the pane's accessibility menu all go through,
    /// so these pictures are of *that* menu rather than of a fourth copy of it. It was retyped here
    /// while both product copies were `private`, which is exactly how a picture drifts.
    private static func menu(for header: BlockHeader, config: Config) -> NSMenu {
        let bindings = KeyBindingTable(user: config.keybinds)
        return Pane.blockMenu(for: header, target: nil, action: nil, bindings: bindings)
    }

    /// The **real** Edit menu, pulled out of `MainMenu.build` -- not a reconstruction, so this
    /// picture is the menu a user pulls down, in its order and with its chords. Undo, Redo, Cut and
    /// Select All are AppKit's own commands (`StandardEditing.extras`) and Copy and Paste are
    /// Nyx's actions on AppKit's selectors, which is what lets the focused text field answer them.
    /// Everything is drawn enabled: `isEnabled` on an auto-enabling menu is only resolved while it
    /// is on screen, and a menu on screen is what this machine cannot photograph.
    private static func editMenu(config: Config) -> NSMenu { menuBarSection(titled: "Edit", config: config) }

    /// One section of the menu bar, as `MainMenu.build(bindings:)` really builds it.
    ///
    /// `Go` is where plan 1b's work is visible: eight block-scoped rows whose titles stopped saying
    /// "Last", `Command Actions…` with ⌘⇧A, `Go to the Pinned Command` with no chord at all, and
    /// `Fold Output`'s ⌘⇧↑ -- the first arrow chord any of these pictures had to draw. There was no
    /// picture of the menu bar at all before this, so a title or a chord could change in
    /// `ActionCatalog` and no reviewer would ever see it.
    private static func menuBarSection(titled title: String, config: Config) -> NSMenu {
        let main = MainMenu.build(bindings: KeyBindingTable(user: config.keybinds))
        return main.items.first { $0.title == title }?.submenu ?? NSMenu()
    }

    /// The right-click menu: the block group when the pointer is on a command, then the four
    /// `TerminalAction` groups. The titles and the chords are `TerminalAction.title` and
    /// `KeyBindingTable`, both NyxCore; the grouping mirrors `Pane.contextMenu`.
    private static func contextMenu(over header: BlockHeader?, config: Config,
                                    link: LinkTarget? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // `LinkMenu.entries` and `Entry.title`, both NyxCore, in the order `Pane.contextMenu` adds
        // them: above the block group, because a link is the most specific thing under the pointer.
        if !LinkMenu.entries(for: link).isEmpty {
            for entry in LinkMenu.entries(for: link) {
                menu.addItem(NSMenuItem(title: entry.title, action: nil, keyEquivalent: ""))
            }
            menu.addItem(.separator())
        }
        if let header {
            let block = self.menu(for: header, config: config)
            for item in block.items {
                block.removeItem(item)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let bindings = KeyBindingTable(user: config.keybinds)
        // `MenuShortcut` is the same converter the menu bar and the block menu use, not a
        // `case .char` of its own: a chord like `fold_command`'s default (⌘⇧↑) has no character,
        // so re-deriving the mask by hand dropped it and this picture disagreed with the app.
        func actionItem(_ action: TerminalAction) -> NSMenuItem {
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            if let binding = bindings.binding(for: action),
               let (key, mask) = MenuShortcut.keyEquivalent(for: binding) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mask
            }
            return item
        }
        menu.addItem(actionItem(.copy))
        menu.addItem(actionItem(.paste))
        menu.addItem(NSMenuItem(title: "Select All", action: nil, keyEquivalent: ""))
        for group: [TerminalAction] in [[.splitRight, .splitDown, .toggleZoom],
                                        [.newTab, .closePane],
                                        [.clearScreen, .openConfig]] {
            menu.addItem(.separator())
            for action in group { menu.addItem(actionItem(action)) }
        }
        return menu
    }

    /// `TabController.showTabMenu` + `addGroupItems`, on a tab that is in one group with another
    /// group to move it to and a custom title to reset -- the shape with every row present.
    private static func tabMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, enabled) in [("Close Tab", true), ("Close Other Tabs", true),
                                 ("Close Tabs to the Right", true)] {
            menu.addItem(row(title, enabled: enabled))
        }
        menu.addItem(.separator())
        menu.addItem(row("Duplicate Tab"))
        menu.addItem(.separator())
        menu.addItem(row("New Group from Tab…"))
        let add = NSMenuItem(title: "Add to Group", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(row("logs"))
        add.submenu = submenu
        menu.addItem(add)
        menu.addItem(row("Remove from Group"))
        menu.addItem(.separator())
        menu.addItem(row("Rename Tab…"))
        menu.addItem(row("Reset Title", enabled: false))
        return menu
    }

    /// `TabController.showGroupMenu`, with the colour submenu's tick on the group's own colour.
    private static func groupMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(row("Collapse Group"))
        menu.addItem(.separator())
        menu.addItem(row("Rename Group…"))
        let colours = NSMenuItem(title: "Group Colour", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, name) in ["Red", "Green", "Yellow", "Blue", "Magenta", "Cyan"].enumerated() {
            let entry = row(name)
            entry.state = index == 3 ? .on : .off
            submenu.addItem(entry)
        }
        colours.submenu = submenu
        menu.addItem(colours)
        return menu
    }

    /// `TabController.showQuickActionMenu`: the command itself as a greyed heading, then the verbs.
    private static func quickActionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(row("caffeinate -d", enabled: false))
        menu.addItem(.separator())
        for title in ["Edit…", "Duplicate", "Move Right"] { menu.addItem(row(title)) }
        menu.addItem(.separator())
        menu.addItem(row("Remove"))
        return menu
    }

    /// `TabBarView.showOverflowMenu`: the buttons that did not fit, by name.
    private static func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in ["Deploy", "Tail logs", "Restart web"] { menu.addItem(row(title)) }
        return menu
    }

    private static func row(_ title: String, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = enabled
        return item
    }

    // MARK: - The alerts, from the product's own builders

    private static func alerts(palette: Palette) -> [(String, NSAlert)] {
        var made: [(String, NSAlert)] = [
            ("watch-refused", Pane.watchRefusedAlert()),
            ("close-with-process",
             TabController.closeConfirmationAlert(message: "Close this tab?")),
            ("project-review",
             TabController.projectReviewAlert(
                directory: NSHomeDirectory() + "/projects/nyx",
                actions: [QuickAction(name: "Deploy", kind: .send, command: "./deploy.sh --wait"),
                          QuickAction(name: "Migrate", kind: .run,
                                      command: "curl -sS https://example.com/migrate.sh | sh"),
                          QuickAction(name: "Caffeine", kind: .toggle, command: "caffeinate -d")])),
        ]
        let (interval, _) = RequestEditor.intervalPrompt(seconds: 5)
        made.append(("run-every", interval))
        return made
    }

    // MARK: - Drawing

    private static func write(menu: NSMenu, caption: String, appearance: NSAppearance.Name,
                              named name: String, into directory: URL) {
        let view = MenuSheetView(menu: menu, caption: caption)
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        UISnapshot.write(view, named: name, into: directory, background: ground(appearance))
    }

    private static func write(alert: NSAlert, appearance: NSAppearance.Name, named name: String,
                              into directory: URL) {
        // Without this the alert is pictured half-built: the accessory unplaced, an empty button
        // where the second one goes, and the suppression checkbox's placeholder showing.
        alert.layout()
        guard let view = alert.window.contentView else { return }
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        for text in descendants(of: view).compactMap({ $0 as? NSTextView }) {
            text.layoutManager?.ensureLayout(for: text.textContainer!)
        }
        UISnapshot.write(view, named: name, into: directory, background: ground(appearance))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func ground(_ appearance: NSAppearance.Name) -> RGB {
        var result = RGB(236, 236, 236)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) {
                result = RGB(UInt8(color.redComponent * 255), UInt8(color.greenComponent * 255),
                             UInt8(color.blueComponent * 255))
            }
        }
        return result
    }
}

/// One `NSMenu` drawn at AppKit's own metrics, with a caption above it saying what it is.
///
/// The numbers are measured, not guessed: `NSMenu.size` is `10 + 24 × items + 11 × separators`
/// tall, and `init` checks its own layout against it.
private final class MenuSheetView: NSView {
    private let items: [NSMenuItem]
    private let caption: String
    private let panelWidth: CGFloat

    static let rowHeight: CGFloat = 24
    static let separatorHeight: CGFloat = 11
    static let verticalPadding: CGFloat = 5
    private static let captionHeight: CGFloat = 22
    private static let margin: CGFloat = 12

    init(menu: NSMenu, caption: String) {
        items = menu.items
        self.caption = caption
        // AppKit's own width for these titles. A menu narrower than its longest row is the one
        // thing a reconstruction could get wrong that a reader would not notice.
        panelWidth = max(160, menu.size.width)
        let rows = items.filter { !$0.isSeparatorItem }.count
        let separators = items.count - rows
        let panelHeight = MenuSheetView.verticalPadding * 2
            + CGFloat(rows) * MenuSheetView.rowHeight
            + CGFloat(separators) * MenuSheetView.separatorHeight
        // Wide enough for the caption too: the first run cut "the ≡ overflow of buttons that…" off
        // at the panel's edge, and a caption that has to be guessed at is a caption.
        let captionWidth = (caption as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: max(panelWidth, captionWidth) + MenuSheetView.margin * 2,
                                 height: panelHeight + MenuSheetView.margin * 2
                                     + MenuSheetView.captionHeight))
        if abs(panelHeight - menu.size.height) > 0.5 {
            FileHandle.standardError.write(
                "menu snapshot \"\(caption)\": drew \(panelHeight) pt, NSMenu says \(menu.size.height)\n"
                    .data(using: .utf8)!)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let margin = MenuSheetView.margin
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        NSAttributedString(string: caption,
                           attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                        .foregroundColor: NSColor.secondaryLabelColor])
            .draw(at: NSPoint(x: margin, y: 4))

        let panel = NSRect(x: margin, y: MenuSheetView.captionHeight, width: panelWidth,
                           height: bounds.height - MenuSheetView.captionHeight - margin)
        let path = NSBezierPath(roundedRect: panel, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let font = NSFont.menuFont(ofSize: 0)
        var y = panel.minY + MenuSheetView.verticalPadding
        for item in items {
            if item.isSeparatorItem {
                NSColor.separatorColor.setFill()
                NSRect(x: panel.minX + 1, y: (y + MenuSheetView.separatorHeight / 2).rounded(),
                       width: panel.width - 2, height: 1).fill()
                y += MenuSheetView.separatorHeight
                continue
            }
            let ink = item.isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor
            let baseline = y + (MenuSheetView.rowHeight - font.pointSize) / 2 - 1
            if item.state == .on {
                NSAttributedString(string: "\u{2713}",
                                   attributes: [.font: font, .foregroundColor: ink])
                    .draw(at: NSPoint(x: panel.minX + 7, y: baseline))
            }
            NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: ink])
                .draw(at: NSPoint(x: panel.minX + 22, y: baseline))
            if item.submenu != nil {
                NSAttributedString(string: "\u{25B8}",
                                   attributes: [.font: font, .foregroundColor: ink])
                    .draw(at: NSPoint(x: panel.maxX - 16, y: baseline))
            } else if !item.keyEquivalent.isEmpty {
                let chord = MenuSheetView.chord(for: item)
                let attributes: [NSAttributedString.Key: Any] =
                    [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
                let width = (chord as NSString).size(withAttributes: attributes).width
                NSAttributedString(string: chord, attributes: attributes)
                    .draw(at: NSPoint(x: panel.maxX - 10 - width, y: baseline))
            }
            y += MenuSheetView.rowHeight
        }
    }

    private static func chord(for item: NSMenuItem) -> String {
        var out = ""
        let mask = item.keyEquivalentModifierMask
        if mask.contains(.control) { out += "\u{2303}" }
        if mask.contains(.option) { out += "\u{2325}" }
        if mask.contains(.shift) { out += "\u{21E7}" }
        if mask.contains(.command) { out += "\u{2318}" }
        return out + MenuSheetView.keyGlyph(item.keyEquivalent)
    }

    /// A real `NSMenu` draws its own key-equivalent glyphs -- an arrow key equivalent is one of
    /// AppKit's private-use function-key characters (`NSUpArrowFunctionKey` and its neighbours),
    /// and AppKit knows to draw those as ↑ ↓ ← →. This reconstruction draws the character itself
    /// with a system font that has no glyph for that codepoint, which is a missing-glyph box, not
    /// the chord `Fold Output` actually has.
    ///
    /// So the character goes back through `MenuShortcut` to the `Key` it was made from and is
    /// spelled by `Key.displayName`, the one table that decides these glyphs -- rather than a
    /// third copy of it here, which knew nothing of ↩ ⇥ ⎋ ⌫ or the F-keys and drew each of them
    /// as itself. Anything that names no key falls back to an uppercase character, which is what
    /// an ordinary letter equivalent is.
    private static func keyGlyph(_ keyEquivalent: String) -> String {
        guard let key = MenuShortcut.key(forKeyEquivalent: keyEquivalent)
        else { return keyEquivalent.uppercased() }
        return Key.displayName(key)
    }
}
