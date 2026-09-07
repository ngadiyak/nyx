import AppKit
import NyxCore

/// The states the design review found no picture for.
///
/// Two kinds live here. The first is **hover and pressed**: the round's whole thesis is "restraint
/// at idle, clarity on hover", and not one hovered control had ever been rendered, so the thesis
/// had never been checked against a picture. Where a control has hover art, these pictures show it;
/// where it has none, the picture is byte-identical to the idle one — which is the finding, and the
/// only way to see it is to take both pictures and compare them.
///
/// The second is the long tail of options that exist and had only ever been drawn in one of their
/// values: a TUI owning the screen, `line-height` and `padding` at their extremes, the request
/// editor with its secrets revealed and with nothing in it, the quick-action editor's other two
/// kinds, the watch popover's other stop rule and its five conditions, a palette longer than its
/// panel, and the project bar's other sentence.
enum StateSnapshot {
    static func run(into directory: URL, config: Config) {
        let palette = Pane.resolvedPalette(for: config)
        let palettes: [(String, Palette)] = [("nyx-dark", Themes.builtin["nyx-dark"] ?? palette),
                                             ("nyx-light", Themes.builtin["nyx-light"] ?? palette)]
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

        hoverAndPressed(into: directory, config: config, palettes: palettes,
                        appearances: appearances)
        sheetStates(into: directory, config: config, palette: palette, appearances: appearances)
        paletteAndBarStates(into: directory, config: config, palette: palette,
                            appearances: appearances)
        settingsChrome(into: directory, appearances: appearances)
    }

    // MARK: - Hover and pressed

    private static func hoverAndPressed(into directory: URL, config: Config,
                                        palettes: [(String, Palette)],
                                        appearances: [(String, NSAppearance.Name)]) {
        let palette = Pane.resolvedPalette(for: config)
        // The tab bar, hovered at each of its four kinds of target, driven through the real
        // `mouseMoved` with a synthesised event. `TabBarView.mouseMoved` sets a tooltip and a
        // cursor and asks for no redraw, so every one of these comes out byte-identical to
        // `tabbar-tabs.png` -- the bar has no hover drawing at all. The tooltip is printed as
        // evidence that the pointer really did land on the control the file is named after.
        //
        // The x of each target is *found*, not written down: the bar sweeps the pointer across
        // itself two points at a time and stops at the first place whose tooltip is the one being
        // looked for. `TabBarLabels` is NyxCore and is the same string the accessibility label
        // uses, so a layout change moves the picture rather than silently mis-aiming it -- which
        // is what four hand-written x values did on the first run (two of them landed on the wrong
        // control and the pictures were named after controls the pointer never touched).
        let targets: [(String, (String) -> Bool)] = [
            ("tab", { $0 == "nyx — zsh" }),
            ("close", { $0.hasPrefix("Close ") }),
            ("new-tab", { $0 == TabBarLabels.newTab }),
            ("tab-list", { $0 == TabBarLabels.tabList }),
            ("quick-action", { $0.hasPrefix("Caffeine") }),
        ]
        for (name, matches) in targets {
            let bar = tabBar(palette: palette, config: config)
            var found: CGFloat?
            var x: CGFloat = 0
            while x < bar.bounds.width {
                if let event = NSEvent.mouseEvent(with: .mouseMoved,
                                                  location: NSPoint(x: x, y: bar.bounds.midY),
                                                  modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 0,
                                                  pressure: 0) {
                    bar.mouseMoved(with: event)
                    if let tip = bar.toolTip, matches(tip) { found = x; break }
                }
                x += 2
            }
            let note = "hover tabbar \(name): x=\(found.map { String(Int($0)) } ?? "not found") "
                + "tooltip \(bar.toolTip ?? "none")\n"
            FileHandle.standardError.write(note.data(using: .utf8)!)
            UISnapshot.write(bar, named: "tabbar-hovered-\(name)", into: directory,
                             background: palette.background)
        }

        for (paletteName, themePalette) in palettes {
            for (appearanceName, appearance) in appearances {
                let suffix = "\(paletteName)-\(appearanceName)"
                // The gutter under a pointer. Hover is not the view's own state: `Pane.render`
                // resolves which block the pointer is on and asks `CommandBlockChrome.gutterCap`
                // for a chevron in place of that block's cap, so a picture of a hovered gutter is
                // a picture of the caps that call produces. Rows 0 and 1 are the hovered block's
                // two chevrons -- pointing down where pressing folds, right where it unfolds --
                // against the untouched marks of the blocks either side of it.
                let cell = ceil(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).ascender
                                - NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).descender)
                let gutter = PromptGutterView(frame: NSRect(x: 0, y: 0,
                                                            width: CGFloat(PromptGutter.hitWidth),
                                                            height: cell * 4))
                gutter.appearance = NSAppearance(named: appearance)
                _ = gutter.update(caps: [0: .init(shape: .chevronDown, tone: .success, isPressable: true),
                                         1: .init(shape: .chevronRight, tone: .failure, isPressable: true),
                                         2: .init(shape: .hollow, tone: .running, isPressable: true),
                                         3: .init(shape: .solid, tone: .success, isPressable: true)],
                                  labels: [0: "Command on line 1 succeeded. Fold its output. Option-click selects its output.",
                                           1: "Command on line 2 failed. Unfold its output. Option-click selects its output.",
                                           2: "Command on line 3 is still running.",
                                           3: "Command on line 4 succeeded. Fold its output. Option-click selects its output."],
                                  palette: themePalette, cellHeight: cell, padding: 8, topPadding: 0)
                gutter.layoutSubtreeIfNeeded()
                UISnapshot.write(gutter, named: "gutter-marks-hovered-\(suffix)", into: directory,
                                 background: themePalette.background)

                // Each pill of the hover strip in its pressed art. `NSButton.highlight(true)` is
                // what a mouse-down does to a button; the *hovered* art of an `.inline` bezel is
                // AppKit's own tracking and cannot be reached without a window, which is why there
                // is no `-hovered-` strip picture -- see the report.
                for (label, title, header, controls) in strippedButtons() {
                    let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: cell))
                    view.appearance = NSAppearance(named: appearance)
                    view.update(header: header, controls: controls, palette: themePalette,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                    let size = view.intrinsicContentSize
                    view.frame = NSRect(x: 0, y: 0, width: size.width, height: cell)
                    view.layoutSubtreeIfNeeded()
                    press(title, in: view)
                    UISnapshot.write(view, named: "block-header-pressed-\(label)-\(suffix)",
                                     into: directory, background: themePalette.background)
                }

