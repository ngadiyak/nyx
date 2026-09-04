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

        write(searchBar(palette: palette), named: "search-bar", into: directory,
              background: palette.background)
        write(palettePanel(palette: palette, config: config), named: "command-palette", into: directory,
              background: palette.background)
        write(banner(), named: "config-banner", into: directory, background: palette.background)

        for name in Themes.builtin.keys.sorted() {
            var themed = config
            themed.themeName = name
            let themedPalette = Pane.resolvedPalette(for: themed)
            write(tabBar(palette: themedPalette, config: themed, tabs: 3, quickActions: quickActions()),
                  named: "theme-\(name)", into: directory, background: themedPalette.background)
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
                               quickActions: [QuickAction], grouped: Bool = false) -> NSView {
        let bar = TabBarView()
        bar.setColors(palette: palette)
        bar.setQuickActions(quickActions)

        var grouping = TabGrouping(tabCount: tabs)
        if grouped, let group = grouping.newGroup(named: "deploy", colorIndex: 2, fromTabAt: 1) {
            grouping.add(tabAt: 2, toGroup: group.id)
        }

        let titles = ["nyx — zsh", "vim Pane.swift", "make test", "tail -f system.log",
                      "ssh prod-web-01", "docker compose"]
        let items = (0..<tabs).map { index in
            TabBarItem(title: titles[index % titles.count],
                       indicator: index == 2 ? .activity : (index == 3 ? .bell : TabIndicator.none))
        }
        bar.setTabs(items, selected: 0, grouping: grouping)
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: bar.preferredHeight)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private static func searchBar(palette: Palette) -> NSView {
        let bar = SearchBarView(palette: palette)
        bar.frame = NSRect(x: 0, y: 0, width: SearchBarView.preferredWidth, height: SearchBarView.height)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    private static func palettePanel(palette: Palette, config: Config) -> NSView {
        let table = KeyBindingTable(user: config.keybinds)
        var items: [PaletteItem] = ActionCatalog.allMenuActions.prefix(8).map { action in
            PaletteItem(title: action.title,
                        detail: table.binding(for: action).map(chordText) ?? "",
                        kind: .action(action))
        }
        items.append(PaletteItem(title: "dracula", detail: "Theme", kind: .theme("dracula")))
        items.append(PaletteItem(title: "Start Caffeine", detail: "Quick action", kind: .quickAction(0)))

        let view = CommandPaletteView(palette: palette, items: items)
        view.frame = NSRect(x: 0, y: 0, width: CommandPaletteView.width, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()
        return view
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

    private static func banner() -> NSView {
        let banner = ConfigBanner()
        banner.showProblems([ConfigDiagnostic(line: 12, message: "invalid value for 'font-size': 'eighteen'")])
        banner.frame = NSRect(x: 0, y: 0, width: 900, height: 28)
        banner.layoutSubtreeIfNeeded()
        return banner
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
