import AppKit
import NyxCore
import NyxRemote

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
        useFixtureConfig()
        let palette = Pane.resolvedPalette(for: config)

        write(tabBar(palette: palette, config: config, tabs: 1, quickActions: quickActions()),
              named: "tabbar-one-tab", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions()),
              named: "tabbar-tabs", into: directory, background: palette.background)
        write(tabBar(palette: palette, config: config, tabs: 6, quickActions: quickActions(), grouped: true),
              named: "tabbar-groups", into: directory, background: palette.background)

        // The states nobody renders are the states nobody has looked at. Twelve as well as twenty:
        // twelve is a working day's tabs and the width at which `TabBarLabels` starts cutting
        // titles, and twenty is past the point where anything is readable -- the two answer
        // different questions and only the second had a picture.
        write(tabBar(palette: palette, config: config, tabs: 12, quickActions: quickActions()),
              named: "tabbar-12-tabs", into: directory, background: palette.background)
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
        write(searchBar(palette: palette, query: "zzzz", readout: noResultsReadout(), allTabs: true),
              named: "search-bar-all-tabs", into: directory, background: palette.background)
        // The miss in the ordinary, one-tab scope. `search-bar-all-tabs` had been standing in for
        // it, and it is a different picture: the scope chip is lit there, which is the one thing
        // that makes "no matches" read as "not in any tab" rather than "not in this one".
        write(searchBar(palette: palette, query: "zzzz", readout: noResultsReadout()),
              named: "search-bar-no-matches", into: directory, background: palette.background)

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
            // All three kinds, not two. `showFailure` is the one a user is most likely to meet --
            // a quick action whose command was not there -- and it had never been drawn at all, so
            // nobody had seen that it is the same amber as a config error rather than a red.
            for kind in BannerKind.allCases {
                write(banner(appearance, kind: kind),
                      named: "config-banner-\(kind == .problems ? "" : "\(kind.rawValue)-")\(name)",
                      into: directory, background: palette.background)
            }
            write(projectBar(appearance), named: "project-bar-\(name)", into: directory,
                  background: palette.background)
            write(quickActionSheet(appearance), named: "sheet-quick-action-\(name)",
                  into: directory, background: windowGround(appearance))
            write(commandEditorSheet(palette: palette, appearance),
                  named: "sheet-command-editor-\(name)", into: directory,
                  background: windowGround(appearance))
            // One picture per tab of the request editor: a tab nobody renders is a tab whose
            // badge, spacing and empty state nobody has looked at. All five on the same request --
            // Chrome's own "Copy as cURL", which is the shape most of these sheets will open on.
            for tab in RequestEditorModel.Tab.allCases {
                write(requestEditorSheet(palette: palette, appearance, tab: tab),
                      named: "request-editor-\(tab.rawValue.lowercased())-\(name)",
                      into: directory, background: windowGround(appearance))
            }
            // Every state, on *both* sides. The sheet is one class with a `side`, and the side
            // decides which controls exist -- the host shows a code, the client types one -- so a
            // state pictured only from the host's side is a state half of the users never see.
            for (side, sideName) in [(PairingFlow.Side.host, "host"),
                                     (PairingFlow.Side.client, "client")] {
                for (stateName, state) in pairingStates() {
                    write(pairingSheetView(state: state, side: side, appearance),
                          named: "pairing-\(sideName)-\(stateName)-\(name)", into: directory,
                          background: windowGround(appearance))
                }
            }
            write(invalidCodePairingSheetView(appearance), named: "pairing-code-invalid-\(name)",
                  into: directory, background: windowGround(appearance))
            writeSettings(into: directory, appearance: appearance, suffix: "-\(name)")
            // The same page with the switch off: every field, the table, Remove and both pairing
            // buttons greyed, and the status line saying why.
            writeSettings(into: directory, appearance: appearance, suffix: "-off-\(name)",
                          remoteOn: false, remotePageOnly: true)
        }
        // The two things the sheet puts *on top of itself*. A sheet over a sheet cannot be drawn
        // into one bitmap -- `cacheDisplay` renders one view tree, and the second sheet lives in
        // its own window -- so each is pictured on its own, built by the same code the sheet runs.
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            write(saveAsButtonSheet(palette: palette, appearance),
                  named: "request-editor-save-as-button-\(name)", into: directory,
                  background: windowGround(appearance))
            write(intervalPromptView(appearance), named: "request-editor-run-every-\(name)",
                  into: directory, background: windowGround(appearance))
        }

        // The request whose output is piped somewhere else: the one state of this sheet that says
        // something is unavailable, and the only way to see whether the note reads as a note.
        write(requestEditorSheet(palette: palette, .darkAqua, tab: .options,
                                 line: "curl -s https://api.example.com/v1/items | jq '.items[]'"),
              named: "request-editor-pipeline-note-dark", into: directory,
              background: windowGround(.darkAqua))
        // Two states the Chrome request has nothing to show for: a masked credential in a table,
        // and a masked one in the Auth tab. Masking is the thing this sheet must not get wrong,
        // and a picture with no secret in it proves nothing about it.
        write(requestEditorSheet(palette: palette, .darkAqua, tab: .headers,
                                 line: "curl -H 'X-API-Key: 4f9c2b7ae1d84c6f' "
                                     + "-H 'Cookie: session=8a1f3c9d2e; theme=dark' "
                                     + "-H 'Accept: application/json' https://api.example.com/v1/items"),
              named: "request-editor-headers-secret-dark", into: directory,
              background: windowGround(.darkAqua))
        write(requestEditorSheet(palette: palette, .darkAqua, tab: .auth,
                                 line: "curl -u sk_test_4eC39HqLyjWDarjtT1zdp7dc: "
                                     + "-d amount=2000 https://api.stripe.com/v1/charges"),
              named: "request-editor-auth-basic-dark", into: directory,
              background: windowGround(.darkAqua))
        // Every tab that can refuse to be edited, refusing. The brief called these "validation
        // errors"; the sheet has none -- a `curl` either parses into the form or is not opened in
        // it at all. What it *does* have is a note per tab saying that some of what is on screen
        // can only be changed on the command line, and until now only the Options one had a
        // picture. A tab whose note nobody has read is a tab that reads as broken.
        for (tab, name, line) in requestEditorNoteStates() {
            write(requestEditorSheet(palette: palette, .darkAqua, tab: tab, line: line),
                  named: "request-editor-\(name)-note-dark", into: directory,
                  background: windowGround(.darkAqua))
        }

        // The remote strip is an `NSButton` on a theme-coloured band, so unlike the block header it
        // is *not* the same picture in both appearances: the button's bezel follows the system.
        // And unlike the block header it never had a light *theme* either -- eleven states, all of
        // them a sentence, none of them ever drawn on a white pane.
        for (paletteName, themePalette) in chromePalettes(default: palette) {
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                for (stateName, state) in remoteStripStates() {
                    write(remoteStrip(state: state, palette: themePalette, appearance),
                          named: "remote-strip-\(stateName)-\(paletteName)-\(name)", into: directory,
                          background: themePalette.background)
                }
                // Every `remote-strip-*` picture is 900 pt wide, so no picture in 811 showed a strip
                // on a narrow pane -- which is the width at which the label has to choose between
                // its clauses (D9c). Two states at 300: the one with both clauses and the one whose
                // note is the whole sentence.
                for (stateName, state) in remoteStripStates()
                where stateName == "clipped" || stateName == "suspended-clipped" {
                    write(remoteStrip(state: state, palette: themePalette, appearance, width: 300),
                          named: "remote-strip-\(stateName)-narrow-\(paletteName)-\(name)",
                          into: directory, background: themePalette.background)
                }
            }
        }
        write(tabBar(palette: palette, config: config, tabs: 3, quickActions: quickActions(),
                     remoteBadgeAt: 1),
              named: "tabbar-remote-badge", into: directory, background: palette.background)
        // Two pictures, each a catalogue that could actually exist. The first is the everyday one:
        // the palette as it opens, ordinary rows and the Remote section together. The second is the
        // relay being down, which is the only state that puts a status row in the list -- and when
        // it is there, there are no live sessions to list beside it.
        write(remotePalettePanel(palette: palette, mixed: true),
              named: "command-palette-mixed-remote", into: directory, background: palette.background)
        write(remotePalettePanel(palette: palette, mixed: false), named: "command-palette-remote",
              into: directory, background: palette.background)
        // The Requests section, under the everyday rows, so it can be read as a section rather than
        // as four loose lines: four requests of four different ages, one of them long enough to be
        // cut, one carrying a password in its URL and one a port and a query. Against both built-in
        // themes, because this is the first section whose right-hand column is neither a chord nor
        // a word.
        write(requestPalettePanel(palette: palette), named: "command-palette-requests-dark",
              into: directory, background: palette.background)
        if let lightPalette = Themes.builtin["nyx-light"] {
            write(requestPalettePanel(palette: lightPalette), named: "command-palette-requests-light",
                  into: directory, background: lightPalette.background)
        }
        // The overlay's shipping height is one cell row -- what `Pane.cellSizePoints` gives it at
        // the default font -- not an arbitrary round number. Rendering the snapshot shorter than
        // that hid a real bug (Important 4): a stack pinned to both edges of a view shorter than
        // its fitting size breaks a required constraint every frame.
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let rowHeight = ceil(defaultFont.ascender - defaultFont.descender + defaultFont.leading)
        let overlayFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Every state of every piece of pane chrome, in both built-in themes and under both system
        // appearances, named `<case>-<palette>-<appearance>`.
        //
        // Four pictures per state is not four times the review. The *palette* pair is where a state
        // is genuinely different -- an accent, a dim grey, a disabled control against a white ground
        // -- and the *appearance* pair is a guard: `BlockHeaderView`, `LensFieldView`,
        // `PromptGutterView` and `StickyPromptView` all paint from the palette and pin their own
        // appearance to it, so their two pictures must come out byte-identical. A pair that differs
        // again is the Light-Mode bug coming back (a disabled Copy measured 1.13:1 over a dark theme
        // under Light Mode), and one state's pair is not enough to catch it: that was caught in
        // `BlockHeaderView` and missed in `LensFieldView`, which had to be fixed a second time.
        //
        // What this replaced was worse than incomplete: `gutter-marks-light.png` and
        // `gutter-marks-dark.png` were byte-identical *and both drawn from the dark theme*, so the
        // one file whose name promised Light Mode showed a dark gutter.
        for (paletteName, themePalette) in chromePalettes(default: palette) {
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let suffix = "\(paletteName)-\(appearanceName)"
                for (name, header, width) in blockStripStates() {
                    guard let strip = blockStrip(header: header, width: width, palette: themePalette,
                                                 appearance: appearance, rowHeight: rowHeight,
                                                 font: overlayFont) else { continue }
                    write(strip, named: "block-header-\(name)-\(suffix)", into: directory,
                          background: themePalette.background)
                }
                // The pill over the row it is really drawn on: what a user sees a moment after
                // pasting a `curl`. Pictured with the command in front of it because the whole
                // question is whether it reads as part of the line or as something floating over
                // it -- a pill on an empty background answers neither.
                write(workbenchHintRow(palette: themePalette, appearance),
                      named: "workbench-hint-\(suffix)", into: directory,
                      background: themePalette.background)
                // The same pill on a 13 pt row -- `line-height = 0.8`, §8.4's case. The floor is
                // `hitRowHeight`'s, so the pill stays 16 pt and overhangs the row it is centred on;
                // this is the only picture in the set where the clamp is visible at all, because at
                // the default font the cell is 17 pt and the clamped and unclamped pills are the
                // same pill.
                write(workbenchHintRow(palette: themePalette, appearance, cellHeight: 13),
                      named: "workbench-hint-lineheight-08-\(suffix)", into: directory,
                      background: themePalette.background)
                // The one strip allowed to sit on the command's own text: a running watch's `Stop`
                // on a line so long that no row of it has a free column. Stopping a runaway watch
                // is one click at every width, so this pill is drawn over the tail on an opaque
                // ground -- and this is the picture of how much of the command that costs.
                write(longCommandStrip(palette: themePalette, appearance),
                      named: "block-header-long-command-\(suffix)", into: directory,
                      background: themePalette.background)
                // The field a `Filter…` or `Find in Body…` lens is typed into. It is drawn over the
                // *pane* and painted from the pane's palette, while its bezel, its secondary
                // sentence and the `Run with jq` button are AppKit's and follow an appearance --
                // which is the mismatch these four pictures per state exist to hold shut.
                for (name, caption, text, message, offersJq) in lensFieldStates() {
                    let view = LensFieldView(frame: NSRect(x: 0, y: 0, width: 360, height: 58))
                    view.appearance = NSAppearance(named: appearance)
                    view.show(caption: caption, text: text, palette: themePalette)
                    view.setMessage(message, offersJq: offersJq)
                    let size = view.intrinsicContentSize
                    view.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
                    view.layoutSubtreeIfNeeded()
                    write(view, named: "lens-field-\(name)-\(suffix)", into: directory,
                          background: themePalette.background)
                }
                // The gutter's four caps, one per shape the idle gutter can draw: a succeeded
                // command's inset capsule, a failure's full-row bar (more ink, because a failure is
                // what has to be findable while scrolling), a running command's hollow capsule, and
                // a command that finished cleanly with nothing to fold at 40 %. Every one is a
                // *shape* as well as a colour, which is the whole point -- colour is the one thing
                // a mark cannot say on its own.
                let cell = rowHeight
                let gutter = PromptGutterView(frame: NSRect(x: 0, y: 0,
                                                            width: CGFloat(PromptGutter.hitWidth),
                                                            height: cell * 4))
                gutter.appearance = NSAppearance(named: appearance)
                _ = gutter.update(caps: [0: .init(shape: .solid, tone: .success, isPressable: true),
                                         1: .init(shape: .bar, tone: .failure, isPressable: true),
                                         2: .init(shape: .hollow, tone: .running, isPressable: true),
                                         3: .init(shape: .faded, tone: .success, isPressable: false)],
                                  // The facts, not the sentences: the view formats them, so a
                                  // picture cannot be taken against wording nobody ships. The
                                  // fourth mark is the silent command -- no output, so no fold
                                  // offer, which is why its cap is the unpressable one.
                                  labels: [0: .init(mark: .succeeded, folded: false, hasOutput: true, line: 1),
                                           1: .init(mark: .failed, folded: false, hasOutput: true, line: 2),
                                           2: .init(mark: .running, folded: false, hasOutput: true, line: 3),
                                           3: .init(mark: .succeeded, folded: false, hasOutput: false, line: 4)],
                                  palette: themePalette, cellHeight: cell, padding: 8, topPadding: 0)
                gutter.layoutSubtreeIfNeeded()
                write(gutter, named: "gutter-marks-\(suffix)", into: directory,
                      background: themePalette.background)
                // `gutter-cap-<state>-<presentation>-<palette>-<appearance>`: §8.5's twelve cases,
                // one cap alone on one row, drawn by the real `gutterCap(_:hasStarted:hovered:)`.
                //
                // The picture above is a *run* of marks and answers a different question (does a
                // column of them read as several commands); this answers what each single mark is,
                // including the two presentations the set had no picture of at all -- hovered, the
                // only new mark this wave draws, and hovered-while-folded, which points right
                // because pressing it unfolds.
                //
                // `no-output`'s three come out byte-identical on purpose: a block that finished
                // cleanly with nothing to fold is not pressable, so `gutterCap` never gives it a
                // chevron. That is the rule, and a picture that shows it is worth more than a case
                // left out because it would look the same.
                for (stateName, header, started) in gutterCapStates() {
                    for (presentation, hovered, folded) in [("idle", false, false),
                                                            ("hovered", true, false),
                                                            ("folded", true, true)] {
                        // `BlockHeader.folded` is a `let`, so the folded case is a second header
                        // rather than a mutation.
                        let shown = folded ? gutterCapHeader(stateName, folded: true) : header
                        // nil is a *state*, not a gap in the set: `gutterCap` answers nil for a
                        // command that has not started, which is the prompt you are typing at. The
                        // gutter is a record, so there is nothing there to draw and nothing to
                        // picture -- `gutterCapStates` includes that row so the rule is exercised,
                        // and this is where it is skipped rather than written as a blank PNG.
                        guard let cap = CommandBlockChrome.gutterCap(shown, hasStarted: started,
                                                                     hovered: hovered)
                        else { continue }
                        let view = PromptGutterView(frame: NSRect(x: 0, y: 0,
                                                                  width: CGFloat(PromptGutter.hitWidth),
                                                                  height: cell))
                        view.appearance = NSAppearance(named: appearance)
                        _ = view.update(caps: [0: cap],
                                        labels: [0: GutterMarkLabel.Key(
                                            mark: shown.failed ? .failed
                                                : (shown.isRunning ? .running : .succeeded),
                                            folded: shown.folded, hasOutput: shown.hasOutput,
                                            line: 1)],
                                        palette: themePalette, cellHeight: cell, padding: 8,
                                        topPadding: 0)
                        view.layoutSubtreeIfNeeded()
                        write(view, named: "gutter-cap-\(stateName)-\(presentation)-\(suffix)",
                              into: directory, background: themePalette.background)
                    }
                }
                for (name, failed, summary, tone, columns) in stickyPromptStates() {
                    let band = stickyPrompt(palette: themePalette, failed: failed, summary: summary,
                                            tone: tone, columns: columns, appearance: appearance)
                    // The band hides itself on empty text, and a hidden band writes a picture of
                    // the background: a state that is *meant* to be up and is not would be a blank
                    // PNG nobody reads as a defect. Said out loud instead (S2).
                    if band.isHidden {
                        print("sticky-prompt-\(name): the band hid itself — nothing to picture")
                    }
                    write(band, named: "sticky-prompt-\(name)-\(suffix)", into: directory,
                          background: themePalette.background)
                }
            }
        }
        // The four HTTP summaries against Solarized Dark, whose red pair (3.25:1 and 3.26:1) is the
        // theme that proved `Palette.readable` alone is not enough: it picks between two colours
        // and lifts neither. Every tone here is now held to 4.5:1 against this background by
        // `SummaryTone.color(in:)`, and this is the picture that says so.
        if let solarized = Themes.builtin["solarized-dark"] {
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (name, header) in httpBlockHeaderStates() {
                    guard let strip = blockStrip(header: header, width: .w3, palette: solarized,
                                                 appearance: appearance, rowHeight: rowHeight,
                                                 font: overlayFont) else { continue }
                    write(strip, named: "block-header-\(name)-solarized-dark-\(appearanceName)",
                          into: directory, background: solarized.background)
                }
            }
        }
        // The `Watch…` popover, in both appearances, on the stop rule that has the most in it:
        // every row is up, and the sentence at the foot is what the header will then say. Plus the
        // one state that has to be unmistakable -- a field that cannot be read, with Start greyed
        // and the sentence saying which box to look at -- which had only ever been drawn dark.
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let view = WatchPlanEditor.snapshotView(seed: WatchPlan(interval: 5, stop: .never)) { model in
                model.stop = .until
                model.condition = .status
                model.value = "200"
            }
            view.appearance = NSAppearance(named: appearance)
            view.layoutSubtreeIfNeeded()
            write(view, named: "watch-plan-editor-\(name)", into: directory,
                  background: windowGround(appearance))
            let invalid = WatchPlanEditor.snapshotView(seed: WatchPlan(interval: 5, stop: .never)) { model in
                model.interval = "0"
            }
            invalid.appearance = NSAppearance(named: appearance)
            invalid.layoutSubtreeIfNeeded()
            write(invalid, named: "watch-plan-editor-invalid-\(name)", into: directory,
                  background: windowGround(appearance))
        }

        // The chrome over a real grid. Everything above is a control on a flat fill, which is the
        // one thing a user never sees; see `GridSnapshot` for why the compositor lives here rather
        // than in `NyxRenderTests`.
        GridSnapshot.run(into: directory, config: config)
        // The menus and the alerts, neither of which `cacheDisplay` can reach on its own; see
        // `MenuSnapshot` for what is real in those pictures and what is a reconstruction.
        MenuSnapshot.run(into: directory, config: config)
        // The states the design review found no picture for: hover and pressed,
        // a TUI owning the screen, extreme metrics, and the sheet and popover
        // states that only one of their options had ever been drawn in.
        StateSnapshot.run(into: directory, config: config)

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
            // The lens and watch chrome, all of it on one page, per theme. The `{ }` toggle's "on"
            // state is the theme's *accent*, the watch dots are the theme's three status colours
            // and the lens field is painted from the theme's background and foreground -- none of
            // which had ever been drawn in gruvbox, solarized or dracula. One sheet per theme
            // rather than thirty files per theme: what is being asked is "can any of this be seen
            // here at all", and that is a question a page answers better than a folder.
            write(lensWatchSheet(palette: themedPalette, name: name, rowHeight: rowHeight,
                                 font: overlayFont),
                  named: "theme-\(name)-lens-watch", into: directory,
                  background: themedPalette.background)
        }

        // Last, because starting a toggle leaves it running in the shared runner and every tab bar
        // rendered afterwards would draw its quick action in the "on" state -- which is how every
        // themed bar above came out with a filled Caffeine chip nobody had asked for.
        write(tabBar(palette: palette, config: config, tabs: 4, quickActions: quickActions(),
                     runningToggle: true),
              named: "tabbar-toggle-running", into: directory, background: palette.background)

        FileHandle.standardError.write("wrote UI snapshots to \(directory.path)\n".data(using: .utf8)!)
    }

    /// Points the settings window's `ConfigStore` at a fixture file for the rest of the run.
    ///
    /// Four pictures were being rendered from the *developer's own* `~/.config/nyx`:
    /// `writeSettings` builds a real `ConfigStore` and a real `SettingsWindowController`, and the
    /// Remote page then shows whether that person happens to have a relay token. They changed
    /// mid-task when the machine's config gained one, which makes them useless as a before/after --
    /// a review tool whose output depends on the reviewer is not a review tool. Every path built
    /// from `$HOME` (the palette's `~/projects` rows, the project-review alert) becomes
    /// reproducible with it.
    ///
    /// Through `NYX_CONFIG`, which `ConfigPath.resolve` already honours, rather than through
    /// `$HOME`: `NSHomeDirectory()` has been read by AppKit long before this runs and does not
    /// follow a `setenv` afterwards (it was tried, and printed "HOME is still /Users/…"). The
    /// override is a shipped, tested path rather than a hook added for the snapshot.
    ///
    /// Set before anything reads it and never restored: this process renders PNGs and exits.
    private static func useFixtureConfig() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("nyx-snapshot-home", isDirectory: true)
        let config = home.appendingPathComponent(".config/nyx", isDirectory: true)
        try? FileManager.default.createDirectory(at: config.appendingPathComponent("themes"),
                                                 withIntermediateDirectories: true)
        // The shipped default file plus the two lines the Remote page is about, so the page is
        // pictured switched on with a token in the field rather than with whatever this Mac has.
        let text = Config.defaultFileText
            + "\nremote = on\nremote-relay-token = snapshot-fixture-token-not-a-secret\n"
        try? text.write(to: config.appendingPathComponent("config"), atomically: true,
                        encoding: .utf8)
        let file = config.appendingPathComponent("config")
        setenv(ConfigPath.environmentVariable, file.path, 1)
        let resolved = ConfigPath.resolve(environment: ProcessInfo.processInfo.environment,
                                          home: NSHomeDirectory())
        if resolved != file {
            // Worth saying out loud rather than quietly rendering the reviewer's own files again.
            let note = "snapshot: config still resolves to \(resolved.path); "
                + "the settings pictures are not reproducible\n"
            FileHandle.standardError.write(note.data(using: .utf8)!)
        }
    }

    // MARK: - The pieces

    static func quickActions() -> [QuickAction] {
        [
            QuickAction(name: "Caffeine", kind: .toggle, command: "caffeinate -d"),
            QuickAction(name: "Deploy", kind: .send, command: "./deploy.sh"),
        ]
    }

    private static func tabBar(palette: Palette, config: Config, tabs: Int,
                               quickActions: [QuickAction], grouped: Bool = false,
                               collapsed: Bool = false, twoGroups: Bool = false,
                               runningToggle: Bool = false, width: CGFloat = 900,
                               remoteBadgeAt: Int? = nil) -> NSView {
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
        let items = (0..<tabs).map { index -> TabBarItem in
            // The two badges together in one picture: a tab this Mac is observing beside one it is
            // writing to, so the pair can be told apart at a glance rather than one at a time.
            let badge: String?
            switch remoteBadgeAt {
            case index: badge = "observer"
            case .some(let first) where index == first + 1: badge = "writer"
            default: badge = nil
            }
            let title = badge == nil ? titles[index % titles.count]
                                     : "\u{27f5} Mac mini · \(titles[index % titles.count])"
            return TabBarItem(title: title,
                              indicator: index == 2 ? .activity : (index == 3 ? .bell : TabIndicator.none),
                              label: badge)
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

    /// What the bar really says when a query matched nothing, asked of the session that says it.
    ///
    /// The two pictures of this state used to carry the string "no matches", typed here. The bar
    /// says "no results" -- `SearchSession.readout` -- so the only picture anyone had of a failed
    /// search showed wording the app has never shown.
    private static func noResultsReadout() -> String {
        let terminal = Terminal(cols: 40, rows: 4, scrollbackLimit: 8)
        terminal.feed("nothing to find on this row\r\n")
        var session = SearchSession()
        session.update(query: "zzzz", in: terminal, viewportTop: 0)
        return session.readout
    }

    private static func palettePanel(palette: Palette, config: Config, query: String = "") -> NSView {
        let table = KeyBindingTable(user: config.keybinds)
        // `KeyBinding.displayName`, in Core, and not a spelling of its own: the two copies these
        // pictures used to carry knew about modifiers and letters only, so a picture of the
        // palette drew `⇧⌘` for `Fold Output` with the arrow missing -- the same gap the menu
        // pictures had. Whatever Core decides ↑ ⇞ ⌦ ↩ look like is what these draw.
        var items: [PaletteItem] = ActionCatalog.allMenuActions.prefix(8).map { action in
            PaletteItem(title: action.title,
                        detail: table.binding(for: action).map(\.displayName) ?? "",
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

    /// Chrome's "Copy as cURL" of a real request, inline rather than read from the test bundle:
    /// the app cannot see `Tests/NyxCoreTests/Fixtures`, and this is fixture 01 verbatim -- the
    /// long header list, the `$'…'` body with a newline in it, and `--compressed`.
    static let chromeCurl = #"""
    curl 'https://api.example.com/v1/messages' \
      -H 'accept: */*' \
      -H 'accept-language: en-US,en;q=0.9' \
      -H 'cache-control: no-cache' \
      -H 'content-type: application/json' \
      -H 'origin: https://app.example.com' \
      -H 'pragma: no-cache' \
      -H 'priority: u=1, i' \
      -H 'referer: https://app.example.com/' \
      -H 'sec-ch-ua: "Chromium";v="128", "Not;A=Brand";v="24"' \
      -H 'sec-ch-ua-mobile: ?0' \
      -H 'sec-ch-ua-platform: "macOS"' \
      -H 'sec-fetch-dest: empty' \
      -H 'sec-fetch-mode: cors' \
      -H 'sec-fetch-site: same-site' \
      --data-raw $'{"model":"claude-opus","stream":true,"messages":[{"role":"user","content":"hi\nthere"}]}' \
      --compressed
    """#

    private static func requestEditorSheet(palette: Palette, _ appearance: NSAppearance.Name,
                                           tab: RequestEditorModel.Tab,
                                           line: String = chromeCurl) -> NSView {
        guard let command = CurlCommand.parse(line) else { return NSView() }
        let controller = RequestEditor(command: command, palette: palette)
        let view = controller.view
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 480)
        controller.show(tab: tab)
        // Glyphs first: the preview snaps its height to the line height AppKit actually used, and
        // a text view that has not laid out yet has no line to measure.
        for textView in descendants(of: view).compactMap({ $0 as? NSTextView }) {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }
        // Three passes: the preview and the two tables snap their own heights down to a whole
        // number of rows *during* a layout pass, and a changed constraint needs the next one to
        // take effect. In the app that is the run loop's next cycle; here there is none.
        for _ in 0..<3 { view.layoutSubtreeIfNeeded() }
        // Three is enough for every tab but Options, whose field group lands anywhere across two
        // hundred points from one run to the next -- five runs of one build gave three different
        // `request-editor-options-*.png`. More passes do not settle it (six was tried), because the
        // ambiguity is in the sheet: `optionsPage`'s horizontal stack is pinned to the page's
        // leading edge and its trailing edge is only `<=`, so nothing decides where inside that
        // slack the two columns sit. It is a chrome defect, listed rather than fixed here; every
        // other one of the 400-odd pictures is byte-identical across five runs.
        // And then everything is marked for display: a scroll view keeps a cached backing for the
        // rows it has already drawn, so a clip view that *grew* in the last pass was captured at
        // its old height -- the picture showed five and a bit rows of a table that had settled on
        // six. `cacheDisplay` redraws only what is dirty.
        for subview in descendants(of: view) { subview.needsDisplay = true }
        view.needsDisplay = true
        // The preview and the body are text views, which generate their glyphs on the first real
        // display pass: without this the two boxes render empty, and they are the two boxes this
        // sheet exists for.
        for textView in descendants(of: view).compactMap({ $0 as? NSTextView }) {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        }
        return view
    }

    /// One row of the grid, drawn the way the pane draws it: the terminal's font, the theme's
    /// foreground, one cell row tall and `columns` cells wide. What the floating chrome below sits
    /// on, so the pictures show contrast against the text rather than against nothing.
    ///
    /// `cellHeight` overrides the font's own row height for the one thing a font cannot say: what
    /// the row is at a `line-height` a user chose. §8.4's case is 13 pt, and it is the case every
    /// one-row hit target's 16 pt floor exists for.
    private static func gridRow(palette: Palette, text: String, columns: Int,
                                cellHeight: CGFloat? = nil) -> (NSView, CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cell = cellHeight ?? ceil(font.ascender - font.descender + font.leading)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let width = advance * CGFloat(columns)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: cell))
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = nsColor(palette.foreground, alpha: 1)
        label.lineBreakMode = .byClipping
        label.frame = NSRect(x: 0, y: 0, width: width, height: cell)
        row.addSubview(label)
        return (row, cell)
    }

    /// `⌘E Workbench` where it is really placed: right-aligned on the last row of a command that
    /// leaves room for it, framed at `CommandBlockChrome.hitRowHeight` and centred on its row,
    /// which is what `Pane.render` does with it.
    ///
    /// Framing it at the cell instead is how the 16 pt floor got lost the first time: at the
    /// default font the cell is already 17 pt, so a picture taken at `height: cell` agreed with a
    /// picture taken at the floor and nothing in the tree noticed the clamp had gone. Hence
    /// `cellHeight:` — at 13 pt the pill is 16 and overhangs its row by 1.5 pt each way, and the
    /// container is as tall as the pill so the picture shows the overhang rather than clipping it.
    private static func workbenchHintRow(palette: Palette, _ appearance: NSAppearance.Name,
                                         cellHeight: CGFloat? = nil) -> NSView {
        let (row, cell) = gridRow(palette: palette,
                                  text: "curl -sS https://api.example.com/v1/users?page=2",
                                  columns: 64, cellHeight: cellHeight)
        let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cell)))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: row.bounds.width,
                                             height: max(cell, height)))
        container.appearance = NSAppearance(named: appearance)
        row.frame = NSRect(x: 0, y: (container.bounds.height - cell) / 2,
                           width: row.bounds.width, height: cell)
        container.addSubview(row)
        let pill = WorkbenchHintView(frame: NSRect(x: 0, y: 0, width: 120, height: height))
        pill.appearance = NSAppearance(named: appearance)
        pill.update(text: WorkbenchHint.text(chord: "\u{2318}E"), palette: palette)
        let width = pill.intrinsicContentSize.width
        pill.frame = NSRect(x: row.bounds.width - width,
                            y: row.frame.minY + (cell - height) / 2, width: width, height: height)
        pill.layoutSubtreeIfNeeded()
        container.addSubview(pill)
        return container
    }

    /// The hover strip on a command line with no room anywhere: the W0 `Stop`, alone, over the tail
    /// of the last row. The command is a real `curl` filling 80 columns, which is the case the
    /// exception exists for -- a request run from the workbench is long by construction, and a
    /// watch on it is the one thing that must be stoppable however long the line is.
    private static func longCommandStrip(palette: Palette, _ appearance: NSAppearance.Name) -> NSView {
        let header = BlockHeader(id: 7, state: .finished, folded: false, hasOutput: true,
                                 anyFolds: false, notifyArmed: false, summary: "",
                                 httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json",
                                                          tone: .success),
                                 isHTTP: true,
                                 watch: WatchHeader(text: "run 12 \u{b7} 200 \u{b7} 100 ms \u{b7} every 5 s",
                                                    dots: [.success, .running], showsStop: true,
                                                    tone: .success))
        // Exactly 80 characters: the row is *full*, which is the only condition under which the
        // strip is placed over text at all. A shorter line here would picture the case that was
        // never in question.
        let (row, cell) = gridRow(
            palette: palette,
            text: "-H 'content-type: application/json' -d '{\"name\":\"ada\",\"role\":\"admin\"}' -u ada:s3",
            columns: 80)
        row.appearance = NSAppearance(named: appearance)
        let strip = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: cell))
        strip.appearance = NSAppearance(named: appearance)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        guard let content = CommandBlockChrome.stripContent(header, at: .w0) else { return row }
        let plan = CommandBlockChrome.StripPlan(content: content, firstColumn: 0,
                                                overlapsCommand: true)
        strip.update(header: header, plan: plan, palette: palette, font: font,
                     groundHeight: cell)
        let width = strip.width(of: content, font: font)
        strip.frame = NSRect(x: row.bounds.width - width, y: 0, width: width, height: cell)
        strip.layoutSubtreeIfNeeded()
        row.addSubview(strip)
        return row
    }

    /// `Save as Button…`: the quick-action sheet as the request editor prefills it -- the name it
    /// suggests and the one-line command, which is the longest thing that field ever holds.
    private static func saveAsButtonSheet(palette: Palette, _ appearance: NSAppearance.Name) -> NSView {
        guard let command = CurlCommand.parse(chromeCurl) else { return NSView() }
        let request = RequestEditor(command: command, palette: palette)
        _ = request.view      // the draft is read from the model, which the view's load fills in
        let controller = QuickActionEditor(editing: request.quickActionDraft(),
                                           heading: "New Button", verb: "Save")
        let view = controller.view
        view.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 232)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// `Run every…`: the alert's own content view, so the picture is the prompt the sheet shows
    /// rather than a rebuilt likeness of it.
    private static func intervalPromptView(_ appearance: NSAppearance.Name) -> NSView {
        let (alert, _) = RequestEditor.intervalPrompt(seconds: 5)
        // Without this the alert is pictured half-built: the accessory view unplaced, an empty
        // button where the second one will go, and the suppression checkbox's placeholder text
        // showing. `layout()` is what running the alert would do before it appeared.
        alert.layout()
        guard let view = alert.window.contentView else { return NSView() }
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// One `PairingFlow.State` per named picture -- constructed directly, not run through a real
    /// flow, because a still picture only needs the state a real pairing would eventually reach,
    /// not the events that got it there.
    private static func pairingStates() -> [(String, PairingFlow.State)] {
        [
            // Pictured on both sides. On the host it is the sheet a user gets by pressing Pair
            // with remote switched on and no relay token in the field -- it rendered as an empty
            // box (every control hidden, one Cancel button) and nobody had seen it. On the client
            // it is the sheet somebody looks at when they choose "Enter a code…", with the field
            // and the default "Pair" button that submits it.
            ("idle", .idle),
            ("opening", .opening("K7M4QZ", expires: Date().addingTimeInterval(300))),
            ("code", .showingCode("K7M4QZ", expires: Date().addingTimeInterval(300))),
            ("requested", .requested(peerID: "peer-device-id", peerName: "Nik's MacBook Pro")),
            ("confirming", .confirming(peerID: "peer-device-id", peerName: "Nik's MacBook Pro",
                                       fingerprint: "apple-river-stone-zero", mine: false, theirs: false)),
            // The same state after this side has pressed Confirm: no button, and a body that says
            // what is being waited for. It used to be the "confirming" picture with the button
            // simply gone, which reads as a sheet that has stopped responding.
            ("waiting", .confirming(peerID: "peer-device-id", peerName: "Nik's MacBook Pro",
                                    fingerprint: "apple-river-stone-zero", mine: true, theirs: false)),
            ("paired", .paired(peerID: "peer-device-id", peerName: "Nik's MacBook Pro")),
            // The relay's wording, not the local five-minute timeout's: a mistyped code and an
            // expired one are indistinguishable once the relay has forgotten it, and this is the
            // sentence most people who fail a pairing actually read -- and the longer of the two,
            // so it is the one that shows whether the sheet's body wraps.
            ("failed", .failed("That code is wrong or has expired")),
        ]
    }

    private static func pairingSheetView(state: PairingFlow.State, side: PairingFlow.Side,
                                         _ appearance: NSAppearance.Name) -> NSView {
        let sheet = PairingSheet(side: side)
        sheet.update(state: state)
        let view = sheet.panel.contentView ?? NSView()
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Client side, mid-`.idle`, having just submitted something that doesn't normalise to a code
    /// -- the one pairing-sheet state that lives in the sheet itself rather than in
    /// `PairingFlow.State`, so it is driven through the real submit path instead of constructed.
    private static func invalidCodePairingSheetView(_ appearance: NSAppearance.Name) -> NSView {
        let sheet = PairingSheet(side: .client)
        sheet.simulateInvalidCodeSubmission("not a code")
        let view = sheet.panel.contentView ?? NSView()
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// One PNG per settings page: an `NSTabView` shows one at a time, so a single render of the
    /// window would leave three of the four pages unlooked-at, which is the whole problem.
    private static func writeSettings(into directory: URL, appearance: NSAppearance.Name,
                                      suffix: String, remoteOn: Bool = true,
                                      remotePageOnly: Bool = false) {
        let store = ConfigStore()
        let controller = SettingsWindowController(store: store)
        // The Remote page's controls follow its checkbox, so the page has to be pictured in both
        // states: switched on (every field live) and switched off (the whole body greyed out, which
        // is the state a Mac that has never set this up is actually in).
        var config = store.config
        config.remote = remoteOn ? .on : .off
        controller.configChanged(config, diagnostics: [])
        // Two fake paired devices and three audit lines -- pictured this way rather than by
        // writing them into a real person's `~/.config/nyx/remote/`, which is what reading the
        // real files at their real path (the settings page's normal, reachable behaviour) would
        // otherwise mean here. After `configChanged`, which re-reads the real files.
        controller.setRemoteDemoData(
            paired: [
                PairedDevice(id: "N1a2B3c4D5e6F7g8H9i0JkLmNoPqRsTuVwXyZ01AB", name: "Nik's MacBook Pro",
                            pairedAt: Date(timeIntervalSince1970: 1_762_000_000)),
                PairedDevice(id: "Q9w8E7r6T5y4U3i2O1p0AsDfGhJkLzXcVbNm7654Z", name: "Mac mini (office)",
                            pairedAt: Date(timeIntervalSince1970: 1_762_400_000)),
            ],
            auditLines: [
                "2026-09-01T10:00:00Z  paired  Nik's MacBook Pro",
                "2026-09-05T09:12:03Z  attached  Nik's MacBook Pro → nyx — zsh",
                "2026-09-05T09:14:47Z  detached  Nik's MacBook Pro → nyx — zsh",
            ])
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
            if remotePageOnly, label != "remote" { continue }
            page.layoutSubtreeIfNeeded()
            // Same lazy-glyph-generation trap as `commandEditorSheet`: the Remote page's activity
            // log is an `NSTextView`, and without this it caches to an empty box.
            for textView in descendants(of: page).compactMap({ $0 as? NSTextView }) {
                textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            }
            write(page, named: "settings-\(label)\(suffix)", into: directory,
                  background: windowGround(appearance))
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The colour a real sheet or settings window puts behind these controls. Rendering them on the
    /// terminal's own background instead would judge a contrast that never happens on screen.
    static func windowGround(_ appearance: NSAppearance.Name) -> RGB {
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

    /// The four states the gutter's mark has a shape for, and whether the command had started when
    /// the cap was asked for.
    ///
    /// `hasStarted` is in the tuple rather than assumed because `gutterCap` returns `nil` before a
    /// command starts -- the prompt you are typing at gets no mark -- and a picture set that could
    /// not express that would be a set that had never tested it. All four have started here; the
    /// unstarted case has no picture because it has no mark.
    private static func gutterCapStates() -> [(String, BlockHeader, Bool)] {
        ["succeeded", "failed", "running", "no-output"].map {
            ($0, gutterCapHeader($0, folded: false), true)
        }
    }

    /// One of `gutterCapStates`' headers, with `folded` set. A second header rather than a
    /// mutation: `BlockHeader.folded` is a `let`.
    private static func gutterCapHeader(_ state: String, folded: Bool) -> BlockHeader {
        switch state {
        case "failed":
            return BlockHeader(id: 2, state: .failed(status: 1), folded: folded, hasOutput: true,
                               anyFolds: folded, notifyArmed: false, summary: "exit 1 \u{b7} 8.8s")
        case "running":
            return BlockHeader(id: 3, state: .running(elapsed: 12), folded: folded, hasOutput: true,
                               anyFolds: folded, notifyArmed: true, summary: "12s")
        case "no-output":
            return BlockHeader(id: 5, state: .finished, folded: folded, hasOutput: false,
                               anyFolds: folded, notifyArmed: false, summary: "")
        default:
            return BlockHeader(id: 1, state: .finished, folded: folded, hasOutput: true,
                               anyFolds: folded, notifyArmed: false, summary: "8.8s")
        }
    }

    /// The three answers a request can give, each in the colour that says which it was. The command
    /// itself exited 0 in all three -- that is the whole reason the header needs a tone of its own:
    /// a 404 in the same grey as a 200 reads as "fine".
    ///
    /// `summary` is deliberately the *duration* here, the thing the block would have said without
    /// a request: if any of these three pictures shows `8.8s` the HTTP summary is not reaching the
    /// view.
    private static func httpBlockHeaderStates() -> [(String, BlockHeader)] {
        func header(_ id: UInt32, _ text: String, _ tone: HTTPSummary.Tone) -> BlockHeader {
            BlockHeader(id: id, state: .finished, folded: false, hasOutput: true, anyFolds: false,
                        notifyArmed: false, summary: "8.8s",
                        httpSummary: HTTPSummary(text: text, tone: tone))
        }
        return [
            ("http-success", header(6, "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json", .success)),
            ("http-redirect", header(7, "301 \u{b7} 31 ms \u{b7} 178 B", .redirect)),
            ("http-failure", header(8, "500 \u{b7} 1.4 s \u{b7} 2.0 KB \u{b7} json", .failure)),
            // The server answered and the command still failed -- `-o` could not write the file,
            // the transfer was cut short. Red, because a failed command is never green, and the
            // status is kept because "which request was it that failed" is the next question. The
            // code has no words beside it: curl's reasons are all about connecting, which this
            // request evidently did.
            ("http-exit", header(9, "200 \u{b7} 245 ms \u{b7} exit 56", .failure)),
        ]
    }

    /// A watch of `runs` finished requests, still going or stopped.
    ///
    /// Never two runs: the timeline is the thing being looked at and a strip of two dots says
    /// nothing about how a full one will read. Every fourth run is a 503 and every seventh a 301, so
    /// all of the dot kinds are in every picture however long the series is.
    private static func watchSeries(runs: Int, running: Bool) -> WatchSeries {
        var series = WatchSeries(plan: WatchPlan(interval: 5, stop: .never), command: "curl x",
                                 startedAt: 0)
        var clock = 0.0
        for index in 0..<max(1, runs) {
            let id = UInt32(index + 1)
            let status = index % 4 == 3 ? 503 : (index % 7 == 4 ? 301 : 200)
            series.runStarted(id: id, at: clock)
            clock += 0.142
            series.runFinished(id: id, status: status, exitStatus: 0,
                               timeTotal: 0.1 + Double(index % 10) * 0.01, body: "", at: clock)
            clock += 5
        }
        if running {
            series.runStarted(id: 9_999, at: clock)
        } else {
            series.stop(.stopped)
        }
        return series
    }

    /// One picture per state the remote strip can be in. The live *writer* is deliberately not
    /// here: that state has no strip at all, which is the point of it -- from the writer's side an
    /// attached session looks exactly like a local one.
    private static func remoteStripStates() -> [(String, AttachState)] {
        func state(_ phase: AttachState.Phase, _ role: AttachState.Role) -> AttachState {
            var s = AttachState(hostName: "Mac mini (office)", title: "swift test")
            s.phase = phase
            s.role = role
            return s
        }
        // The live *writer* with a geometry note is the one picture of that state there can be: it
        // is the only thing that puts a strip on a tab which otherwise has none.
        var clipped = state(.live, .writer)
        clipped.hostSize = GridSize(cols: 132, rows: 40)
        clipped.paneSize = GridSize(cols: 96, rows: 30)
        // A fixed clock, so the picture is the same every run rather than "since <now>".
        let offlineAt = Date(timeIntervalSince1970: 1_757_082_720)
        var suspended = state(.suspended("Mac mini (office)", since: offlineAt), .writer)
        suspended.timeZone = TimeZone(identifier: "UTC")!
        suspended.today = AttachState.startOfDay(offlineAt, in: suspended.timeZone)
        // The same tab left open overnight, and one left open for a week: the sentence has to say
        // which, because "since 14:32" is the same four characters either way.
        var suspendedYesterday = suspended
        suspendedYesterday.today = AttachState.startOfDay(offlineAt + 86_400, in: suspended.timeZone)
        var suspendedDated = suspended
        suspendedDated.today = AttachState.startOfDay(offlineAt + 6 * 86_400, in: suspended.timeZone)
        // The same state in a split tab: no "⌘W to close" -- ⌘W would take the other pane's tab
        // with it -- and the Close button carries the whole offer.
        var suspendedSplit = suspended
        suspendedSplit.closesWholeTab = false
        // Both clauses at once, which is the case the strip has to choose between when it is narrow.
        var suspendedClipped = suspended
        suspendedClipped.hostSize = clipped.hostSize
        suspendedClipped.paneSize = clipped.paneSize
        return [
            ("attaching", state(.attaching, .observer)),
            ("observer", state(.live, .observer)),
            ("reconnecting", state(.reconnecting, .writer)),
            ("suspended", suspended),
            ("suspended-yesterday", suspendedYesterday),
            ("suspended-dated", suspendedDated),
            ("suspended-split", suspendedSplit),
            ("suspended-clipped", suspendedClipped),
            ("ended", state(.ended("Mac mini (office)"), .writer)),
            ("failed", state(.failed(AttachFailure.text(code: "host_offline")), .observer)),
            ("clipped", clipped),
        ]
    }

    private static func remoteStrip(state: AttachState, palette: Palette,
                                    _ appearance: NSAppearance.Name,
                                    width: CGFloat = 900) -> NSView {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let height = ceil(font.ascender - font.descender + font.leading)
        // Inside a parent with a frame, which is how the pane holds it. A strip's own width is a
        // *required* constraint only while it has a superview: on its own, Auto Layout resolved a
        // label too long for the strip by making the strip wider, and at 300 pt that put 672 pt of
        // label and the Close button at x=682 inside a 300 pt picture -- a picture that would have
        // said the narrow case is fine when it is the case these two pictures exist to show.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let view = RemoteStripView(frame: host.bounds)
        host.addSubview(view)
        view.appearance = NSAppearance(named: appearance)
        view.update(state: state, palette: palette,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular), cellHeight: height)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// The palette showing what the Remote section actually looks like: an online Mac with two
    /// sessions, a Mac that is awake with nothing open, one that is asleep, and the relay status
    /// row that appears in place of everything when the socket is down. Built through
    /// `RemoteCatalogue` rather than by hand, so the rows are the ones a real presence and
    /// catalogue message would produce.
    private static func remotePalettePanel(palette: Palette, mixed: Bool) -> NSView {
        let now = Date()
        let iso = ISO8601DateFormatter()
        var catalogue = RemoteCatalogue()
        // In the order the coordinator does it: the paired list first, because the catalogue takes
        // presence and sessions only for devices this Mac has paired with.
        catalogue.setPaired(["d1": "Mac mini (office)", "d2": "Nik's MacBook Pro",
                             "d3": "iMac (studio)"])
        catalogue.applyPresence([
            RemotePresence(deviceID: "d1", name: "Mac mini (office)", online: true),
            RemotePresence(deviceID: "d2", name: "Nik's MacBook Pro", online: true),
            RemotePresence(deviceID: "d3", name: "iMac (studio)", online: false),
        ])
        catalogue.applyCatalogue(deviceID: "d1", sessions: [
            RemoteSessionInfo(sessionID: "s1", title: "zsh", cwd: NSHomeDirectory() + "/projects/nyx",
                              repo: "nyx", branch: "feat/remote-sessions", process: "swift test",
                              lastCommand: "make test",
                              lastActivity: iso.string(from: now.addingTimeInterval(-120)),
                              cols: 120, rows: 40),
            RemoteSessionInfo(sessionID: "s2", title: "vim Pane.swift",
                              cwd: NSHomeDirectory() + "/projects/nyx", repo: "nyx", branch: "main",
                              process: "vim", lastCommand: "git status",
                              lastActivity: iso.string(from: now.addingTimeInterval(-3600)),
                              cols: 120, rows: 40),
        ])
        catalogue.applyCatalogue(deviceID: "d2", sessions: [])

        var items: [PaletteItem] = []
        if mixed {
            // What ⌘⇧P actually opens on: the window's own verbs, a theme, a tab, and the Remote
            // section after them, in the order `PaletteSource.items` builds.
            let bindings = KeyBindingTable(user: [])
            // Four actions, not five: the panel shows ten rows, and the eleventh -- the offline
            // Mac, the row this picture exists to show greyed -- fell off the bottom.
            items = PaletteSource.items(actions: Array(ActionCatalog.allMenuActions.prefix(4)),
                                        chord: { bindings.binding(for: $0).map(\.displayName) },
                                        themes: ["dracula"], tabTitles: ["nyx — zsh"],
                                        remote: catalogue.paletteItems(now: now, home: NSHomeDirectory()))
        } else {
            // The relay is down. Its own row is what the section becomes: a host whose sessions
            // this Mac cannot see has nothing to list, so showing live rows beside "unreachable"
            // would be a picture of a state that cannot happen.
            var offline = RemoteCatalogue()
            offline.setPaired(["d1": "Mac mini (office)", "d3": "iMac (studio)"])
            offline.relayStatusText = "Relay unreachable (nyx.agentforge.cc)"
            items = offline.paletteItems(now: now, home: NSHomeDirectory())
        }

        let view = CommandPaletteView(palette: palette, items: items)
        view.frame = NSRect(x: 0, y: 0, width: CommandPaletteView.width, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// The palette as a person with a day's requests behind them opens it: the window's own verbs
    /// first, then the Requests section. Ages are relative to `now`, so the picture reads the same
    /// whenever it is taken.
    private static func requestPalettePanel(palette: Palette) -> NSView {
        let now = Date()
        var history = RequestHistory(limit: Config.defaults.httpHistory)
        history.record("curl -sS https://api.example.com/v1/organisations/acme/projects/nyx/deployments",
                       at: now.addingTimeInterval(-86_400 * 3))
        history.record("curl https://admin:hunter2secret@staging.example.com/v1/health",
                       at: now.addingTimeInterval(-7_200))
        // The localhost row: a port and a query, which are what tell two otherwise identical rows
        // apart on the machine where this list gets the most use.
        history.record("curl -X POST -d '{\"name\":\"nik\"}' 'http://127.0.0.1:8000/users.json?debug=1'",
                       at: now.addingTimeInterval(-1_800))
        history.record("curl -X POST -H 'Authorization: Bearer $TOKEN' -d '{\"ref\":\"main\"}' "
                       + "https://api.example.com/v2/deployments",
                       at: now.addingTimeInterval(-90))
        let bindings = KeyBindingTable(user: [])
        let items = PaletteSource.items(actions: Array(ActionCatalog.allMenuActions.prefix(4)),
                                        chord: { bindings.binding(for: $0).map(\.displayName) },
                                        themes: ["dracula"], tabTitles: ["nyx — zsh"],
                                        requests: history.paletteItems(now: now))
        let view = CommandPaletteView(palette: palette, items: items)
        view.frame = NSRect(x: 0, y: 0, width: CommandPaletteView.width, height: view.preferredHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private static func stickyPrompt(palette: Palette, failed: Bool, summary: String = "",
                                     tone: SummaryTone? = nil, columns: Int = 100,
                                     appearance: NSAppearance.Name = .darkAqua) -> NSView {
        // 22 pt cells, so the frame's `hitRowHeight` floor does not bite: what these pictures are
        // of is the band's *states*, and `composite-block-lineheight-08-sticky-*` is the picture of
        // the drawn-height rule (D3) over a 13 pt row.
        let cell: CGFloat = 22
        let height = CGFloat(CommandBlockChrome.hitRowHeight(cellHeight: Double(cell)))
        // The frame is the pane the band is being pictured in: `columns` cells wide, plus the
        // leading inset the gutter takes, capped at the 900 pt the wide states use. A narrow band
        // drawn in a wide frame is a picture of a wide band whose label happens to be short (S2's
        // fixture half, review minor 5).
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let width = min(900, CGFloat(columns) * advance + CGFloat(StickyPromptView.minimumTextInset))
        let view = StickyPromptView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.appearance = NSAppearance(named: appearance)
        // The system's mono, and a cell measured from that same font, because there is no grid in
        // this picture: these are the band's *states*, and the kern is 0 by construction. The
        // band over a real grid in a face that is not the system's is
        // `composite-font-menlo-sticky-*` in `GridSnapshot`.
        // Through `StickyPromptLabel.text`, with the note it will be drawn beside, so each picture
        // says the status exactly where the real band would: in the note when there is one, in the
        // text when there is not (`sticky-prompt-failed-*` is the second case).
        let text = StickyPromptLabel.text(
            command: failed ? "$ make test" : "$ ./deploy.sh --env production --wait",
            exitStatus: failed ? 2 : 0, columns: columns, summary: summary)
        view.update(text: text, summary: summary, tone: tone ?? (failed ? .failure : .plain),
                    palette: palette, font: font, padding: 8,
                    cellWidth: advance, cellHeight: cell)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// What the pinned strip can be: a command still going, one whose status is in its own *text*
    /// because it has no note, one whose status and duration are both worth a word, a `curl` whose
    /// *response* is what the note describes -- which is why `tone` is not derived from `failed`, a
    /// 404 exits 0 -- and a band too narrow for its command and its note both.
    ///
    /// `status-in-text` was called `failed`, and the name pictured a state **no failed command can
    /// be in** (PM P5): a failure always has a summary, `exit N` at the very least, so a failed
    /// block's band always has a note. What the case really shows is the other branch of
    /// `StickyPromptLabel.text` -- no note, so the text carries `  exit 2` itself, because colour
    /// alone says nothing to a reader who cannot see it.
    ///
    /// `narrow` is P4's fix in a picture: 20 columns for an 11-column command and a 13-column note,
    /// so the command is cut to `$ mak…` and the status appears **once**, in the note. The band used
    /// to append the suffix as well and read `$ make te…  exit 2      exit 2 · 8.8s`.
    ///
    /// Its **frame** is 20 columns wide too, not the 900 pt every other state is drawn at: a picture
    /// of a narrow band in a wide frame says nothing about what a narrow band looks like -- the
    /// label had room for the whole command and the cut was invisible. The fourth number is the
    /// column count the text is cut to, and the frame follows it.
    private static func stickyPromptStates() -> [(String, Bool, String, SummaryTone?, Int)] {
        [
            ("running", false, "", nil, 100),
            ("status-in-text", true, "", nil, 100),
            ("summary", true, "exit 2 \u{b7} 8.8s", nil, 100),
            ("http", false, "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json", .success, 100),
            ("narrow", true, "exit 2 \u{b7} 8.8s", nil, 20),
            // The width S2 was about: a note as wide as the band. The text is one ellipsis and the
            // note carries the status, and the **band is still up** -- `StickyPromptLabel.text`
            // returned `""` here and `StickyPromptView.update` hides the view on empty text, so the
            // arrow, the command and the note all vanished. Every pane of 29 columns or fewer did
            // that with an HTTP summary, and 34 or fewer with a watch sentence.
            ("narrowest", true, "exit 2 \u{b7} 8.8s", nil, 14),
        ]
    }

    /// The two built-in themes every piece of pane chrome is judged against.
    ///
    /// Both, always, because the palette is what the chrome paints from: a dark theme's accent on
    /// a lit `{ }` and a light theme's are two different questions, and until now only the first
    /// had a picture.
    private static func chromePalettes(default fallback: Palette) -> [(String, Palette)] {
        [("nyx-dark", Themes.builtin["nyx-dark"] ?? fallback),
         ("nyx-light", Themes.builtin["nyx-light"] ?? fallback)]
    }

    /// One strip, configured and sized the way `Pane.blockHeaderChanged` sizes it.
    ///
    /// The frame is `CommandBlockChrome.stripFrameHeight`, not one row. Sizing it to `rowHeight`
    /// is where every picture of a clipped pill came from: the pane has framed the strip taller
    /// than a row since the last round, so the pill in the app was whole and the pill in the
    /// picture was sliced flat. What the strip *paints* is still one row, which is why the ground
    /// under the pills is shorter than they are.
    private static func blockStrip(header: BlockHeader, width: CommandBlockChrome.WidthClass,
                                   palette: Palette, appearance: NSAppearance.Name,
                                   rowHeight: CGFloat, font: NSFont) -> NSView? {
        guard let content = CommandBlockChrome.stripContent(header, at: width) else { return nil }
        let view = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight))
        view.appearance = NSAppearance(named: appearance)
        let measured = view.width(of: content, font: font)
        let plan = CommandBlockChrome.StripPlan(content: content, firstColumn: 0,
                                                overlapsCommand: false)
        let height = CGFloat(CommandBlockChrome.stripFrameHeight(cellHeight: Double(rowHeight)))
        view.update(header: header, plan: plan, palette: palette, font: font,
                    groundHeight: CGFloat(CommandBlockChrome.stripGroundHeight(cellHeight: Double(rowHeight))))
        view.frame = NSRect(x: 0, y: 0, width: measured, height: height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Every state the hover strip has, with the width class it is pictured at.
    ///
    /// One list rather than five loops: a state added here is pictured in both themes and both
    /// appearances without a second edit, which is the only way a matrix this size stays complete.
    private static func blockStripStates() -> [(String, BlockHeader, CommandBlockChrome.WidthClass)] {
        var states: [(String, BlockHeader, CommandBlockChrome.WidthClass)] =
            (blockHeaderStates() + httpBlockHeaderStates()).map { ($0.0, $0.1, .w3) }
        // The two narrower strips of section 2.6's table. A crowded command line leaves no room for
        // a W3 strip, so `Fold` goes, then `Copy`, and `Actions` collapses to the glyph -- while
        // the status is the last thing dropped, which is what makes suppressing the in-grid summary
        // safe. These are what `CommandBlockChrome.pills(_:at:)` picks between.
        if let failed = blockHeaderStates().first(where: { $0.0 == "failed" })?.1 {
            states.append(("w2", failed, .w2))
            states.append(("w1", failed, .w1))
        }
        // The strip on a request, which is the only block that gets a lens chip: the chip's states
        // at W3 -- a response that can be lensed, one already being read through a lens, one being
        // read through `.body`, and a body too large for one, where the chip is gone rather than
        // greyed because there is nothing behind it at all -- and then the lensable response at the
        // two narrower classes. The narrow ones are the question: the chip is one more control
        // competing for room the row was already short of, and W1 must not grow by it.
        func request(_ id: UInt32, lens: ResponseLens?, tooLarge: Bool, json: Bool) -> BlockHeader {
            BlockHeader(id: id, state: .finished, folded: false, hasOutput: true, anyFolds: false,
                        notifyArmed: false, summary: "",
                        httpSummary: HTTPSummary(text: json ? "200 \u{b7} 142 ms" : "301 \u{b7} 42 ms",
                                                 tone: json ? .success : .redirect),
                        isHTTP: true, lens: lens, lensTooLarge: tooLarge, bodyIsJSON: json)
        }
        states += [
            ("http-lens", request(10, lens: nil, tooLarge: false, json: true), .w3),
            ("http-lens-on", request(11, lens: .pretty, tooLarge: false, json: true), .w3),
            ("http-lens-body", request(12, lens: .body, tooLarge: false, json: true), .w3),
            ("http-lens-too-large", request(13, lens: nil, tooLarge: true, json: true), .w3),
            // `.raw` chosen explicitly, from the menu, after some other lens was on. It is
            // **byte-identical** to `http-lens` above, and that is the assertion (design D8): a
            // lens value of raw is "no transformation", the response is raw either way, and a lit
            // chip reading `Raw` meant "you picked the no-op on purpose" -- a state with no
            // user-visible consequence, drawn as though a lens were on. The ⋯ menu still ticks its
            // `Raw` row, because there raw is one of seven choices.
            ("http-lens-raw", request(25, lens: .raw, tooLarge: false, json: true), .w3),
            // The same "there is nothing behind this control" state on a crowded command line: the
            // narrow strip is where a missing control is easiest to mistake for a dropped one.
            ("http-lens-too-large-w2", request(14, lens: nil, tooLarge: true, json: true), .w2),
            // A 301 with an HTML body: `.pretty` has nothing to pretty-print, so the chip that
            // promises pretty JSON is not offered rather than offered and inert.
            ("http-lens-not-json", request(15, lens: nil, tooLarge: false, json: false), .w3),
            ("http-lens-w2", request(16, lens: nil, tooLarge: false, json: true), .w2),
            ("http-lens-w1", request(17, lens: nil, tooLarge: false, json: true), .w1),
        ]
        // The watched block's header. Two questions: whether the dots read as a timeline (and
        // whether the filled accent "running" one is legible against the rest) and whether the
        // whole strip -- timeline, sentence, Stop, Actions -- is still a width a command line can
        // find room for. Four runs, then exactly twelve, then far past it: the timeline is capped at
        // **twelve** (`WatchSeries.header(dots:)`, the design review's 76-of-84 ruling), and the
        // picture at the cap and the picture past it are what say the cap holds, the strip stops
        // growing, and `+36` says how much it is hiding.
        func watched(_ id: UInt32, _ series: WatchSeries) -> BlockHeader {
            BlockHeader(id: id, state: .finished, folded: false, hasOutput: true, anyFolds: false,
                        notifyArmed: false, summary: "",
                        httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                        isHTTP: true, bodyIsJSON: true, watch: series.header())
        }
        states += [
            ("watch-running", watched(18, watchSeries(runs: 11, running: true)), .w3),
            ("watch-finished", watched(19, watchSeries(runs: 11, running: false)), .w3),
            ("watch-4-dots", watched(26, watchSeries(runs: 4, running: false)), .w3),
            ("watch-12-dots", watched(20, watchSeries(runs: 12, running: false)), .w3),
            ("watch-past-12-dots", watched(21, watchSeries(runs: 48, running: false)), .w3),
            // Stop goes nowhere: it is on every width, because a watch you cannot stop from the
            // strip is the one control here with a running side effect.
            ("watch-running-w2", watched(22, watchSeries(runs: 11, running: true)), .w2),
            ("watch-running-w1", watched(23, watchSeries(runs: 11, running: true)), .w1),
            ("watch-running-w0", watched(24, watchSeries(runs: 11, running: true)), .w0),
        ]
        return states
    }

    /// Every state the lens field has: empty, typed, a path outside the subset (with `Run with jq`
    /// beside the sentence), a body that is not JSON at all, and the other lens that uses the same
    /// box. The last two had no picture, and "Not JSON" is the sentence a reader gets most often.
    private static func lensFieldStates() -> [(String, String, String, String?, Bool)] {
        [
            ("empty", "Filter", "", nil, false),
            ("typed", "Filter", ".users[] | .name", nil, false),
            ("unsupported", "Filter", "map(.x)", JSONPath.unsupportedMessage, true),
            ("not-json", "Filter", ".users[0]",
             LensRendering.filterError(".users[0]", body: nil), false),
            ("find", "Find in Body", "alpha", nil, false),
        ]
    }

    private static func projectBar(_ appearance: NSAppearance.Name) -> NSView {
        let bar = ProjectActionsBar(frame: .zero)
        bar.appearance = NSAppearance(named: appearance)
        bar.show(message: "This folder has a .nyx/project.conf that has changed since you approved it.",
                 changed: true)
        return opened(bar, width: 900, height: 32)
    }

    /// One page of the lens and watch chrome in a theme: the `{ }` toggle off, on, and on a body
    /// too large for it; a watch running and stopped; and the filter field in its typed and its
    /// refused state.
    ///
    /// Right-aligned like the strips are, on the theme's own background, with a row of the theme's
    /// foreground text behind them -- the contrast question is against the *text*, not against an
    /// empty ground.
    private static func lensWatchSheet(palette: Palette, name: String, rowHeight: CGFloat,
                                       font: NSFont) -> NSView {
        let appearance: NSAppearance.Name = palette.isLight ? .aqua : .darkAqua
        let width: CGFloat = 680
        func request(_ id: UInt32, lens: ResponseLens?, tooLarge: Bool) -> BlockHeader {
            BlockHeader(id: id, state: .finished, folded: false, hasOutput: true, anyFolds: false,
                        notifyArmed: false, summary: "",
                        httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms", tone: .success),
                        isHTTP: true, lens: lens, lensTooLarge: tooLarge, bodyIsJSON: true)
        }
        let strips: [(String, BlockHeader)] = [
            ("lens off", request(1, lens: nil, tooLarge: false)),
            ("lens on", request(2, lens: .pretty, tooLarge: false)),
            ("body too large", request(3, lens: nil, tooLarge: true)),
            ("watch running", BlockHeader(id: 4, state: .finished, folded: false, hasOutput: true,
                                          anyFolds: false, notifyArmed: false, summary: "",
                                          httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms",
                                                                   tone: .success),
                                          isHTTP: true, bodyIsJSON: true,
                                          watch: watchSeries(runs: 11, running: true).header())),
            ("watch stopped", BlockHeader(id: 5, state: .finished, folded: false, hasOutput: true,
                                          anyFolds: false, notifyArmed: false, summary: "",
                                          httpSummary: HTTPSummary(text: "200 \u{b7} 142 ms",
                                                                   tone: .success),
                                          isHTTP: true, bodyIsJSON: true,
                                          watch: watchSeries(runs: 11, running: false).header())),
        ]
        let fields: [(String, String, String?, Bool)] = [
            ("filter typed", ".users[] | .name", nil, false),
            ("filter refused", "map(.x)", JSONPath.unsupportedMessage, true),
        ]
        let rowGap: CGFloat = 12
        let fieldHeight: CGFloat = 58
        let height = 24 + CGFloat(strips.count) * (rowHeight + rowGap)
            + CGFloat(fields.count) * (fieldHeight + rowGap)
        let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        sheet.appearance = NSAppearance(named: appearance)
        var y = height - 24
        func caption(_ text: String, at top: CGFloat, tall: CGFloat) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            label.textColor = nsColor(palette.noteForeground, alpha: 1)
            label.frame = NSRect(x: 12, y: top - tall, width: 150, height: tall)
            return label
        }
        for (label, header) in strips {
            y -= rowHeight
            // A row of the theme's own text under each strip, so what is judged is the strip
            // against the grid rather than the strip against nothing.
            let behind = NSTextField(labelWithString:
                "curl -sSi https://api.example.com/v1/users?page=2&per_page=50")
            behind.font = font
            behind.textColor = nsColor(palette.foreground, alpha: 1)
            behind.lineBreakMode = .byClipping
            behind.frame = NSRect(x: 170, y: y, width: width - 182, height: rowHeight)
            sheet.addSubview(behind)
            sheet.addSubview(caption(label, at: y + rowHeight, tall: rowHeight))
            if let content = CommandBlockChrome.stripContent(header, at: .w3) {
                let strip = BlockHeaderView(frame: NSRect(x: 0, y: 0, width: 320, height: rowHeight))
                strip.appearance = NSAppearance(named: appearance)
                let plan = CommandBlockChrome.StripPlan(content: content, firstColumn: 0,
                                                        overlapsCommand: false)
                strip.update(header: header, plan: plan, palette: palette, font: font,
                             groundHeight: rowHeight)
                let measured = strip.width(of: content, font: font)
                strip.frame = NSRect(x: width - 12 - measured, y: y, width: measured,
                                     height: rowHeight)
                strip.layoutSubtreeIfNeeded()
                sheet.addSubview(strip)
            }
            y -= rowGap
        }
        for (label, text, message, offersJq) in fields {
            let field = LensFieldView(frame: NSRect(x: 0, y: 0, width: 360, height: fieldHeight))
            field.appearance = NSAppearance(named: appearance)
            field.show(caption: "Filter", text: text, palette: palette)
            field.setMessage(message, offersJq: offersJq)
            let size = field.intrinsicContentSize
            y -= size.height
            field.frame = NSRect(x: width - 12 - 360, y: y, width: 360, height: size.height)
            field.layoutSubtreeIfNeeded()
            sheet.addSubview(caption(label, at: y + size.height, tall: size.height))
            sheet.addSubview(field)
            y -= rowGap
        }
        let title = NSTextField(labelWithString: "\(name) \u{2014} lens and watch chrome")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = nsColor(palette.foreground, alpha: 1)
        title.frame = NSRect(x: 12, y: height - 22, width: width - 24, height: 18)
        sheet.addSubview(title)
        sheet.layoutSubtreeIfNeeded()
        return sheet
    }

    /// One request per tab that can tell the user something is not editable here, with the tab it
    /// says it on. `RequestEditorModel.paramsNote`, `headersNote` and `bodyNote` are the three
    /// sentences; each needs a `curl` that actually produces it, or the picture is of a tab with
    /// nothing to say.
    private static func requestEditorNoteStates() -> [(RequestEditorModel.Tab, String, String)] {
        [
            // `-G` with a parameter-list body: curl sends the body as query parameters, so the
            // Params tab shows rows it cannot edit and the Body tab owns them.
            (.params, "params",
             "curl -G -d 'q=nyx terminal' -d 'page=2' https://api.example.com/v1/search"),
            // `--json` sends Content-Type and Accept itself; those two rows are curl's, not the
            // user's.
            (.headers, "headers",
             "curl --json '{\"service\":\"web\",\"ref\":\"main\"}' https://api.example.com/v2/deployments"),
            // A multipart form: there is no text body to put in a box.
            (.body, "body",
             "curl -F 'file=@report.pdf' -F 'name=Q3 report' https://api.example.com/v1/uploads"),
        ]
    }

    /// The three things the banner is ever used for. It is the only place a window says anything,
    /// so a kind with no picture is a sentence nobody has read.
    enum BannerKind: String, CaseIterable {
        case problems, note, failure
    }

    private static func banner(_ appearance: NSAppearance.Name, kind: BannerKind) -> NSView {
        let banner = ConfigBanner()
        banner.appearance = NSAppearance(named: appearance)
        switch kind {
        case .problems:
            banner.showProblems([
                ConfigDiagnostic(line: 12, message: "invalid value for 'font-size': 'eighteen'"),
                ConfigDiagnostic(line: 30, message: "unknown key 'cursor-blink-rate'"),
            ])
        case .note:
            banner.showNote("The new font size applies to windows opened from now on.")
        case .failure:
            banner.showFailure("Quick action \u{201C}Deploy\u{201D} failed: ./deploy.sh: "
                               + "No such file or directory")
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
    static func write(_ view: NSView, named name: String, into directory: URL,
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

        // The layer's ground, then `cacheDisplay` -- see `ChromeGround`.
        //
        // `cacheDisplay`, not `displayIgnoringOpacity`, for the view half. The custom-drawn panels
        // here render identically either way, which is exactly why the one that did not was easy to
        // misdiagnose: `NSTabView`'s strip is a segmented control that paints through the
        // layer/CoreUI path, which `displayIgnoringOpacity` skips entirely, so the settings tabs
        // came out as four blank white pills — in *both* appearances, which is the detail that
        // rules out the appearance explanation I reached for first.
        //
        // And `cacheDisplay` alone was not enough either: it draws the view, never the layer, so a
        // ground that is a `layer.backgroundColor` was missing from every picture. On this flat fill
        // that is invisible wherever the ground *is* the fill; it is not invisible for the sticky
        // strip, whose ground is `foreground @ 0.10`, and it was not invisible at all in the
        // composites, where the search bar came out with the terminal reading through it.
        ChromeGround.draw(view, at: CGRect(origin: .zero, size: size), in: context)

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
