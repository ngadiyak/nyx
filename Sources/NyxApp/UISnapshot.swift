import AppKit
import NyxCore

/// Renders the window chrome to PNG files, offscreen, and exits.
///
/// This exists because the design cannot otherwise be looked at. The machine Nyx is built on denies
/// screen recording, so `screencapture` returns nothing and no amount of running the app produces a
/// picture of it -- which leaves colour, spacing and type as the one part of the work with no
/// feedback loop at all. `cacheDisplay(in:to:)` draws a view into a bitmap without involving the
/// window server, and needs no permission, so the chrome can be rendered and inspected like any
/// other output.
///
/// Metal-backed content is *not* captured this way -- a `CAMetalLayer` has nothing for AppKit to
/// draw -- so the terminal grid itself is covered by the offscreen renderer in `SnapshotTests`
/// instead. Between the two, every pixel Nyx draws can be looked at.
///
/// Run with:
///
///     NYX_UI_SNAPSHOT=/tmp/shots ./build/Nyx.app/Contents/MacOS/Nyx
enum UISnapshot {
    static var requestedDirectory: URL? {
        ProcessInfo.processInfo.environment["NYX_UI_SNAPSHOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static func run(into directory: URL, config: Config) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let palette = Pane.resolvedPalette(for: config)

        write(tabBar(palette: palette, config: config, tabs: 1, quickActions: quickActions()),
              named: "tabbar-one-tab", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions()),
              named: "tabbar-tabs", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 6, quickActions: quickActions(), grouped: true),
              named: "tabbar-groups", into: directory, background: palette.background)

