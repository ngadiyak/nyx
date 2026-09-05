import AppKit
import NyxCore
import NyxRemote

/// The settings window.
///
/// It does not hold a configuration of its own. Every control writes its key straight into the
/// config file through `ConfigStore.write`, the file watcher notices, and the reload applies the
/// change to every open window -- the same path an edit made in an editor takes. So the window and
/// the file cannot disagree, and "apply" is not a button anyone has to press.
///
/// `configChanged` pushes the reloaded values back into the controls, which is what keeps the
/// window honest when the file is edited behind its back. Refreshing is a no-op when the values
/// already match, so a control does not fight the user who is turning it.
final class SettingsWindowController: NSWindowController {
    private let store: ConfigStore
    private var config: Config
    /// Set while `refresh` is writing values into controls, so their actions do not write the file
    /// back with what they were just told -- which would be an endless loop through the watcher.
    private var isRefreshing = false

    private var controls: [String: NSControl] = [:]
    private let keysTable = NSTableView()
    private var keyRows: [(action: TerminalAction, chord: String)] = []
    private let diagnosticsLabel = NSTextField(labelWithString: "")

    private let pairedTable = NSTableView()
    /// Everything on the Remote page below the checkbox: it all follows "Enable remote sessions",
    /// because a page of live-looking fields that do nothing is a page that reads as broken.
    private var remoteBodyControls: [NSControl] = []
    private var pairedRows: [PairedDevice] = []
    private let removePairedButton = NSButton()
    private let remoteStatusLabel = NSTextField(labelWithString: "")
    /// Replaced in `remotePage()` with the text view out of `NSTextView.scrollableTextView()`: a
    /// bare `NSTextView()` handed to `documentView` lays out into a zero-size container and shows
    /// nothing at all (the same trap `CommandEditor` documents), which is what happened here first.
    private var activityView = NSTextView()
    private var pairingSheet: PairingSheet?

    /// The name this Mac would show up as if `remote-device-name` were left empty -- the
    /// placeholder in that field, and what `refreshRemoteStatus` uses for "Online as <name>".
    /// Read once: it does not change while the window is open, and `Host.current()` is not free.
    private static let localHostName = Host.current().localizedName ?? "Mac"

    init(store: ConfigStore) {
        self.store = store
        self.config = store.config
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Nyx Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = buildContent()
        refresh(config, diagnostics: store.diagnostics)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configChanged(_ config: Config, diagnostics: [ConfigDiagnostic]) {
        self.config = config
        refresh(config, diagnostics: diagnostics)
    }

    // MARK: - Building

    private func buildContent() -> NSView {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("Appearance", appearancePage()))
        tabs.addTabViewItem(tab("Text", textPage()))
        tabs.addTabViewItem(tab("Behaviour", behaviourPage()))
        tabs.addTabViewItem(tab("Keys", keysPage()))
        tabs.addTabViewItem(tab("Remote", remotePage()))

        diagnosticsLabel.translatesAutoresizingMaskIntoConstraints = false
        diagnosticsLabel.describeForAccessibility("Configuration problems", role: .staticText)
        diagnosticsLabel.textColor = .systemRed
        diagnosticsLabel.lineBreakMode = .byTruncatingTail
        diagnosticsLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(diagnosticsLabel)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            diagnosticsLabel.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 8),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            diagnosticsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            diagnosticsLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func tab(_ title: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        item.view = view
        return item
    }

    // MARK: - Pages

    private func appearancePage() -> NSView {
        let themes = Pane.themes.names
        return page([
            row("Theme", popUp("theme", options: themes)),
            row("Dark theme", popUp("theme-dark", options: themes, includesNone: true)),
            row("Light theme", popUp("theme-light", options: themes, includesNone: true)),
            row("Padding", stepperField("padding", min: 0, max: 64, step: 1)),
            row("Opacity", slider("background-opacity", min: 0.3, max: 1, decimals: 2)),
            row("Blur", slider("background-blur", min: 0, max: 60, decimals: 0)),
            row("Tab bar", popUp("tab-bar", options: ["auto", "always", "never"])),
            row("", checkbox("window-decorations", title: "Show the title bar")),
        ], note: "Themes, padding and opacity apply as soon as you change them.")
    }

