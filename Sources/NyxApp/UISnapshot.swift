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
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions(),
                     runningToggle: true),
              named: "tabbar-toggle-running", into: directory, background: palette.background)

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

        for name in Themes.builtin.keys.sorted() {
            var themed = config
            themed.themeName = name
            let themedPalette = Pane.resolvedPalette(for: themed)
            write(tabBar(palette: themedPalette, config: themed, tabs: 3, quickActions: quickActions()),
                  named: "theme-\(name)", into: directory, background: themedPalette.background)
            write(tabBar(palette: themedPalette, config: themed, tabs: 6,
                         quickActions: quickActions(), grouped: true),
                  named: "theme-\(name)-groups", into: directory, background: themedPalette.background)
            // The palette's selected row and the search bar are drawn from the theme too, and a
            // row highlight that works in one theme can be unreadable in another.
            write(palettePanel(palette: themedPalette, config: themed),
                  named: "theme-\(name)-palette", into: directory, background: themedPalette.background)
            write(searchBar(palette: themedPalette, query: "connection refused", readout: "3 of 47"),
                  named: "theme-\(name)-search", into: directory, background: themedPalette.background)
        }

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
            let label = tabs.tabViewItem(at: index).label.lowercased()
            write(content, named: "settings-\(label)\(suffix)", into: directory,
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

    private static func stickyPrompt(palette: Palette, failed: Bool) -> NSView {
        let view = StickyPromptView(frame: NSRect(x: 0, y: 0, width: 900, height: 22))
        view.update(text: failed ? "$ make test" : "$ ./deploy.sh --env production --wait",
                    failed: failed, palette: palette,
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

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        view.displayIgnoringOpacity(view.bounds, in: graphics)
        NSGraphicsContext.restoreGraphicsState()

        guard let image = context.makeImage() else { return }
        let url = directory.appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