                // The remote strip's own button, pressed. Its title is invisible at rest whenever
                // the theme and the appearance disagree (the 1.7:1 finding); this says whether
                // pressing it makes it any more visible.
                var state = AttachState(hostName: "Mac mini (office)", title: "swift test")
                state.phase = .ended("Mac mini (office)")
                state.role = .writer
                let strip = RemoteStripView(frame: NSRect(x: 0, y: 0, width: 900, height: cell))
                strip.appearance = NSAppearance(named: appearance)
                strip.update(state: state, palette: themePalette,
                             font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                strip.layoutSubtreeIfNeeded()
                press("Close", in: strip)
                UISnapshot.write(strip, named: "remote-strip-pressed-\(suffix)", into: directory,
                                 background: themePalette.background)
            }
        }

        // The banner's and the project bar's buttons, pressed. Both are AppKit surfaces, so the
        // palette has no say and only the appearance does.
        for (name, appearance) in appearances {
            let banner = ConfigBanner()
            banner.appearance = NSAppearance(named: appearance)
            banner.showProblems([ConfigDiagnostic(line: 12,
                                                  message: "invalid value for 'font-size': 'eighteen'")])
            opened(banner, width: 900, height: 32)
            press("Edit Config", in: banner)
            UISnapshot.write(banner, named: "config-banner-pressed-\(name)", into: directory,
                             background: palette.background)

            let bar = ProjectActionsBar(frame: .zero)
            bar.appearance = NSAppearance(named: appearance)
            bar.show(message: "nyx changed its actions (3). They will not run until you look at "
                     + "them again.", changed: true)
            opened(bar, width: 900, height: 32)
            press("Review…", in: bar)
            UISnapshot.write(bar, named: "project-bar-pressed-\(name)", into: directory,
                             background: palette.background)
        }
    }

    /// The five pressable pills, each on a header that shows it.
    private static func strippedButtons() -> [(String, String, BlockHeader, OverlayControls)] {
        let finished = BlockHeader(id: 1, state: .finished, folded: false, hasOutput: true,
                                   anyFolds: true, notifyArmed: false, summary: "8.8s")
        let request = BlockHeader(id: 2, state: .finished, folded: false, hasOutput: true,
                                  anyFolds: false, notifyArmed: false, summary: "",
                                  httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                                  isHTTP: true, bodyIsJSON: true)
        let watched = BlockHeader(id: 3, state: .finished, folded: false, hasOutput: true,
                                  anyFolds: false, notifyArmed: false, summary: "",
                                  httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                                  isHTTP: true, bodyIsJSON: true,
                                  watch: GridScene.watchHeader(runs: 11))
        return [("copy", "Copy", finished, .full),
                ("more", "\u{22EF}", finished, .full),
                ("chevron", "\u{25BE}", finished, .full),
                ("lens", "{ }", request, .full),
                ("stop", "Stop", watched, .full)]
    }

    /// Puts a named button into its pressed art, by the title it draws.
    ///
    /// `BlockHeaderView.style` sets `attributedTitle`, so the plain `title` is not what is on the
    /// button; both are matched. A press that finds nothing prints, because a picture named
    /// `-pressed-copy-` that has no pressed button in it is worse than no picture.
    private static func press(_ title: String, in view: NSView) {
        let buttons = UISnapshot.descendants(of: view).compactMap { $0 as? NSButton }
        guard let button = buttons.first(where: {
            $0.title == title || $0.attributedTitle.string == title
        }) else {
            FileHandle.standardError.write(
                "pressed-state snapshot: no button titled \"\(title)\" in \(type(of: view))\n"
                    .data(using: .utf8)!)
            return
        }
        button.highlight(true)
    }

    /// Both banners slide in from a zero height constraint and there is no run loop here.
    private static func opened(_ view: NSView, width: CGFloat, height: CGFloat) {
        for constraint in view.constraints
        where constraint.firstAttribute == .height && constraint.firstItem === view {
            constraint.constant = height
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
    }

    private static func tabBar(palette: Palette, config: Config) -> TabBarView {
        let bar = TabBarView()
        bar.setColors(palette: palette)
        bar.setQuickActions(UISnapshot.quickActions())
        let titles = ["nyx — zsh", "vim Pane.swift", "make test", "tail -f system.log"]
        bar.setTabs(titles.map { TabBarItem(title: $0, indicator: .none, label: nil) },
                    selected: 0, grouping: TabGrouping(tabCount: titles.count))
        bar.frame = NSRect(x: 0, y: 0, width: 900, height: bar.preferredHeight)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    // MARK: - Sheets and popovers whose other values had no picture

    private static func sheetStates(into directory: URL, config: Config, palette: Palette,
                                    appearances: [(String, NSAppearance.Name)]) {
        for (name, appearance) in appearances {
            // The request editor with its secrets shown. Masking is the thing this sheet must not
            // get wrong, and only the *masked* half had ever been pictured -- so nothing said what
            // the box looks like once the checkbox is ticked, which is the state a user is in while
            // they read a token to check it.
            if let view = requestEditor(palette: palette, appearance, revealed: true,
                                        line: "curl -H 'X-API-Key: 4f9c2b7ae1d84c6f' "
                                            + "-u sk_test_4eC39HqLyjWDarjtT1zdp7dc: "
                                            + "https://api.example.com/v1/items") {
                UISnapshot.write(view, named: "request-editor-revealed-\(name)", into: directory,
                                 background: UISnapshot.windowGround(appearance))
            }
            // A new, empty request: what ⌘E opens on when there is no `curl` to read. Every table
            // empty, every field placeholder -- the sheet at its least explained.
            if let view = requestEditor(palette: palette, appearance, revealed: false,
                                        line: "curl https://", tab: .params) {
                UISnapshot.write(view, named: "request-editor-empty-\(name)", into: directory,
                                 background: UISnapshot.windowGround(appearance))
            }
            // The quick-action editor's other two kinds. `send` types the command at the prompt,
            // `run` runs it in the background; the sheet says which with a pop-up and a sentence,
            // and only `toggle` had been drawn.
            for kind in [QuickActionKind.send, .run] {
                let controller = QuickActionEditor(
                    editing: QuickAction(name: kind == .send ? "Deploy" : "Tail logs", kind: kind,
                                         command: kind == .send ? "./deploy.sh --env production"
                                                                : "tail -f /var/log/system.log"))
                let view = controller.view
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 460, height: 232)
                view.layoutSubtreeIfNeeded()
                UISnapshot.write(view, named: "sheet-quick-action-\(kind.rawValue)-\(name)",
                                 into: directory, background: UISnapshot.windowGround(appearance))
            }
            // The command editor's other heading and verb. One sheet class serves "Edit and run"
            // and the multi-line paste, and only the first pair had a picture.
            let paste = CommandEditor(text: "make test\nmake lint\n./deploy.sh --env production",
                                      heading: "Run these three lines?", runTitle: "Run",
                                      palette: palette)
            let pasteView = paste.view
            pasteView.appearance = NSAppearance(named: appearance)
            pasteView.frame = NSRect(x: 0, y: 0, width: 620, height: 360)
            pasteView.layoutSubtreeIfNeeded()
            for text in UISnapshot.descendants(of: pasteView).compactMap({ $0 as? NSTextView }) {
                text.layoutManager?.ensureLayout(for: text.textContainer!)
            }
            UISnapshot.write(pasteView, named: "sheet-command-editor-paste-\(name)",
                             into: directory, background: UISnapshot.windowGround(appearance))

            // The watch popover's other stop rule, and every condition it can hold. `Until a
            // condition holds` had one picture in one condition; the other four were words in an
            // enum nobody had seen laid out beside a field.
            let counted = WatchPlanEditor.snapshotView(seed: WatchPlan(interval: 5, stop: .never)) {
                $0.stop = .count
                $0.count = "20"
            }
            counted.appearance = NSAppearance(named: appearance)
            counted.layoutSubtreeIfNeeded()
            UISnapshot.write(counted, named: "watch-plan-editor-after-n-runs-\(name)",
                             into: directory, background: UISnapshot.windowGround(appearance))
            // The value is left at whatever picking that condition leaves it -- the model's own
            // default -- rather than cleared. Cleared, every one of these opened on a red
            // validation error, which is a state the user reaches by deleting the text and not one
            // they are handed by choosing a condition; `watch-plan-editor-invalid-*` is the
            // picture of the error.
            for condition in WatchPlanEditorModel.ConditionKind.allCases {
                let view = WatchPlanEditor.snapshotView(seed: WatchPlan(interval: 5, stop: .never)) {
                    $0.stop = .until
                    $0.condition = condition
                }
                view.appearance = NSAppearance(named: appearance)
                view.layoutSubtreeIfNeeded()
                UISnapshot.write(view, named: "watch-plan-editor-\(condition.rawValue)-\(name)",
                                 into: directory, background: UISnapshot.windowGround(appearance))
            }
        }
    }

    private static func requestEditor(palette: Palette, _ appearance: NSAppearance.Name,
                                      revealed: Bool, line: String,
                                      tab: RequestEditorModel.Tab = .auth) -> NSView? {
        guard let command = CurlCommand.parse(line) else { return nil }
        let controller = RequestEditor(command: command, palette: palette)
        let view = controller.view
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        if revealed {
            // Through the checkbox, not through a back door: `revealSecrets` reads the box's state
            // and re-renders every table, and a snapshot that set the flag directly would picture a
            // state the control cannot reach.
            let boxes = UISnapshot.descendants(of: view).compactMap { $0 as? NSButton }
            if let box = boxes.first(where: { $0.title == "Reveal secrets" }) {
                // `performClick` alone: it flips the checkbox *and* fires the action. Setting
                // `state = .on` first and then clicking flips it straight back off, which is how
                // the first `request-editor-revealed-*.png` came out fully masked under a name
                // that promised the opposite.
                box.performClick(nil)
                if box.state != .on {
                    FileHandle.standardError.write(
                        "request editor: Reveal secrets did not turn on\n".data(using: .utf8)!)
                }
            }
        }
        controller.show(tab: tab)
        for text in UISnapshot.descendants(of: view).compactMap({ $0 as? NSTextView }) {
            text.layoutManager?.ensureLayout(for: text.textContainer!)
        }
        for _ in 0..<3 { view.layoutSubtreeIfNeeded() }
        for subview in UISnapshot.descendants(of: view) { subview.needsDisplay = true }
        view.needsDisplay = true
        for text in UISnapshot.descendants(of: view).compactMap({ $0 as? NSTextView }) {
            text.layoutManager?.ensureLayout(for: text.textContainer!)
        }
        return view
    }

    // MARK: - The palette and the bars

    private static func paletteAndBarStates(into directory: URL, config: Config, palette: Palette,
                                            appearances: [(String, NSAppearance.Name)]) {
        // More results than the panel shows. The list is capped at ten rows and there is no count
        // and no scroll indicator, so a query matching thirty actions looks exactly like one
        // matching ten.
        let table = KeyBindingTable(user: config.keybinds)
        let items = ActionCatalog.allMenuActions.map { action in
            PaletteItem(title: action.title,
                        detail: table.binding(for: action).map(StateSnapshot.chordText) ?? "",
                        kind: .action(action))
        }
        FileHandle.standardError.write("palette long list: \(items.count) items\n"
                                        .data(using: .utf8)!)
        let long = CommandPaletteView(palette: palette, items: items)
        long.frame = NSRect(x: 0, y: 0, width: CommandPaletteView.width, height: long.preferredHeight)
        long.layoutSubtreeIfNeeded()
        UISnapshot.write(long, named: "command-palette-long-list", into: directory,
                         background: palette.background)

        // A four-digit readout. `SearchSession.readout` is "\(position) of \(count)" with no
        // grouping and no cap, and the bar reserves no room for it: `3 of 47` was the only picture.
        let bar = SearchBarView(palette: palette)
        bar.frame = NSRect(x: 0, y: 0, width: SearchBarView.preferredWidth,
                           height: SearchBarView.height)
        if let field = bar.subviews.compactMap({ $0 as? NSTextField })
            .first(where: { $0.isEditable }) {
            field.stringValue = "e"
        }
        bar.setReadout("1234 of 5678")
        bar.layoutSubtreeIfNeeded()
        UISnapshot.write(bar, named: "search-bar-four-digit-readout", into: directory,
                         background: palette.background)

        // The project bar's *other* sentence. Only the `changed` wording had a picture, and the
        // one a user meets first is `unseen`: a directory that has never been approved.
        let actions = [QuickAction(name: "Deploy", kind: .send, command: "./deploy.sh"),
                       QuickAction(name: "Migrate", kind: .run, command: "./migrate.sh")]
        let directoryPath = NSHomeDirectory() + "/projects/nyx"
        for (state, label) in [(ProjectActionsState.unseen(pending: ProjectActions(actions: actions, digest: "d41d8cd98f00b204")),
                                "new"),
                               (ProjectActionsState.changed(pending: ProjectActions(actions: actions, digest: "d41d8cd98f00b204")),
                                "changed")] {
            guard let message = ProjectActionsGate.barMessage(for: state, directory: directoryPath)
            else { continue }
            for (name, appearance) in appearances {
                let view = ProjectActionsBar(frame: .zero)
                view.appearance = NSAppearance(named: appearance)
                var changed = false
                if case .changed = state { changed = true }
                view.show(message: message, changed: changed)
                opened(view, width: 900, height: 32)
                UISnapshot.write(view, named: "project-bar-\(label)-\(name)", into: directory,
                                 background: palette.background)
            }
        }
    }

    /// `UISnapshot.chordText`, which is file-private there. The chord is not a decision -- the
    /// binding is, in `KeyBindingTable` -- so two spellings of the same four glyphs cannot drift
    /// into disagreeing about anything a reader would notice.
    static func chordText(_ binding: KeyBinding) -> String {
        var out = ""
        if binding.modifiers.contains(.ctrl) { out += "\u{2303}" }
        if binding.modifiers.contains(.alt) { out += "\u{2325}" }
        if binding.modifiers.contains(.shift) { out += "\u{21E7}" }
        if binding.modifiers.contains(.cmd) { out += "\u{2318}" }
        if case .char(let c) = binding.key { out += String(c).uppercased() }
        return out
    }

    // MARK: - The settings window's own chrome

    /// The whole settings window, strip and all.
    ///
    /// `writeSettings` renders one *page* at a time and says so: `NSTabView`'s strip is a stock
    /// segmented control that "draws nothing at all outside a real on-screen window". That was
    /// measured before `ChromeGround` existed, and a segmented control paints through the layer;
    /// this is the picture that says whether the strip and the window's foot are reviewable now.
    private static func settingsChrome(into directory: URL,
                                       appearances: [(String, NSAppearance.Name)]) {
        for (name, appearance) in appearances {
            let controller = SettingsWindowController(store: ConfigStore())
            guard let content = controller.window?.contentView else { continue }
            controller.window?.appearance = NSAppearance(named: appearance)
            content.appearance = NSAppearance(named: appearance)
            content.frame = NSRect(x: 0, y: 0, width: 540, height: 460)
            content.layoutSubtreeIfNeeded()
            for text in UISnapshot.descendants(of: content).compactMap({ $0 as? NSTextView }) {
                text.layoutManager?.ensureLayout(for: text.textContainer!)
            }
            UISnapshot.write(content, named: "settings-window-\(name)", into: directory,
                             background: UISnapshot.windowGround(appearance))
        }
    }
}