    private func textPage() -> NSView {
        return page([
            row("Font", popUp("font-family", options: SettingsWindowController.monospacedFamilies())),
            row("Size", stepperField("font-size", min: 6, max: 72, step: 1)),
            row("Line height", slider("line-height", min: 0.8, max: 2.0, decimals: 2)),
            row("", checkbox("font-thicken", title: "Thicken glyphs")),
            row("Cursor", popUp("cursor-style", options: ["block", "underline", "bar"])),
            row("", checkbox("cursor-blink", title: "Blink the cursor")),
            row("Scrollback", stepperField("scrollback-lines", min: 0, max: 1_000_000, step: 1000)),
        ], note: "Only monospaced font families are listed; a proportional font would break the grid.")
    }

    private func behaviourPage() -> NSView {
        return page([
            row("", checkbox("copy-on-select", title: "Copy on select")),
            row("", checkbox("middle-click-paste", title: "Paste on middle click")),
            row("", checkbox("confirm-close-process", title: "Confirm before closing a running process")),
            row("", checkbox("restore-session", title: "Reopen windows and tabs on launch")),
            row("", checkbox("mouse-scroll-alt-screen", title: "Scroll wheel sends arrows in full-screen apps")),
            row("", checkbox("clipboard-read", title: "Allow programs to read the clipboard")),
            row("Option key", popUp("option-as-meta", options: ["none", "left", "right", "both"])),
            row("Bell", popUp("bell", options: ["visual", "sound", "none"])),
            row("Multi-line paste", popUp("multiline-paste", options: ["edit", "confirm", "direct"])),
            row("Folded output keeps", stepperField("fold-keep-lines", min: 0, max: 100, step: 1),
                unit: "lines"),
            row("Auto-fold output over", stepperField("fold-long-output", min: 0, max: 1_000_000, step: 50),
                unit: "lines (0 = never)"),
        ], note: "Letting programs read the clipboard is off by default: any program in the terminal could then see whatever you last copied.")
    }