        // The states nobody renders are the states nobody has looked at.
        write(tabBar(palette: palette, config: config, tabs: 20, quickActions: quickActions()),
              named: "tabbar-20-tabs", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions(), width: 420),
              named: "tabbar-narrow-420", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions(), width: 300),
              named: "tabbar-narrow-300", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 6, quickActions: quickActions(),
                     grouped: true, collapsed: true),
              named: "tabbar-group-collapsed", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: []),
              named: "tabbar-no-quick-actions", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 6, quickActions: quickActions(),
                     grouped: true, twoGroups: true),
              named: "tabbar-two-groups", into: directory, background: palette.background)
        write(searchBar(palette: palette), named: "search-bar", into: directory,
              background: palette.background)
        write(searchBar(palette: palette, query: "connection refused", readout: "3 of 47"),
              named: "search-bar-typed", into: directory, background: palette.background)
        write(searchBar(palette: palette, query: "zzzz", readout: "no matches", allTabs: true),
              named: "search-bar-all-tabs", into: directory, background: palette.background)

        write(palettePanel(palette: palette, config: config), named: "command-palette", into: directory,
              background: palette.background)
        write(palettePanel(palette: palette, config: config, query: "spl"),
              named: "command-palette-filtered", into: directory, background: palette.background)
        write(palettePanel(palette: palette, config: config, query: "zzqq"),
              named: "command-palette-no-matches", into: directory, background: palette.background)

        // Both banners paint themselves in a system colour and label themselves in `labelColor`,
        // neither of which is the terminal's theme -- so how they read depends on the *system*
        // appearance, and both have to be looked at.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            write(banner(appearance), named: "config-banner-\(name)", into: directory,
                  background: palette.background)
            write(banner(appearance, note: true), named: "config-banner-note-\(name)",
                  into: directory, background: palette.background)
            write(projectBar(appearance), named: "project-bar-\(name)", into: directory,
                  background: palette.background)
            write(quickActionSheet(appearance), named: "sheet-quick-action-\(name)",
                  into: directory, background: windowGround(appearance))
            write(commandEditorSheet(palette: palette, appearance),
                  named: "sheet-command-editor-\(name)", into: directory,
                  background: windowGround(appearance))
            writeSettings(into: directory, appearance: appearance, suffix: "-\(name)")
        }
        write(stickyPrompt(palette: palette, failed: false), named: "sticky-prompt", into: directory,
              background: palette.background)
        write(stickyPrompt(palette: palette, failed: true), named: "sticky-prompt-failed",
              into: directory, background: palette.background)

        // The overlay's shipping height is one cell row -- what `Pane.cellSizePoints` gives it at
        // the default font -- not an arbitrary round number. Rendering the snapshot shorter than
        // that hid a real bug (Important 4): a stack pinned to both edges of a view shorter than
        // its fitting size breaks a required constraint every frame.
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let rowHeight = ceil(defaultFont.ascender - defaultFont.descender + defaultFont.leading)
        for (name, header) in blockHeaderStates() {
            // The `-light` and `-dark` pair is now the *same* picture on purpose: `update` sets the
            // view's appearance from the palette, so the system's has no say. That is the fix for
            // the disabled Copy reading at 1.13:1 in Light Mode over the dark theme; a pair that
            // differs again is that bug coming back.
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight))
                view.appearance = NSAppearance(named: appearance)
                view.update(header: header, controls: .full, palette: palette,
                            font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                let size = view.intrinsicContentSize
                view.frame = NSRect(x: 0, y: 0, width: size.width, height: rowHeight)
                view.layoutSubtreeIfNeeded()
                write(view, named: "block-header-\(name)-\(appearance == .aqua ? "light" : "dark")",
                      into: directory, background: palette.background)
            }
        }
        // The two narrower strips. A crowded command line leaves no room for a 20-column strip, and
        // one drawn anyway covers the end of the command it describes -- so the summary goes first
        // and then Copy, and the ⋯ menu and the chevron, which between them reach every action,
        // never do. These are what `CommandBlockChrome.overlayPlacement` picks between.
        if let failed = blockHeaderStates().first(where: { $0.0 == "failed" })?.1 {
            for (name, controls) in [("nocopy", OverlayControls.noCopy), ("minimal", .minimal)] {
                let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight))
                view.appearance = NSAppearance(named: .darkAqua)
                view.update(header: failed, controls: controls, palette: palette,
                            font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                let size = view.intrinsicContentSize
                view.frame = NSRect(x: 0, y: 0, width: size.width, height: rowHeight)
                view.layoutSubtreeIfNeeded()
                write(view, named: "block-header-\(name)-dark", into: directory,
                      background: palette.background)
            }
        }
        // The gutter's four marks, in one picture. A no-output command's dot is identical to any
        // other succeeded one on purpose -- it is a record of what happened, and the difference is
        // that it offers no tooltip, no pointing hand and no accessibility button, none of which a
        // still picture can show. The running mark is the one thing here that is a shape rather
        // than a colour: hollow, so "in progress" survives being looked at in greyscale. The
        // `-light` and `-dark` pair is byte-identical for the same reason the block-header pair is:
        // the view paints from the palette, so the system appearance has no say. A pair that
        // differs is that bug coming back.
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let cell = ceil(defaultFont.ascender - defaultFont.descender + defaultFont.leading)
            // The shipping width: the gutter takes at most `PromptGutter.maximumWidth` of the
            // pane's own padding, so a wider picture would flatter marks that are really 6 points.
            let width = CGFloat(PromptGutter.width(padding: Double(8)))
            let gutter = PromptGutterView(frame: NSRect(x: 0, y: 0, width: width, height: cell * 4))
            gutter.appearance = NSAppearance(named: appearance)
            gutter.update(marks: [.succeeded, .failed, .running, .succeeded],
                          folded: [false, true, false, false],
                          hasOutput: [true, true, true, false],
                          palette: palette, cellHeight: cell, topPadding: 0)
            gutter.layoutSubtreeIfNeeded()
            write(gutter, named: "gutter-marks-\(name)", into: directory, background: palette.background)
        }
        // One state against the light built-in theme, in the aqua appearance: everything above
        // uses `nyx-dark` (the default config's theme) under both system appearances, which never
        // looks at a *light theme's own* colours.
        if let lightPalette = Themes.builtin["nyx-light"],
           let finished = blockHeaderStates().first(where: { $0.0 == "finished" })?.1 {
            let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight))
            view.appearance = NSAppearance(named: .aqua)
            view.update(header: finished, controls: .full, palette: lightPalette,
                        font: .monospacedSystemFont(ofSize: 12, weight: .regular))
            let size = view.intrinsicContentSize
            view.frame = NSRect(x: 0, y: 0, width: size.width, height: rowHeight)
            view.layoutSubtreeIfNeeded()
            write(view, named: "block-header-finished-light-theme", into: directory,
                  background: lightPalette.background)
        }
        write(stickyPrompt(palette: palette, failed: true, summary: "exit 2 \u{b7} 8.8s"),
              named: "sticky-prompt-summary", into: directory, background: palette.background)

        for name in Themes.builtin.keys.sorted() {
            var themed = config
            themed.themeName = name
            let themedPalette = Pane.resolvedPalette(for: themed)
            // The whole theme on one page: the sixteen against each other and against the
            // background, and every colour Nyx derives from them shown doing the job it was
            // derived for. Everything else here is one control in one state; this is the sheet
            // that makes "invisible in gruvbox" a thing you see rather than a thing you compute.
            write(themeSheet(palette: themedPalette, name: name),
                  named: "theme-\(name)-colours", into: directory, background: themedPalette.background)
            write(tabBar(palette: themedPalette, config: themed, tabs: 3, quickActions: quickActions()),
                  named: "theme-\(name)", into: directory, background: themedPalette.background)
            write(tabBar(palette: themedPalette, config: themed, tabs: 6,
                         quickActions: quickActions(), grouped: true),
                  named: "theme-\(name)-groups", into: directory, background: themedPalette.background)
            // The palette's selected row and the search bar are drawn from the theme too, and a
            // row highlight that works in one theme can be unreadable in another.
            write(palettePanel(palette: themedPalette, config: themed),
                  named: "theme-\(name)-palette", into: directory, background: themedPalette.background)
            // Filtered, because the characters a query matched are drawn in a colour of their own
            // and the unfiltered list never shows it.
            write(palettePanel(palette: themedPalette, config: themed, query: "spl"),
                  named: "theme-\(name)-palette-filtered", into: directory,
                  background: themedPalette.background)
            write(searchBar(palette: themedPalette, query: "connection refused", readout: "3 of 47"),
                  named: "theme-\(name)-search", into: directory, background: themedPalette.background)
        }

        // Last, because starting a toggle leaves it running in the shared runner and every tab bar
        // rendered afterwards would draw its quick action in the "on" state -- which is how every
        // themed bar above came out with a filled Caffeine chip nobody had asked for.
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions(),
                     runningToggle: true),
              named: "tabbar-toggle-running", into: directory, background: palette.background)

        FileHandle.standardError.write("wrote UI snapshots to \(directory.path)\n".data(using: .utf8)!)
    }

    // MARK: - The pieces

    private static func quickActions() -> [QuickAction] {
        [
            QuickAction(name: "Caffeine", kind: .toggle, command: "caffeinate -d"),
            QuickAction(name: "Deploy", kind: .send, command: "./deploy.sh"),
        ]
    }

    private static func tabBar(palette: Palette, config: Config, tabs: Int,
                               quickActions: [QuickAction], grouped: Bool = false,
                               collapsed: Bool = false, twoGroups: Bool = false,
                               runningToggle: Bool = false, width: CGFloat = 900) -> NSView {
        let bar = TabBarView()
        bar.setColors(palette: palette)
        if runningToggle {
            // The "on" look of a toggle is the one state the button exists to show, so it has to be
            // rendered rather than reasoned about. A short sleep is alive for as long as this takes.
            let toggle = QuickAction(name: "Caffeine", kind: .toggle, command: "sleep 20")
            QuickActionRunner.shared.perform(toggle, in: nil, pane: nil)
            bar.setQuickActions([toggle, QuickAction(name: "Deploy", kind: .send, command: "./deploy.sh")])
        } else {
            bar.setQuickActions(quickActions)
        }

        var grouping = TabGrouping(tabCount: tabs)
        if grouped, let group = grouping.newGroup(named: "deploy", colorIndex: 2, fromTabAt: 1) {
            _ = grouping.add(tabAt: 2, toGroup: group.id)
            if collapsed { grouping.setCollapsed(true, forGroup: group.id) }
        }
        if twoGroups, let second = grouping.newGroup(named: "logs", colorIndex: 4, fromTabAt: 4) {
            _ = grouping.add(tabAt: 5, toGroup: second.id)
        }

        let titles = ["nyx — zsh", "vim Pane.swift", "make test", "tail -f system.log",
                      "ssh prod-web-01", "docker compose"]
        let items = (0..<tabs).map { index in
            TabBarItem(title: titles[index % titles.count],
                       indicator: index == 2 ? .activity : (index == 3 ? .bell : TabIndicator.none))
        }
        bar.setTabs(items, selected: 0, grouping: grouping)
        bar.frame = NSRect(x: 0, y: 0, width: width, height: bar.preferredHeight)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// One page per theme: the sixteen ANSI colours as blocks *and* as text, the foreground,
    /// cursor and selection doing what they do, and every colour `Palette` derives shown in its
    /// own use. Read it as a checklist -- anything you cannot see here you cannot see in the app.
    private static func themeSheet(palette: Palette, name: String) -> NSView {
        ThemeSheetView(palette: palette, name: name)
    }

    private static func searchBar(palette: Palette, query: String = "", readout: String = "",
                                  allTabs: Bool = false) -> NSView {
        let bar = SearchBarView(palette: palette)
        bar.frame = NSRect(x: 0, y: 0, width: SearchBarView.preferredWidth, height: SearchBarView.height)
        // Driven the way a user drives it -- typed into the field, clicked on the toggle -- rather
        // than through setters added for the snapshot, so what is rendered is what they would see.
        if let field = bar.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
            field.stringValue = query
        }
        bar.setReadout(readout)
        if allTabs, let scope = bar.subviews.compactMap({ $0 as? NSButton }).first {
            scope.performClick(nil)
        }
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private static func palettePanel(palette: Palette, config: Config, query: String = "") -> NSView {
        let table = KeyBindingTable(user: config.keybinds)
        var items: [PaletteItem] = ActionCatalog.allMenuActions.prefix(8).map { action in
            PaletteItem(title: action.title,
                        detail: table.binding(for: action).map(chordText) ?? "",
                        kind: .action(action))
        }
        items.append(PaletteItem(title: "dracula", detail: "Theme", kind: .theme("dracula")))
        items.append(PaletteItem(title: "Start Caffeine", detail: "Quick action", kind: .quickAction(0)))

        let view = CommandPaletteView(palette: palette, items: items)
        if !query.isEmpty,
           let field = view.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) {
            field.stringValue = query
            // The same call the field editor makes on a keystroke: it re-ranks and redraws.
            view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                   object: field))
        }
        view.frame = NSRect(x: 0, y: 0, width: CommandPaletteView.width, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private static func quickActionSheet(_ appearance: NSAppearance.Name) -> NSView {
        let controller = QuickActionEditor(editing: QuickAction(name: "Caffeine", kind: .toggle,
                                                                command: "caffeinate -d"))
        let view = controller.view
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 232)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private static func commandEditorSheet(palette: Palette, _ appearance: NSAppearance.Name) -> NSView {
        let text = """
        curl -sS -X POST https://api.example.com/v2/deployments \\
          -H 'Authorization: Bearer $TOKEN' \\
          -H 'Content-Type: application/json' \\
          -d '{"service":"web","ref":"main","wait":true}'
        """
        let controller = CommandEditor(text: text, heading: "Edit and run",
                                       runTitle: "Run", palette: palette)
        let view = controller.view
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 360)
        view.layoutSubtreeIfNeeded()
        // A text view generates its glyphs lazily, on the first real display pass, so without this
        // the sheet renders as an empty box and the one thing it is for cannot be looked at.
        for textView in descendants(of: view).compactMap({ $0 as? NSTextView }) {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }
        return view
    }

    /// One PNG per settings page: an `NSTabView` shows one at a time, so a single render of the
    /// window would leave three of the four pages unlooked-at, which is the whole problem.
    private static func writeSettings(into directory: URL, appearance: NSAppearance.Name,
                                      suffix: String) {
        let controller = SettingsWindowController(store: ConfigStore())
        guard let content = controller.window?.contentView,
              let tabs = content.subviews.compactMap({ $0 as? NSTabView }).first else { return }
        // On the *window*, not the content view. An `NSTabView`'s strip resolves its appearance
        // against the window, so setting it here left the four tab labels rendering as blank white
        // pills -- a review tool that lies about the interface is worse than no review tool.
        controller.window?.appearance = NSAppearance(named: appearance)
        content.appearance = NSAppearance(named: appearance)
        content.frame = NSRect(x: 0, y: 0, width: 540, height: 460)
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index)
            content.layoutSubtreeIfNeeded()
            let item = tabs.tabViewItem(at: index)
            let label = item.label.lowercased()
            // The page, not the whole window. `NSTabView`'s strip is a stock segmented control that
            // draws nothing at all outside a real on-screen window, so including it produced an
            // empty white pill above every settings page and made the tool look broken. It is also
            // the one part of this window nobody needs to review: it is Apple's, not ours.
            guard let page = item.view else { continue }
            page.layoutSubtreeIfNeeded()
            write(page, named: "settings-\(label)\(suffix)", into: directory,
                  background: windowGround(appearance))
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The colour a real sheet or settings window puts behind these controls. Rendering them on the
    /// terminal's own background instead would judge a contrast that never happens on screen.
    private static func windowGround(_ appearance: NSAppearance.Name) -> RGB {
        var result = RGB(236, 236, 236)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) {
                result = RGB(UInt8(color.redComponent * 255),
                             UInt8(color.greenComponent * 255),
                             UInt8(color.blueComponent * 255))
            }
        }
        return result
    }

    /// One `BlockHeader` per state the overlay can be in: the states nobody renders are the states
    /// nobody has looked at.
    private static func blockHeaderStates() -> [(String, BlockHeader)] {
        [
            ("finished", BlockHeader(id: 1, state: .finished, folded: false, hasOutput: true, anyFolds: false, notifyArmed: false, summary: "8.8s")),
            ("failed", BlockHeader(id: 2, state: .failed(status: 1), folded: false, hasOutput: true, anyFolds: false, notifyArmed: false, summary: "exit 1 \u{b7} 8.8s")),
            ("running", BlockHeader(id: 3, state: .running(elapsed: 12), folded: false, hasOutput: true, anyFolds: false, notifyArmed: true, summary: "12s")),
            ("folded", BlockHeader(id: 4, state: .finished, folded: true, hasOutput: true, anyFolds: true, notifyArmed: false, summary: "8.8s")),
            ("no-output", BlockHeader(id: 5, state: .finished, folded: false, hasOutput: false, anyFolds: false, notifyArmed: false, summary: "")),
        ]
    }

    private static func stickyPrompt(palette: Palette, failed: Bool, summary: String = "") -> NSView {
        let view = StickyPromptView(frame: NSRect(x: 0, y: 0, width: 900, height: 22))
        view.update(text: failed ? "$ make test" : "$ ./deploy.sh --env production --wait",
                    summary: summary, failed: failed, palette: palette,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private static func projectBar(_ appearance: NSAppearance.Name) -> NSView {
        let bar = ProjectActionsBar(frame: .zero)
        bar.appearance = NSAppearance(named: appearance)
        bar.show(message: "This folder has a .nyx/project.conf that has changed since you approved it.",
                 changed: true)
        return opened(bar, width: 900, height: 32)
    }

    private static func chordText(_ binding: KeyBinding) -> String {
        var out = ""
        if binding.modifiers.contains(.ctrl) { out += "⌃" }
        if binding.modifiers.contains(.alt) { out += "⌥" }
        if binding.modifiers.contains(.shift) { out += "⇧" }
        if binding.modifiers.contains(.cmd) { out += "⌘" }
        if case .char(let c) = binding.key { out += String(c).uppercased() }
        return out
    }

    private static func banner(_ appearance: NSAppearance.Name, note: Bool = false) -> NSView {
        let banner = ConfigBanner()
        banner.appearance = NSAppearance(named: appearance)
        if note {
            banner.showNote("The new font size applies to windows opened from now on.")
        } else {
            banner.showProblems([
                ConfigDiagnostic(line: 12, message: "invalid value for 'font-size': 'eighteen'"),
                ConfigDiagnostic(line: 30, message: "unknown key 'cursor-blink-rate'"),
            ])
        }
        return opened(banner, width: 900, height: 32)
    }

    /// Both banners slide in by animating a height constraint from zero, and an animation needs a
    /// run loop that a snapshot never reaches -- so rendered as they stand they come out empty,
    /// which is precisely why neither had ever been looked at. The constraint is set outright here,
    /// the way it would read once the slide has finished.
    private static func opened(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        for constraint in view.constraints
        where constraint.firstAttribute == .height && constraint.firstItem === view {
            constraint.constant = height
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    // MARK: - Drawing

    /// Draws on a background the way the window would, so contrast can be judged rather than
    /// guessed at -- a bar rendered on transparency tells you nothing about how it reads in place.
    private static func write(_ view: NSView, named name: String, into directory: URL,
                              background: RGB) {
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(red: CGFloat(background.r) / 255, green: CGFloat(background.g) / 255,
                             blue: CGFloat(background.b) / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)

        // `cacheDisplay`, not `displayIgnoringOpacity`.
        //
        // The custom-drawn panels here render identically either way, which is exactly why the one
        // that did not was easy to misdiagnose: `NSTabView`'s strip is a segmented control that
        // paints through the layer/CoreUI path, which `displayIgnoringOpacity` skips entirely, so
        // the settings tabs came out as four blank white pills — in *both* appearances, which is
        // the detail that rules out the appearance explanation I reached for first.
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage {
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
        } else {
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            view.displayIgnoringOpacity(view.bounds, in: graphics)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let image = context.makeImage() else { return }
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// The colour sheet drawn for `theme-<name>-colours.png`.
///
/// Not a stack of labels: every row here is a colour used the way the interface uses it -- text on
/// a fill, a fill under text, a 2px spine in the left margin -- because a swatch says a colour
/// exists and says nothing about whether you can read what is written on it. The numbers beside
/// each ANSI colour are its WCAG contrast against this theme's background, which is the one figure
/// that decides whether a program printing in that colour can be read at all.
private final class ThemeSheetView: NSView {
    private let palette: Palette
    private let name: String

    /// Room for sixteen colour rows in two columns, plus the derived block underneath.
    static let size = NSSize(width: 760, height: 620)

    init(palette: Palette, name: String) {
        self.palette = palette
        self.name = name
        super.init(frame: NSRect(origin: .zero, size: ThemeSheetView.size))
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    private static let ansiNames = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "br black", "br red", "br green", "br yellow", "br blue", "br magenta", "br cyan", "br white",
    ]

    override func draw(_ dirtyRect: NSRect) {
        nsColor(palette.background, alpha: 1).setFill()
        dirtyRect.fill()

        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let heading = NSFont.systemFont(ofSize: 15, weight: .semibold)

        draw("\(name)  —  \(palette.isLight ? "light" : "dark"), foreground \(contrast(palette.foreground)) on background",
             at: NSPoint(x: 20, y: 16), font: heading, color: palette.foreground)

        // The sixteen. Left column normal, right column bright, so a bright that is dimmer than its
        // own normal -- or identical to it -- is one glance rather than a memory test.
        for index in 0..<16 {
            let column = index / 8, row = index % 8
            let x = 20.0 + Double(column) * 370
            let y = 56.0 + Double(row) * 26
            let colour = palette.colors[index]
            nsColor(colour, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 34, height: 18),
                         xRadius: 3, yRadius: 3).fill()
            draw(String(format: "%2d %-11@", index, ThemeSheetView.ansiNames[index] as NSString),
                 at: NSPoint(x: x + 42, y: y + 2), font: mono, color: palette.foreground)
            // The same colour as text on the background, which is how a program actually uses it.
            draw("The quick brown fox", at: NSPoint(x: x + 150, y: y + 2), font: mono, color: colour)
            draw(contrast(colour), at: NSPoint(x: x + 300, y: y + 2), font: mono,
                 color: palette.noteForeground)
        }

        var y = 280.0
        func band(_ label: String, _ fill: RGB, _ text: RGB, _ note: String) {
            draw(label, at: NSPoint(x: 20, y: y + 3), font: mono, color: palette.noteForeground)
            nsColor(fill, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 180, y: y, width: 300, height: 20),
                         xRadius: 4, yRadius: 4).fill()
            draw("connection refused", at: NSPoint(x: 188, y: y + 3), font: mono, color: text)
            draw(note, at: NSPoint(x: 496, y: y + 3), font: mono, color: palette.noteForeground)
            y += 28
        }

        band("selection", palette.selectionBackground,
             palette.selectionForeground ?? palette.foreground,
             String(format: "%.2f:1", RGB.contrast(palette.selectionForeground ?? palette.foreground,
                                                   palette.selectionBackground)))
        band("search match", palette.searchMatchBackground, palette.foreground,
             String(format: "%.2f:1", RGB.contrast(palette.foreground, palette.searchMatchBackground)))
        band("current match", palette.currentMatchBackground, palette.searchMatchForeground,
             String(format: "%.2f:1", RGB.contrast(palette.searchMatchForeground,
                                                   palette.currentMatchBackground)))
        band("panel selection", palette.panelSelectionBackground, palette.foreground,
             String(format: "%.2f:1", RGB.contrast(palette.foreground, palette.panelSelectionBackground)))

        // The cursor over its own background, and the note colour: both are text-sized, and both
        // have been "obviously fine" in the theme whoever tuned them had open.
        nsColor(palette.cursor, alpha: 1).setFill()
        NSRect(x: 180, y: y, width: 9, height: 18).fill()
        draw("cursor", at: NSPoint(x: 20, y: y + 3), font: mono, color: palette.noteForeground)
        draw("block cursor over a line of output", at: NSPoint(x: 196, y: y + 3), font: mono,
             color: palette.foreground)
        draw(contrast(palette.cursor), at: NSPoint(x: 496, y: y + 3), font: mono,
             color: palette.noteForeground)
        y += 28
        draw("duration note", at: NSPoint(x: 20, y: y + 3), font: mono, color: palette.noteForeground)
        draw("make test", at: NSPoint(x: 180, y: y + 3), font: mono, color: palette.foreground)
        draw("2.4s", at: NSPoint(x: 300, y: y + 3), font: mono, color: palette.noteForeground)
        draw(contrast(palette.noteForeground), at: NSPoint(x: 496, y: y + 3), font: mono,
             color: palette.noteForeground)
        y += 36

        // The three spine colours beside the rows they would mark, at the width they are drawn.
        draw("block spines", at: NSPoint(x: 20, y: y + 3), font: mono, color: palette.noteForeground)
        for (offset, entry) in [(1, "make test — exit 1"), (3, "make test — running"),
                                (2, "make test — 2.4s")].enumerated() {
            let top = y + Double(offset) * 22
            nsColor(palette.readable(entry.0), alpha: 1).setFill()
            NSRect(x: 180, y: top, width: 2, height: 18).fill()
            draw(entry.1, at: NSPoint(x: 192, y: top + 3), font: mono,
                 color: entry.0 == 1 ? palette.readable(1) : palette.foreground)
        }
        y += 74

        // Six group pills, because a group can be any of six ANSI colours and only two of them
        // have ever appeared in a snapshot.
        draw("group pills", at: NSPoint(x: 20, y: y + 4), font: mono, color: palette.noteForeground)
        var x = 180.0
        for index in 1...6 {
            let fill = palette.readable(index)
            let label = ThemeSheetView.ansiNames[index] as NSString
            let width = label.size(withAttributes: [.font: bold]).width + 18
            nsColor(fill, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 20),
                         xRadius: 5, yRadius: 5).fill()
            draw(label as String, at: NSPoint(x: x + 9, y: y + 3), font: bold,
                 color: palette.textOn(fill))
            x += width + 8
        }
        y += 32

        // The accent, in the two places the chrome puts it.
        draw("accent", at: NSPoint(x: 20, y: y + 4), font: mono, color: palette.noteForeground)
        nsColor(palette.accent, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 180, y: y, width: 84, height: 20),
                     xRadius: 5, yRadius: 5).fill()
        draw("Caffeine", at: NSPoint(x: 189, y: y + 3), font: bold,
             color: palette.textOn(palette.accent))
        nsColor(palette.panelSelectionBackground, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 276, y: y, width: 204, height: 20),
                     xRadius: 5, yRadius: 5).fill()
        let matched = NSMutableAttributedString(
            string: "Split Right",
            attributes: [.font: mono, .foregroundColor: nsColor(palette.foreground, alpha: 1)])
        for position in [0, 1, 2] {
            matched.setAttributes([.font: bold,
                                   .foregroundColor: nsColor(palette.accentText, alpha: 1)],
                                  range: NSRange(location: position, length: 1))
        }
        matched.draw(at: NSPoint(x: 285, y: y + 3))
        draw(String(format: "match %.2f:1 on the selected row",
                    RGB.contrast(palette.accentText, palette.panelSelectionBackground)),
             at: NSPoint(x: 496, y: y + 3), font: mono, color: palette.noteForeground)
    }

    private func contrast(_ colour: RGB) -> String {
        String(format: "%.2f:1", RGB.contrast(colour, palette.background))
    }

    private func draw(_ text: String, at point: NSPoint, font: NSFont, color: RGB) {
        NSAttributedString(string: text,
                           attributes: [.font: font, .foregroundColor: nsColor(color, alpha: 1)])
            .draw(at: point)
    }
}