    private func keysPage() -> NSView {
        keysTable.addTableColumn(column("action", "Action", width: 220))
        keysTable.addTableColumn(column("chord", "Shortcut", width: 180))
        keysTable.dataSource = self
        keysTable.delegate = self
        keysTable.usesAlternatingRowBackgroundColors = true
        keysTable.rowSizeStyle = .default

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.documentView = keysTable

        let openConfig = NSButton(title: "Edit Config File…", target: self,
                                  action: #selector(openConfigFile(_:)))
        openConfig.translatesAutoresizingMaskIntoConstraints = false
        openConfig.setAccessibilityHelp("Opens ~/.config/nyx/config in your editor.")
        keysTable.setAccessibilityLabel("Shortcuts")

        let note = NSTextField(wrappingLabelWithString:
            "Shortcuts are set in the config file with lines like `keybind = cmd+shift+t=new_tab`. "
            + "A binding you add there wins over the built-in one and takes effect on save.")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        let view = NSView()
        view.addSubview(scroll)
        view.addSubview(note)
        view.addSubview(openConfig)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            scroll.heightAnchor.constraint(equalToConstant: 230),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            openConfig.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            openConfig.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
        ])
        return view
    }

    private func remotePage() -> NSView {
        let rows: [(NSView, NSView)] = [
            row("", checkbox("remote", title: "Enable remote sessions")),
            row("Device name", textField("remote-device-name", placeholder: SettingsWindowController.localHostName)),
            row("Relay", textField("remote-relay", width: 260)),
            row("Relay token", textField("remote-relay-token", secure: true, width: 260)),
            row("Snapshot lines", stepperField("remote-snapshot-lines", min: 100, max: 20_000, step: 100)),
        ]
        let grid = NSGridView(views: rows.map { [$0.0, $0.1] })
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        remoteStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        remoteStatusLabel.textColor = .secondaryLabelColor
        remoteStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        remoteStatusLabel.describeForAccessibility("Remote sessions status", role: .staticText)

        let pairedLabel = NSTextField(labelWithString: "Paired devices")
        pairedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        pairedLabel.translatesAutoresizingMaskIntoConstraints = false

        pairedTable.addTableColumn(column("name", "Name", width: 170))
        pairedTable.addTableColumn(column("id", "Device id", width: 100))
        pairedTable.addTableColumn(column("pairedAt", "Paired on", width: 100))
        pairedTable.dataSource = self
        pairedTable.delegate = self
        pairedTable.usesAlternatingRowBackgroundColors = true
        pairedTable.setAccessibilityLabel("Paired devices")

        let pairedScroll = NSScrollView()
        pairedScroll.translatesAutoresizingMaskIntoConstraints = false
        pairedScroll.hasVerticalScroller = true
        pairedScroll.borderType = .bezelBorder
        pairedScroll.documentView = pairedTable

        removePairedButton.title = "Remove"
        removePairedButton.bezelStyle = .rounded
        removePairedButton.target = self
        removePairedButton.action = #selector(removeSelectedPairedDevice(_:))
        removePairedButton.translatesAutoresizingMaskIntoConstraints = false
        removePairedButton.describeForAccessibility("Remove selected paired device")

        let pairHostButton = NSButton(title: "Pair with another device\u{2026}", target: self,
                                      action: #selector(pairAsHost(_:)))
        let pairClientButton = NSButton(title: "Enter a code\u{2026}", target: self,
                                        action: #selector(pairAsClient(_:)))
        let pairButtons = NSStackView(views: [pairHostButton, pairClientButton])
        pairButtons.orientation = .horizontal
        pairButtons.spacing = 10
        pairButtons.translatesAutoresizingMaskIntoConstraints = false

        let activityLabel = NSTextField(labelWithString: "Recent activity")
        activityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        activityLabel.translatesAutoresizingMaskIntoConstraints = false

        let activityScrollable = NSTextView.scrollableTextView()
        guard let builtActivityView = activityScrollable.documentView as? NSTextView else {
            fatalError("scrollableTextView did not produce a text view")
        }
        activityView = builtActivityView
        activityView.isEditable = false
        activityView.isSelectable = true
        activityView.drawsBackground = true
        activityView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        activityView.textContainerInset = NSSize(width: 4, height: 4)
        activityView.describeForAccessibility("Recent remote activity", role: .staticText)
        let activityScroll = activityScrollable
        activityScroll.translatesAutoresizingMaskIntoConstraints = false
        activityScroll.hasVerticalScroller = true
        activityScroll.borderType = .bezelBorder

        let note = NSTextField(wrappingLabelWithString:
            "Session titles, directories and branches are visible to the relay; terminal contents are not.")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        // Every control the switch governs. The status line, the labels and the note stay live:
        // they are the page explaining itself, and the status line's whole job while the switch is
        // off is to say so.
        remoteBodyControls = ["remote-device-name", "remote-relay", "remote-relay-token",
                              "remote-snapshot-lines"].compactMap { controls[$0] }
            + [removePairedButton, pairHostButton, pairClientButton]

        let view = NSView()
        for subview in [grid, remoteStatusLabel, pairedLabel, pairedScroll, removePairedButton,
                       pairButtons, activityLabel, activityScroll, note] as [NSView] {
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),

            remoteStatusLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            remoteStatusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            remoteStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            pairedLabel.topAnchor.constraint(equalTo: remoteStatusLabel.bottomAnchor, constant: 12),
            pairedLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            pairedScroll.topAnchor.constraint(equalTo: pairedLabel.bottomAnchor, constant: 4),
            pairedScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            pairedScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            pairedScroll.heightAnchor.constraint(equalToConstant: 76),

            removePairedButton.topAnchor.constraint(equalTo: pairedScroll.bottomAnchor, constant: 6),
            removePairedButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            pairButtons.topAnchor.constraint(equalTo: removePairedButton.bottomAnchor, constant: 10),
            pairButtons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            activityLabel.topAnchor.constraint(equalTo: pairButtons.bottomAnchor, constant: 12),
            activityLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            activityScroll.topAnchor.constraint(equalTo: activityLabel.bottomAnchor, constant: 4),
            activityScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            activityScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            activityScroll.heightAnchor.constraint(equalToConstant: 64),

            note.topAnchor.constraint(equalTo: activityScroll.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            note.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12),
        ])
        refreshPairedDevicesAndActivity()
        return view
    }

    // MARK: - Remote

    private static let pairedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    /// Greys out the Remote page's body when the switch is off. The table goes with it: a paired
    /// device you cannot reach is not a row worth selecting, and Remove beside it would be the one
    /// live control on a dead page.
    private func refreshRemoteEnabled() {
        let on = config.remote == .on
        for control in remoteBodyControls { control.isEnabled = on }
        // The stepper is a second control beside its field, registered under its own key by
        // `stepperField`; a subview scan would break the first time the row's layout changed.
        controls["remote-snapshot-lines.stepper"]?.isEnabled = on
        pairedTable.isEnabled = on
        pairedTable.reloadData()   // the cells carry the enabled colour; see `pairedDeviceCell`
        activityView.isSelectable = on
        // Explicitly both ways round. Reading the view's current colour to write it back left the
        // log stuck at whatever it happened to be the first time this ran.
        activityView.textColor = on ? .labelColor : .tertiaryLabelColor
    }

    /// The one line under the remote settings: what the connection is actually doing.
    ///
    /// Asked of the live coordinator, which is the only thing that knows. Without one -- a snapshot
    /// run renders this page with no application state behind it -- the honest answer is the one
    /// the configuration alone supports: off when it is off, and "Connecting…" when it is on but
    /// nothing here has reached anything.
    private func refreshRemoteStatus() {
        let text = coordinator?.statusText
            ?? RemoteStatusText.text(mode: config.remote, connection: .connecting,
                                     deviceName: RemoteDeviceName.resolve(
                                        configured: config.remoteDeviceName,
                                        hostName: SettingsWindowController.localHostName))
        remoteStatusLabel.stringValue = text
        remoteStatusLabel.setAccessibilityValue(text)
    }

    /// Reads the real `paired.json` and the last 20 lines of `audit.log` from beside the config
    /// file in force -- the same files `RemoteHost`/`RemoteClient` read and write.
    private func refreshPairedDevicesAndActivity() {
        // Through the coordinator when there is one: it holds the list the relay was told about, so
        // a pairing made a second ago is here without waiting for a file to be re-read. Straight
        // from disk otherwise, which is what a snapshot run and a window opened before remote
        // sessions were switched on have.
        let dir = RemoteFiles.directory(besideConfigAt: ConfigStore.path)
        let devices = coordinator?.pairedDevices
            ?? PairedDevices.load(from: RemoteFiles.pairedDevices(in: dir)).devices
        pairedRows = devices.sorted { $0.pairedAt > $1.pairedAt }
        pairedTable.reloadData()

        if let coordinator {
            setActivityText(lines: coordinator.auditLogTail(lines: 20))
            return
        }
        let text = try? String(contentsOf: RemoteFiles.auditLog(in: dir), encoding: .utf8)
        let lines = text?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
        setActivityText(lines: Array(lines.suffix(20)))
    }

    private func setActivityText(lines: [String]) {
        activityView.string = lines.isEmpty ? "No remote activity yet" : lines.joined(separator: "\n")
        activityView.textColor = lines.isEmpty ? .tertiaryLabelColor : .labelColor
    }

    /// Pictures the page with data that would otherwise mean writing fake devices and log lines
    /// into a real person's `~/.config/nyx/remote/` just to take a screenshot. `UISnapshot` is the
    /// only caller; the real window always shows what is actually on disk.
    func setRemoteDemoData(paired: [PairedDevice], auditLines: [String]) {
        pairedRows = paired
        pairedTable.reloadData()
        setActivityText(lines: auditLines)
    }

    @objc private func removeSelectedPairedDevice(_ sender: Any?) {
        let selected = pairedTable.selectedRow
        guard pairedRows.indices.contains(selected) else {
            NSSound.beep()
            return
        }
        let id = pairedRows[selected].id
        // Through the coordinator: removing a pairing is not only a line out of a file. Every
        // attachment that device still holds is torn down, the relay is told this Mac no longer
        // lists it, and the audit log records it -- none of which a write to `paired.json` does.
        if let coordinator {
            coordinator.removePairing(deviceID: id)
        } else {
            let dir = RemoteFiles.directory(besideConfigAt: ConfigStore.path)
            var paired = PairedDevices.load(from: RemoteFiles.pairedDevices(in: dir))
            paired.remove(id: id)
            try? paired.save(to: RemoteFiles.pairedDevices(in: dir))
        }
        refreshPairedDevicesAndActivity()
    }

    /// The `remote_pair` action, from the menu or a key binding: this window comes forward on its
    /// Remote page with the pairing already started, so pairing is reachable by somebody who has
    /// never opened the settings window.
    func beginHostPairing() {
        selectRemotePage()
        pairAsHost(nil)
    }

    /// Shows a code for the other Mac to type. The real relay answers `pair_opened` before the code
    /// is shown, so the sheet reads "Requesting a code from the relay" for as long as that takes --
    /// a code shown before the relay has it is one the other Mac would be told does not exist.
    @objc private func pairAsHost(_ sender: Any?) {
        guard let coordinator else {
            NSSound.beep()
            return
        }
        presentPairing(side: .host)
        coordinator.pairAsHost()
    }

    @objc private func pairAsClient(_ sender: Any?) {
        guard let coordinator else {
            NSSound.beep()
            return
        }
        presentPairing(side: .client)
        coordinator.pairAsClient()
    }

    private func presentPairing(side: PairingFlow.Side) {
        guard let window, let coordinator else { return }
        dismissPairing()
        let sheet = PairingSheet(side: side)
        sheet.onEvent = { [weak self] event in self?.handlePairingEvent(event) }
        // Everything the sheet shows comes back through here, from the one flow the coordinator
        // runs against the real relay. The sheet itself never decides anything.
        coordinator.onPairingState = { [weak self] state in
            self?.pairingSheet?.update(state: state)
        }
        pairingSheet = sheet
        window.beginSheet(sheet.panel, completionHandler: nil)
    }

    private func handlePairingEvent(_ event: PairingFlow.Event) {
        coordinator?.handlePairing(event)
        // Cancel, and the two terminal states' single button, all close the sheet: `.paired` and
        // `.failed` show "Done"/"Close", which the sheet reports as `.cancel`.
        if case .cancel = event { dismissPairing() }
    }

    private func dismissPairing() {
        coordinator?.onPairingState = nil
        coordinator?.cancelPairing()
        guard let sheet = pairingSheet, let window else { return }
        window.endSheet(sheet.panel)
        pairingSheet = nil
    }

    /// The application's remote sessions, or nil in a snapshot run (which has no coordinator at all
    /// -- rendering a settings page must not open a socket).
    private var coordinator: RemoteCoordinator? { (NSApp.delegate as? AppDelegate)?.remote }

    /// The catalogue, the status or the paired list moved.
    func remoteChanged() {
        refreshRemoteStatus()
        refreshPairedDevicesAndActivity()
    }

    /// Brings the Remote page forward, for `remote_pair` arriving from the menu.
    private func selectRemotePage() {
        guard let content = window?.contentView,
              let tabs = content.subviews.compactMap({ $0 as? NSTabView }).first else { return }
        for index in 0..<tabs.numberOfTabViewItems where tabs.tabViewItem(at: index).label == "Remote" {
            tabs.selectTabViewItem(at: index)
        }
    }

    private func column(_ id: String, _ title: String, width: CGFloat) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title
        c.width = width
        return c
    }

    /// A page of label/control rows, with an explanatory note under them.
    private func page(_ rows: [(NSView, NSView)], note: String) -> NSView {
        let grid = NSGridView(views: rows.map { [$0.0, $0.1] })
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        let noteLabel = NSTextField(wrappingLabelWithString: note)
        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor

        let view = NSView()
        view.addSubview(grid)
        view.addSubview(noteLabel)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
            noteLabel.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
            noteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            noteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            noteLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        return view
    }

    /// A label beside a control -- and the same words attached to the control itself.
    ///
    /// The text field to its left is what a sighted user reads a popup or a slider by; nothing
    /// connects the two for anyone else, so every control here reached VoiceOver as "pop up
    /// button" and "slider" with no indication of what they set. A checkbox is the exception: its
    /// title is already its name, which is why those rows are built with an empty label.
    ///
    /// `unit` is the word after the control -- "Folded output keeps [3] lines". A bare number in a
    /// settings window says nothing about what it counts, and "Auto-fold output over [0]" said
    /// neither the unit nor that zero means off. It goes into the control's accessibility name too,
    /// so the same sentence reaches VoiceOver, and the label itself is not an element: announced on
    /// its own between two numbers it reads as another value.
    private func row(_ label: String, _ control: NSView, unit: String? = nil) -> (NSView, NSView) {
        var control = control
        if let unit {
            let suffix = NSTextField(labelWithString: unit)
            suffix.identifier = SettingsWindowController.unitLabelIdentifier
            suffix.setAccessibilityElement(false)
            let stack = NSStackView(views: [control, suffix])
            stack.orientation = .horizontal
            stack.spacing = 6
            control = stack
        }
        if !label.isEmpty { describe(control, as: unit.map { "\(label), \($0)" } ?? label) }
        return (NSTextField(labelWithString: label.isEmpty ? "" : label + ":"), control)
    }

    private static let unitLabelIdentifier = NSUserInterfaceItemIdentifier("unit-label")

    /// Names every control inside `view`. A slider comes with a readout beside it and a field with
    /// a stepper, and both of those are separate controls that would otherwise be announced as a
    /// nameless number next to a nameless one.
    private func describe(_ view: NSView, as label: String) {
        for control in SettingsWindowController.controls(in: view) {
            // The unit beside a stepper is part of the control's own name, set above.
            if control.identifier == SettingsWindowController.unitLabelIdentifier { continue }
            switch control {
            case let field as NSTextField where !field.isEditable:
                control.describeForAccessibility("\(label), current value", role: .staticText)
            case is NSStepper:
                control.describeForAccessibility("\(label), step up or down")
            default:
                control.setAccessibilityLabel(label)
            }
        }
    }

    private static func controls(in view: NSView) -> [NSControl] {
        if let control = view as? NSControl { return [control] }
        return view.subviews.flatMap { controls(in: $0) }
    }

    // MARK: - Controls

    /// `none` is a real choice for the dark/light theme overrides: it means "follow `theme`".
    private static let noneTitle = "— none —"

    /// The three theme menus, rebuilt from the catalogue on every reload.
    ///
    /// Built once, they were the themes that existed when the window was opened -- so a theme file
    /// dropped in while the settings window was open could not be chosen from it, which is the exact
    /// moment a person is most likely to be looking for it.
    private func refreshThemeLists() {
        let names = Pane.themes.names
        for key in ["theme", "theme-dark", "theme-light"] {
            guard let button = controls[key] as? NSPopUpButton else { continue }
            let none = button.itemTitles.first == SettingsWindowController.noneTitle
            guard button.itemTitles.filter({ $0 != SettingsWindowController.noneTitle }) != names else { continue }
            let selected = button.titleOfSelectedItem
            button.removeAllItems()
            if none { button.addItem(withTitle: SettingsWindowController.noneTitle) }
            button.addItems(withTitles: names)
            // `refresh` sets the value from the config a line later; this only keeps the menu from
            // flickering to its first entry for themes that are still there.
            if let selected, button.itemTitles.contains(selected) { button.selectItem(withTitle: selected) }
        }
    }

    private func popUp(_ key: String, options: [String], includesNone: Bool = false) -> NSPopUpButton {
        let button = NSPopUpButton()
        if includesNone { button.addItem(withTitle: SettingsWindowController.noneTitle) }
        button.addItems(withTitles: options)
        button.target = self
        button.action = #selector(controlChanged(_:))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        controls[key] = button
        return button
    }

    private func checkbox(_ key: String, title: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(controlChanged(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        controls[key] = button
        return button
    }

    /// A free-form text field, unlike every other control on this window -- everything else is an
    /// enum, a number or a boolean. `secure` makes it an `NSSecureTextField`, which the existing
    /// read/write paths (`value(of:for:)`, `set(_:_:)`) already handle: both switch on `NSTextField`,
    /// and `NSSecureTextField` is one.
    private func textField(_ key: String, secure: Bool = false, placeholder: String? = nil,
                           width: CGFloat = 220) -> NSTextField {
        let field: NSTextField = secure ? NSSecureTextField() : NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(controlChanged(_:))
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        controls[key] = field
        return field
    }

    private func slider(_ key: String, min: Double, max: Double, decimals: Int) -> NSView {
        let s = NSSlider(value: min, minValue: min, maxValue: max,
                         target: self, action: #selector(controlChanged(_:)))
        s.identifier = NSUserInterfaceItemIdentifier(key)
        s.isContinuous = true
        s.widthAnchor.constraint(equalToConstant: 200).isActive = true
        controls[key] = s

        let readout = NSTextField(labelWithString: "")
        readout.identifier = NSUserInterfaceItemIdentifier(key + ".readout")
        readout.alignment = .right
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        readout.widthAnchor.constraint(equalToConstant: 46).isActive = true
        controls[key + ".readout"] = readout
        sliderDecimals[key] = decimals

        let stack = NSStackView(views: [s, readout])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private var sliderDecimals: [String: Int] = [:]

    private func stepperField(_ key: String, min: Double, max: Double, step: Double) -> NSView {
        let field = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(key)
        field.alignment = .right
        field.target = self
        field.action = #selector(controlChanged(_:))
        field.widthAnchor.constraint(equalToConstant: 78).isActive = true
        controls[key] = field

        let stepper = NSStepper()
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = step
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        stepper.identifier = NSUserInterfaceItemIdentifier(key + ".stepper")
        controls[key + ".stepper"] = stepper

        let stack = NSStackView(views: [field, stepper])
        stack.orientation = .horizontal
        stack.spacing = 4
        return stack
    }

    /// Only monospaced families: a proportional font makes the cell grid meaningless, so offering
    /// one would be offering a broken terminal.
    private static func monospacedFamilies() -> [String] {
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }
        // `system` first, and not from the family list: SF Mono is not an installed family and
        // cannot be enumerated, so without this the best-looking option on the machine would be
        // the one setting you could not pick from the settings window.
        return ["system"] + (families.isEmpty ? ["Menlo"] : families.sorted())
    }

    // MARK: - Reading the controls back

    @objc private func controlChanged(_ sender: NSControl) {
        guard !isRefreshing, let key = sender.identifier?.rawValue else { return }
        guard let value = value(of: sender, for: key) else { return }
        if let stepper = controls[key + ".stepper"] as? NSStepper, sender is NSTextField {
            stepper.doubleValue = Double(value) ?? stepper.doubleValue
        }
        updateReadout(key, sender.doubleValue)
        store.write([(key: key, value: value)])
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        guard !isRefreshing, let raw = sender.identifier?.rawValue else { return }
        let key = String(raw.dropLast(".stepper".count))
        guard let field = controls[key] as? NSTextField else { return }
        field.stringValue = format(sender.doubleValue, decimals: 0)
        store.write([(key: key, value: field.stringValue)])
    }

    private func value(of sender: NSControl, for key: String) -> String? {
        switch sender {
        case let button as NSPopUpButton:
            let title = button.titleOfSelectedItem ?? ""
            // "none" for a theme override means "no override", which is an absent line rather than
            // a value -- but the file may already carry one, so write the empty string, which the
            // parser reads back as unset.
            return title == SettingsWindowController.noneTitle ? "" : title
        case let button as NSButton:
            // Every other checkbox on this window is a `Bool` field, parsed as `true`/`false`.
            // `remote` is a word-valued `on`/`off` field -- mirroring `shell-integration`, not a
            // boolean -- so writing `true` here left `ConfigParser` unable to parse it at all and
            // the checkbox looked like it did nothing. Caught by the smoke hook in the built app,
            // not by any test: `ConfigParser` tests only ever fed it the right spelling.
            if key == "remote" { return button.state == .on ? "on" : "off" }
            return button.state == .on ? "true" : "false"
        case let slider as NSSlider:
            return format(slider.doubleValue, decimals: sliderDecimals[key] ?? 2)
        case let field as NSTextField:
            return field.stringValue.trimmingCharacters(in: .whitespaces)
        default:
            return nil
        }
    }

    private func format(_ value: Double, decimals: Int) -> String {
        decimals == 0 ? String(Int(value.rounded())) : String(format: "%.\(decimals)f", value)
    }

    private func updateReadout(_ key: String, _ value: Double) {
        guard let readout = controls[key + ".readout"] as? NSTextField else { return }
        readout.stringValue = format(value, decimals: sliderDecimals[key] ?? 2)
    }

    @objc private func openConfigFile(_ sender: Any?) {
        NSWorkspace.shared.open(store.createIfMissing())
    }

    // MARK: - Writing the controls

    private func refresh(_ c: Config, diagnostics: [ConfigDiagnostic]) {
        isRefreshing = true
        defer { isRefreshing = false }

        refreshThemeLists()
        set("theme", c.themeName)
        set("theme-dark", c.darkThemeName)
        set("theme-light", c.lightThemeName)
        set("padding", c.padding, decimals: 0)
        set("background-opacity", c.backgroundOpacity, decimals: 2)
        set("background-blur", c.backgroundBlur, decimals: 0)
        set("tab-bar", c.tabBar.rawValue)
        set("window-decorations", c.windowDecorations)

        set("font-family", c.fontFamily)
        set("font-size", c.fontSize, decimals: 0)
        set("line-height", c.lineHeight, decimals: 2)
        set("font-thicken", c.fontThicken)
        set("cursor-style", cursorName(c.cursorStyle))
        set("cursor-blink", c.cursorBlink)
        set("scrollback-lines", Double(c.scrollbackLines), decimals: 0)

        set("copy-on-select", c.copyOnSelect)
        set("middle-click-paste", c.middleClickPaste)
        set("confirm-close-process", c.confirmCloseProcess)
        set("restore-session", c.restoreSession)
        set("mouse-scroll-alt-screen", c.mouseScrollAltScreen)
        set("clipboard-read", c.clipboardRead)
        set("option-as-meta", c.optionAsMeta.rawValue)
        set("bell", c.bell.rawValue)
        set("multiline-paste", c.multilinePaste.rawValue)
        set("fold-keep-lines", Double(c.foldKeepLines), decimals: 0)
        set("fold-long-output", Double(c.foldLongOutput), decimals: 0)

        set("remote", c.remote == .on)
        set("remote-device-name", c.remoteDeviceName)
        set("remote-relay", c.remoteRelay)
        set("remote-relay-token", c.remoteRelayToken)
        set("remote-snapshot-lines", Double(c.remoteSnapshotLines), decimals: 0)
        refreshRemoteStatus()
        refreshPairedDevicesAndActivity()
        refreshRemoteEnabled()

        let table = KeyBindingTable(user: c.keybinds)
        keyRows = ActionCatalog.allMenuActions.map { action in
            (action, table.binding(for: action).map(SettingsWindowController.describe) ?? "—")
        }
        keysTable.reloadData()

        diagnosticsLabel.stringValue = diagnostics.isEmpty
            ? ""
            : diagnostics.map { $0.line > 0 ? "line \($0.line): \($0.message)" : $0.message }
                .joined(separator: "   ")
        diagnosticsLabel.setAccessibilityValue(diagnostics.isEmpty
            ? "none" : diagnosticsLabel.stringValue)
    }

    private func cursorName(_ shape: CursorShape) -> String {
        switch shape {
        case .block: return "block"
        case .underline: return "underline"
        case .bar: return "bar"
        }
    }

    private func set(_ key: String, _ title: String?) {
        guard let button = controls[key] as? NSPopUpButton else {
            if let field = controls[key] as? NSTextField { field.stringValue = title ?? "" }
            return
        }
        let wanted = title ?? SettingsWindowController.noneTitle
        if button.itemTitles.contains(wanted) {
            button.selectItem(withTitle: wanted)
        } else if !wanted.isEmpty {
            // A theme or font named in the file that this machine does not have: show it rather
            // than silently snapping the control to something else the user never chose.
            button.addItem(withTitle: wanted)
            button.selectItem(withTitle: wanted)
        }
    }

    private func set(_ key: String, _ on: Bool) {
        (controls[key] as? NSButton)?.state = on ? .on : .off
    }

    private func set(_ key: String, _ value: Double, decimals: Int) {
        if let slider = controls[key] as? NSSlider {
            slider.doubleValue = value
            updateReadout(key, value)
        }
        if let field = controls[key] as? NSTextField {
            field.stringValue = format(value, decimals: decimals)
        }
        (controls[key + ".stepper"] as? NSStepper)?.doubleValue = value
    }

    /// `⌘⇧D`, the way the menu writes it.
    private static func describe(_ binding: KeyBinding) -> String {
        var s = ""
        if binding.modifiers.contains(.ctrl) { s += "⌃" }
        if binding.modifiers.contains(.alt) { s += "⌥" }
        if binding.modifiers.contains(.shift) { s += "⇧" }
        if binding.modifiers.contains(.cmd) { s += "⌘" }
        switch binding.key {
        case .char(let c): s += String(c).uppercased()
        case .up: s += "↑"
        case .down: s += "↓"
        case .left: s += "←"
        case .right: s += "→"
        case .enter: s += "⏎"
        case .tab: s += "⇥"
        case .escape: s += "⎋"
        case .backspace: s += "⌫"
        case .delete: s += "⌦"
        case .home: s += "↖"
        case .end: s += "↘"
        case .pageUp: s += "⇞"
        case .pageDown: s += "⇟"
        case .insert: s += "Ins"
        case .f(let n): s += "F\(n)"
        }
        return s
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === pairedTable ? pairedRows.count : keyRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === pairedTable {
            return pairedDeviceCell(tableColumn, row)
        }
        guard let id = tableColumn?.identifier.rawValue, keyRows.indices.contains(row) else { return nil }
        let text = id == "action" ? keyRows[row].action.title : keyRows[row].chord
        let field = NSTextField(labelWithString: text)
        if id == "chord" {
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.textColor = text == "—" ? .tertiaryLabelColor : .labelColor
            // The dash means "nothing is bound", which is a character no screen reader can be
            // relied upon to say and which reads as a stray hyphen when it does.
            field.setAccessibilityLabel(text == "—"
                ? "\(keyRows[row].action.title): no shortcut"
                : "\(keyRows[row].action.title): \(text)")
        }
        return field
    }

    private func pairedDeviceCell(_ tableColumn: NSTableColumn?, _ row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, pairedRows.indices.contains(row) else { return nil }
        let device = pairedRows[row]
        let text: String
        switch id {
        case "name": text = device.name
        case "id": text = String(device.id.prefix(8))
        case "pairedAt": text = SettingsWindowController.pairedDateFormatter.string(from: device.pairedAt)
        default: text = ""
        }
        let field = NSTextField(labelWithString: text)
        if id == "id" { field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) }
        // `NSTableView.isEnabled` does not reach the views inside its rows, so a disabled table
        // still drew its devices at full weight -- the one live-looking thing on a page that is
        // otherwise entirely greyed.
        field.textColor = config.remote == .on ? .labelColor : .tertiaryLabelColor
        return field
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        tableView === pairedTable
    }
}
