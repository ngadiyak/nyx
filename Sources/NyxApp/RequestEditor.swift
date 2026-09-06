import AppKit
import NyxCore

/// The request workbench's editing half: one `curl` command shown as the form it always was.
///
/// A pasted `curl` is a wall of quoted words in which changing one header means counting
/// backslashes. The parser already takes it apart, so this sheet shows the pieces -- parameters,
/// headers, body, credentials, options -- lets them be changed, and writes the command back out.
/// Nothing is guessed: what the preview at the bottom says is exactly what would run, and the
/// `Run` button hands that line back the way `CommandEditor` does.
///
/// Every control's action mutates `model` and calls `render()`, which re-reads the model and sets
/// every control. No control keeps state of its own: two sources of truth for "what is this
/// request" is how an editor starts showing one thing and sending another.
final class RequestEditor: NSViewController {
    /// The line to run, or nil when the sheet was cancelled -- `CommandEditor`'s contract, so a
    /// pane can treat the two sheets the same way.
    var onFinish: ((String?) -> Void)?

    /// A repeated run the response side will own. Until it does, the pane runs the request once
    /// and says in the log what was asked for: a menu item that quietly does nothing is worse than
    /// one that does less than it promises.
    var onWatch: ((WatchPlanRequest) -> Void)?

    /// `(name, "quick = …")` for the project's `.nyx` file. The controller never touches a file --
    /// only the pane knows which directory this request belongs to, and the approval gate has to
    /// see the write.
    var onSaveToProject: ((String, String) -> Void)?

    /// What would run right now, for a caller that needs the line without ending the sheet.
    var runLine: String { model.runLine }

    /// Shows one tab. The sheet opens on Params; a caller that knows better -- a snapshot, or a
    /// menu item that means "look at the headers" -- says which.
    func show(tab: RequestEditorModel.Tab) {
        model.tab = tab
        guard isViewLoaded else { return }
        render()
    }

    /// Whether the sheet is currently showing credentials in full, for a caller that has to know
    /// what is on screen before it prints or captures it.
    var isRevealingSecrets: Bool { revealed }

    private var model: RequestEditorModel
    private let palette: Palette
    private let watchInterval: Double
    /// Secrets are masked in the tables, the auth fields and the preview until this is on. A masked
    /// field is also a disabled one; see `RequestEditorModel.Field`.
    private var revealed = false

    private let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let urlField = NSTextField(frame: .zero)
    private let tabs = NSSegmentedControl(labels: RequestEditorModel.Tab.allCases.map(\.rawValue),
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let pages = NSTabView(frame: .zero)

    private lazy var paramTable = FieldTable(kind: .params, owner: self)
    private lazy var headerTable = FieldTable(kind: .headers, owner: self)

    private let bodyText = NSTextView.scrollableTextView()
    private let contentType = NSComboBox(frame: .zero)
    private let prettyButton = NSButton(title: "Pretty-print", target: nil, action: nil)
    private let bodyNote = NSTextField(wrappingLabelWithString: "")

    private let authPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authUserLabel = NSTextField(labelWithString: "User:")
    private let authUserField = NSTextField(frame: .zero)
    private let authSecretLabel = NSTextField(labelWithString: "Token:")
    private let authSecretField = NSTextField(frame: .zero)
    private weak var authGrid: NSGridView?

    private let followBox = NSButton(checkboxWithTitle: "Follow redirects (-L)", target: nil, action: nil)
    private let insecureBox = NSButton(checkboxWithTitle: "Allow insecure TLS (-k)", target: nil, action: nil)
    private let compressedBox = NSButton(checkboxWithTitle: "Compressed (--compressed)", target: nil, action: nil)
    private let verboseBox = NSButton(checkboxWithTitle: "Verbose (-v)", target: nil, action: nil)
    private let failBox = NSButton(checkboxWithTitle: "Fail on 4xx/5xx (-f)", target: nil, action: nil)
    private let maxTimeField = NSTextField(frame: .zero)
    private let retryField = NSTextField(frame: .zero)
    private let outputPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private weak var projectItem: NSMenuItem?
    private let revealBox = NSButton(checkboxWithTitle: "Reveal secrets", target: nil, action: nil)
    private let runNote = NSTextField(labelWithString: "")
    private let preview = NSTextView.scrollableTextView()

    init(command: CurlCommand, palette: Palette, watchInterval: Double = 5) {
        self.model = RequestEditorModel(command: command)
        self.palette = palette
        self.watchInterval = watchInterval
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Building the sheet

    override func loadView() {
        let content = ContentView(frame: NSRect(x: 0, y: 0, width: 720, height: 480))
        content.onLayout = { [weak self] in self?.snapPreview() }

        methodPopup.target = self
        methodPopup.action = #selector(methodChanged)
        methodPopup.setAccessibilityLabel("Method")

        urlField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        urlField.placeholderString = "https://api.example.com/v1/items"
        urlField.delegate = self
        urlField.describeForAccessibility("URL", role: .textField)

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.segmentDistribution = .fillEqually
        tabs.setAccessibilityLabel("Request section")

        pages.tabViewType = .noTabsNoBorder
        pages.translatesAutoresizingMaskIntoConstraints = false
        for tab in RequestEditorModel.Tab.allCases {
            let item = NSTabViewItem(identifier: tab.rawValue)
            item.label = tab.rawValue
            item.view = page(for: tab)
            pages.addTabViewItem(item)
        }

        revealBox.target = self
        revealBox.action = #selector(revealChanged)
        revealBox.toolTip = "Show the credentials in this request in full."

        runNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        runNote.textColor = .systemOrange
        runNote.describeForAccessibility("What this run cannot show", role: .staticText)

        configure(textView(of: preview), editable: false, monospaced: true)
        preview.borderType = .bezelBorder
        previewTextView.describeForAccessibility("Command preview", role: .textArea)

        let top = NSStackView(views: [methodPopup, urlField])
        top.orientation = .horizontal
        top.spacing = 8
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = buttonRow()

        let stack = NSStackView(views: [top, tabs, pages, revealBox, runNote, preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        for view in [top, tabs, pages, preview, buttons] as [NSView] {
            stack.setCustomSpacing(10, after: view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                                         view.trailingAnchor.constraint(equalTo: stack.trailingAnchor)])
        }

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            pages.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            previewHeight,
        ])

        view = content
        render()
    }

    private lazy var previewHeight =
        preview.heightAnchor.constraint(equalToConstant: RequestEditor.previewDesignHeight)

    /// What the Repeat menu says while the response side does not exist.
    static let comingWithTheResponsePlan = "Coming with lenses and watch"

    /// What the Response popup says when a pipeline has already taken the answer away.
    static let unavailableWithAPipeline = "Unavailable with a pipeline"

    /// The width the auth grid's label column is held to: the widest of the four labels it shows
    /// (`Kind:`, `User:`, and `Password:` / `Value:` / `Token:` depending on the kind).
    static let widestAuthLabel: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return ["Kind:", "User:", "Password:", "Value:", "Token:"]
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 80
    }()

    /// The preview shows whole lines, and as many of them as its box has room for.
    private func snapPreview() {
        let text = previewTextView
        guard let manager = text.layoutManager, manager.numberOfGlyphs > 0 else { return }
        // The height AppKit *used* for the first line fragment, not `defaultLineHeight` for the
        // font: they differ by a fraction of a point, and a fraction per line is most of a line by
        // the eighth one -- which is the line that was being sliced.
        let pitch = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
        // The space the *lines* actually get: from the top of the first line fragment to the bottom
        // of what is visible, both in the text view's own coordinates. Taking the container's inset
        // off the clip height instead was wrong by eight points -- the box drew a ninth line that
        // had room to start and not to finish, which is a line of the command with its descenders
        // cut off.
        let firstTop = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY
        let visible = text.visibleRect
        let showing = visible.maxY - max(visible.minY, firstTop)
        guard pitch > 0, showing > 0 else { return }
        let chrome = previewHeight.constant - showing
        let lines = max(1, floor((RequestEditor.previewDesignHeight - chrome) / pitch))
        let target = lines * pitch + chrome
        if abs(previewHeight.constant - target) > 0.5 { previewHeight.constant = target }
    }

    /// About eight lines. The exact height is `snapPreview`'s: this is the space the sheet gives
    /// the box, and it takes the largest whole number of lines that fits in it.
    private static let previewDesignHeight: CGFloat = 118

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(urlField)
        if let editor = urlField.currentEditor() {
            editor.selectedRange = NSRange(location: urlField.stringValue.count, length: 0)
        }
    }

    /// The four buttons and the two pull-downs, right-aligned. `Run` is a plain button rather than
    /// a pull-down so it can be the default one: `⏎` has to run the request, and no pull-down can
    /// carry a key equivalent. The chevron beside it is the menu.
    private func buttonRow() -> NSView {
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyCommand))
        copy.toolTip = "Copy this command, in one line, with its credentials."

        let export = NSPopUpButton(frame: .zero, pullsDown: true)
        export.addItem(withTitle: "Export")
        for format in ExportFormat.allCases {
            let item = NSMenuItem(title: format.title, action: #selector(exportAs(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            export.menu?.addItem(item)
        }
        export.setAccessibilityLabel("Export as")

        let save = NSPopUpButton(frame: .zero, pullsDown: true)
        save.addItem(withTitle: "Save")
        // Manual enabling: a pull-down enables its items from the responder chain by default,
        // which would leave "Save to Project…" live in a pane that has no project to save to.
        save.menu?.autoenablesItems = false
        for (title, action) in [("Save as Button…", #selector(saveAsButton)),
                                ("Save to Project…", #selector(saveToProject))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            save.menu?.addItem(item)
        }
        projectItem = save.menu?.items.last
        save.setAccessibilityLabel("Save this request")

        // A labelled pull-down rather than a bare chevron beside `Run`: a control whose whole
        // face is a disclosure arrow says nothing about what is behind it.
        let repeats = NSPopUpButton(frame: .zero, pullsDown: true)
        repeats.addItem(withTitle: "Repeat")
        // Disabled, not removed. Repeating a request is the response plan's, and running it *once*
        // while a menu says "Run 10 times" is a feature lying about what it did. Left in view and
        // greyed, with a tooltip that says when it arrives: a menu item that vanishes teaches
        // nobody anything, and one that is there and does less than it says is worse.
        repeats.menu?.autoenablesItems = false
        for (title, plan) in [("Run every…", WatchPlanRequest.every(seconds: watchInterval)),
                              ("Run 10 times", .times(10)),
                              ("Run until 200", .untilStatus(200))] {
            let entry = item(title, #selector(runWatch(_:)), plan)
            entry.isEnabled = false
            entry.toolTip = RequestEditor.comingWithTheResponsePlan
            repeats.menu?.addItem(entry)
        }
        // The control itself, not only its items: a pull-down that opens onto three greyed lines
        // is a worse answer than one that is plainly not ready.
        repeats.isEnabled = false
        repeats.toolTip = RequestEditor.comingWithTheResponsePlan
        repeats.setAccessibilityLabel("Run this request repeatedly \u{2014} "
            + RequestEditor.comingWithTheResponsePlan)

        let run = NSButton(title: "Run", target: self, action: #selector(runOnce))
        // ⌘⏎, not ⏎. A plain Return here is a key equivalent, and a key equivalent is offered the
        // event before the first responder is: with `"\r"` alone the sheet ran and closed the
        // moment anyone pressed Return inside the body, so a two-line JSON body could not be
        // typed at all. Return still runs the request from the URL field, where it means that --
        // see `control(_:textView:doCommandBy:)`.
        run.keyEquivalent = "\r"
        run.keyEquivalentModifierMask = [.command]
        run.toolTip = "⌘⏎ — or ⏎ in the URL field"

        let row = NSStackView(views: [cancel, NSView(), copy, export, save, repeats, run])
        row.orientation = .horizontal
        row.spacing = 8
        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func page(for tab: RequestEditorModel.Tab) -> NSView {
        switch tab {
        case .params: return paramTable
        case .headers: return headerTable
        case .body: return bodyPage()
        case .auth: return authPage()
        case .options: return optionsPage()
        }
    }

    private func bodyPage() -> NSView {
        contentType.addItems(withObjectValues: ["application/json",
                                                "application/x-www-form-urlencoded",
                                                "text/plain"])
        contentType.isEditable = true
        contentType.completes = true
        contentType.target = self
        contentType.action = #selector(bodyChanged)
        contentType.delegate = self
        contentType.describeForAccessibility("Content type", role: .comboBox)

        prettyButton.target = self
        prettyButton.action = #selector(prettyPrint)
        prettyButton.controlSize = .small

        let editor = textView(of: bodyText)
        configure(editor, editable: true, monospaced: true)
        editor.delegate = self
        editor.describeForAccessibility("Request body", role: .textArea)
        bodyText.borderType = .bezelBorder

        bodyNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bodyNote.textColor = .secondaryLabelColor

        let head = NSStackView(views: [NSTextField(labelWithString: "Content-Type:"), contentType,
                                       NSView(), prettyButton])
        head.orientation = .horizontal
        head.spacing = 8
        contentType.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        return column([head, bodyText, bodyNote], flexible: bodyText)
    }

    private func authPage() -> NSView {
        authPopup.addItems(withTitles: RequestEditorModel.AuthKind.allCases.map(\.rawValue))
        authPopup.target = self
        authPopup.action = #selector(authChanged)
        authPopup.setAccessibilityLabel("Authentication")

        for field in [authUserField, authSecretField] {
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.target = self
            field.action = #selector(authChanged)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        }
        authUserField.describeForAccessibility("User", role: .textField)
        authSecretField.describeForAccessibility("Secret", role: .textField)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Kind:"), authPopup],
            [authUserLabel, authUserField],
            [authSecretLabel, authSecretField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        // Pinned to the widest label this column will ever hold. Without it the column is as wide
        // as whatever is *visible*, so choosing None -- which hides the two rows under Kind --
        // shrank it to fit "Kind:" and slid the popup 31 points to the left. A control that moves
        // when you change an unrelated value reads as a different sheet.
        grid.column(at: 0).width = RequestEditor.widestAuthLabel
        authGrid = grid

        let note = NSTextField(wrappingLabelWithString:
            "A credential written as a variable \u{2014} $TOKEN \u{2014} is kept as a reference, never "
            + "resolved and never masked: it is not the secret.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        // A spacer to the grid's right so it keeps its own width. Stretched across the page, the
        // grid hands the extra width to its first column -- and a trailing-aligned label then
        // walks to the far side of the sheet whenever the rows under it are hidden.
        let row = NSStackView(views: [grid, NSView()])
        row.orientation = .horizontal
        row.spacing = 0

        return column([row, note, NSView()], flexible: nil)
    }

    private func optionsPage() -> NSView {
        for box in [followBox, insecureBox, compressedBox, verboseBox, failBox] {
            box.target = self
            box.action = #selector(flagChanged(_:))
        }
        followBox.tag = CurlCommand.Flags.location.rawValue
        insecureBox.tag = CurlCommand.Flags.insecure.rawValue
        compressedBox.tag = CurlCommand.Flags.compressed.rawValue
        verboseBox.tag = CurlCommand.Flags.verbose.rawValue
        failBox.tag = CurlCommand.Flags.fail.rawValue

        for field in [maxTimeField, retryField] {
            field.target = self
            field.action = #selector(timingChanged)
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }
        maxTimeField.placeholderString = "none"
        retryField.placeholderString = "none"
        maxTimeField.describeForAccessibility("Maximum time in seconds", role: .textField)
        retryField.describeForAccessibility("Retries", role: .textField)

        outputPopup.addItems(withTitles: RequestEditorModel.OutputMode.allCases.map(\.rawValue))
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged)
        outputPopup.setAccessibilityLabel("Show the response as")

        let switches = NSStackView(views: [followBox, insecureBox, compressedBox, verboseBox, failBox])
        switches.orientation = .vertical
        switches.alignment = .leading
        switches.spacing = 6

        let numbers = NSGridView(views: [
            [NSTextField(labelWithString: "Max time:"), maxTimeField, NSTextField(labelWithString: "seconds")],
            [NSTextField(labelWithString: "Retries:"), retryField, NSTextField(labelWithString: "times")],
            [NSTextField(labelWithString: "Response:"), outputPopup],
        ])
        numbers.rowSpacing = 8
        numbers.columnSpacing = 8
        numbers.column(at: 0).xPlacement = .trailing
        // The popup is wider than the two number fields, so it takes both of their columns.
        numbers.mergeCells(inHorizontalRange: NSRange(location: 1, length: 2),
                           verticalRange: NSRange(location: 2, length: 1))

        let row = NSStackView(views: [switches, numbers])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 28

        return column([row, NSView()], flexible: nil)
    }

    /// A vertical stack whose children span its width, with one of them allowed to grow.
    private func column(_ views: [NSView], flexible: NSView?) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                                         view.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor)])
        }
        if let flexible {
            flexible.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            flexible.setContentHuggingPriority(.defaultLow, for: .vertical)
        }
        return stack
    }

    private var previewTextView: NSTextView { textView(of: preview) }
    private var bodyTextView: NSTextView { textView(of: bodyText) }

    private func textView(of scroller: NSScrollView) -> NSTextView {
        guard let view = scroller.documentView as? NSTextView else {
            fatalError("scrollableTextView did not produce a text view")
        }
        return view
    }

    /// The terminal's own colours for the two boxes that hold command text -- this is the text as
    /// the shell will see it, and the system font on a system ground would be showing something
    /// else. Wrapped rather than scrolled sideways, for the same reason `CommandEditor` is.
    private func configure(_ view: NSTextView, editable: Bool, monospaced: Bool) {
        view.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = editable
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.drawsBackground = true
        view.backgroundColor = nsColor(palette.background, alpha: 1)
        view.textColor = nsColor(palette.foreground, alpha: 1)
        view.insertionPointColor = nsColor(palette.cursor, alpha: 1)
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        if let scroller = view.enclosingScrollView {
            scroller.hasVerticalScroller = true
            scroller.hasHorizontalScroller = false
            scroller.drawsBackground = true
            scroller.backgroundColor = nsColor(palette.background, alpha: 1)
        }
    }

    // MARK: - One render from the model

    /// Re-reads the model and sets every control. Called after every edit, so the sheet has one
    /// state and it is the model's.
    private func render() {
        methodPopup.removeAllItems()
        methodPopup.addItems(withTitles: model.methods)
        methodPopup.selectItem(withTitle: model.command.effectiveMethod)

        setIfChanged(urlField, model.urlString)

        // `tabLabel`, not a count appended here: the badge sits in a constant-width field so the
        // five centred labels do not slide sideways as things are added and removed.
        for (index, tab) in RequestEditorModel.Tab.allCases.enumerated() {
            tabs.setLabel(model.tabLabel(tab), forSegment: index)
        }
        if let index = RequestEditorModel.Tab.allCases.firstIndex(of: model.tab) {
            tabs.selectedSegment = index
            pages.selectTabViewItem(at: index)
        }

        paramTable.show(rows: model.paramRows(revealed: revealed), note: model.paramsNote,
                        canAdd: model.queryIsEditable, editableCount: model.command.url.query.count)
        headerTable.show(rows: model.headerRows(revealed: revealed), note: model.headersNote,
                         canAdd: true, editableCount: model.command.headers.count)

        setIfChanged(bodyTextView, model.bodyText)
        bodyTextView.isEditable = model.bodyIsEditable
        contentType.isEnabled = model.bodyIsEditable
        contentType.stringValue = model.contentTypeHeader ?? ""
        prettyButton.isEnabled = model.bodyIsEditable && !model.bodyText.isEmpty
        bodyNote.stringValue = model.bodyNote ?? ""
        bodyNote.isHidden = model.bodyNote == nil

        let auth = model.authFields(revealed: revealed)
        authPopup.selectItem(withTitle: auth.kind.rawValue)
        // Whole rows, not the views in them: hiding a view leaves the row's height behind, and
        // `None` came out as a popup with two empty bands under it.
        authGrid?.row(at: 1).isHidden = auth.kind != .basic
        authGrid?.row(at: 2).isHidden = auth.kind == .none
        authSecretLabel.stringValue = auth.kind == .basic ? "Password:"
            : (auth.kind == .header ? "Value:" : "Token:")
        setIfChanged(authUserField, auth.user)
        setIfChanged(authSecretField, auth.secret)
        for field in [authUserField, authSecretField] {
            field.isEditable = auth.isEditable
            field.isEnabled = auth.isEditable
            field.toolTip = auth.isEditable ? nil : "Reveal secrets to edit this."
        }

        followBox.state = model.command.flags.contains(.location) ? .on : .off
        insecureBox.state = model.command.flags.contains(.insecure) ? .on : .off
        compressedBox.state = model.command.flags.contains(.compressed) ? .on : .off
        verboseBox.state = model.command.flags.contains(.verbose) ? .on : .off
        failBox.state = model.command.flags.contains(.fail) ? .on : .off
        setIfChanged(maxTimeField, model.command.timing.maxTime.map(Self.number) ?? "")
        setIfChanged(retryField, model.command.timing.retry.map(String.init) ?? "")
        // A pipeline takes the headers and the sentinel away, so there is nothing to choose
        // between: the popup says why rather than showing a mode that will not happen. The note
        // under it (`runNote`) says the same thing at more length; this is the control agreeing
        // with it instead of contradicting it.
        let piped = model.runNote != nil
        outputPopup.isEnabled = !piped
        if piped {
            if outputPopup.item(withTitle: RequestEditor.unavailableWithAPipeline) == nil {
                outputPopup.addItem(withTitle: RequestEditor.unavailableWithAPipeline)
            }
            outputPopup.selectItem(withTitle: RequestEditor.unavailableWithAPipeline)
            outputPopup.toolTip = model.runNote
        } else {
            outputPopup.item(withTitle: RequestEditor.unavailableWithAPipeline)
                .map { outputPopup.menu?.removeItem($0) }
            outputPopup.toolTip = nil
            outputPopup.selectItem(withTitle: model.outputMode.rawValue)
        }

        revealBox.state = revealed ? .on : .off
        runNote.stringValue = model.runNote.map { "⚠︎ " + $0 } ?? ""
        runNote.isHidden = model.runNote == nil
        // Only when it differs: reassigning the string scrolls a long preview back to the top,
        // and every keystroke in a table cell comes through here.
        setIfChanged(previewTextView, revealed ? model.revealedPreview : model.preview)
        previewTextView.setAccessibilityValue(previewTextView.string)
        // Nothing is wired to the project file unless a pane wired it: a menu item that beeps is
        // a menu item that looked available.
        projectItem?.isEnabled = onSaveToProject != nil
    }

    /// Writing a field that is being typed into moves the caret to the end and eats the keystroke,
    /// so a value that has not changed is left alone.
    private func setIfChanged(_ field: NSTextField, _ text: String) {
        if field.stringValue != text { field.stringValue = text }
    }

    private func setIfChanged(_ view: NSTextView, _ text: String) {
        if view.string != text { view.string = text }
    }

    /// `30`, not `30.0`: a timeout that grows a decimal point every time the sheet is redrawn
    /// stops looking like the number that was typed.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - Edits

    @objc private func methodChanged() {
        model.setMethod(methodPopup.titleOfSelectedItem ?? "GET")
        render()
    }

    @objc private func tabChanged() {
        let index = tabs.selectedSegment
        guard RequestEditorModel.Tab.allCases.indices.contains(index) else { return }
        model.tab = RequestEditorModel.Tab.allCases[index]
        render()
    }

    private func commitURL() {
        guard urlField.stringValue != model.urlString else { return }
        model.setURLString(urlField.stringValue)
        render()
    }

    /// Ends whatever is being edited, so the model holds it.
    ///
    /// A field's action fires when its editing ends, and until then the model has the *previous*
    /// value: Run, Copy, Export and both Saves all read the model, and all four would otherwise
    /// have used a body, a header or a timeout the user could see on screen but had not tabbed
    /// out of. Resigning first responder is what makes the field editor give it up.
    private func commitEdits() {
        view.window?.makeFirstResponder(nil)
        commitURL()
    }

    @objc private func revealChanged() {
        revealed = revealBox.state == .on
        render()
    }

    @objc private func bodyChanged() {
        let type = contentType.stringValue.trimmingCharacters(in: .whitespaces)
        model.setBodyText(bodyTextView.string, contentType: type.isEmpty ? nil : type)
        render()
    }

    @objc private func prettyPrint() {
        // Commit what is in the box first: pretty-printing text the model has not been told about
        // would print the previous body.
        let type = contentType.stringValue.trimmingCharacters(in: .whitespaces)
        model.setBodyText(bodyTextView.string, contentType: type.isEmpty ? nil : type)
        let printed = model.prettyPrintBody()
        if !printed { NSSound.beep() }
        bodyNote.stringValue = printed ? (model.bodyNote ?? "") : "This body is not JSON."
        bodyNote.isHidden = false
        render()
        bodyNote.isHidden = printed && model.bodyNote == nil
    }

    @objc private func authChanged() {
        switch RequestEditorModel.AuthKind(rawValue: authPopup.titleOfSelectedItem ?? "") ?? .none {
        case .none:
            model.setAuth(.none)
        case .basic:
            let secret = authSecretField.stringValue
            var password: ShellWord? = secret.isEmpty ? nil : ShellWords.word(literal: secret)
            // `-u sk_test_…:` -- a token as the user half, with an empty *but present* password --
            // keeps its colon until the field is actually typed into.
            if secret.isEmpty, case .basic(_, let existing) = model.command.auth,
               existing?.text.isEmpty == true {
                password = existing
            }
            model.setAuth(.basic(user: authUserField.stringValue, password: password))
        case .bearer:
            model.setAuth(.bearer(ShellWords.word(literal: authSecretField.stringValue)))
        case .header:
            model.setAuth(.header(ShellWords.word(literal: authSecretField.stringValue)))
        }
        render()
    }

    @objc private func flagChanged(_ sender: NSButton) {
        model.toggle(CurlCommand.Flags(rawValue: sender.tag))
        render()
    }

    @objc private func timingChanged() {
        // A field left empty means "curl's default"; text that is not a number is refused rather
        // than silently read as one, and `render()` puts the previous value back.
        let maxTime = maxTimeField.stringValue.trimmingCharacters(in: .whitespaces)
        let retry = retryField.stringValue.trimmingCharacters(in: .whitespaces)
        if !maxTime.isEmpty && Double(maxTime) == nil { NSSound.beep() }
        if !retry.isEmpty && Int(retry) == nil { NSSound.beep() }
        model.setTiming(maxTime: maxTime.isEmpty ? nil : Double(maxTime),
                        retry: retry.isEmpty ? nil : Int(retry))
        render()
    }

    @objc private func outputChanged() {
        let mode = RequestEditorModel.OutputMode(rawValue: outputPopup.titleOfSelectedItem ?? "")
            ?? .headersAndBody
        guard mode == .saveBody else {
            model.setOutputMode(mode, savePath: nil)
            render()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save the response body"
        panel.nameFieldStringValue = "response"
        panel.canCreateDirectories = true
        guard let window = view.window else {
            model.setOutputMode(mode, savePath: nil)
            render()
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            // Cancelled: `setOutputMode` with no path leaves the command alone, and the render
            // below puts the popup back to the mode that is actually in force.
            self.model.setOutputMode(.saveBody, savePath: response == .OK ? panel.url?.path : nil)
            self.render()
        }
    }

    // MARK: - Finishing

    @objc private func cancel() { onFinish?(nil) }

    @objc private func runOnce() {
        commitEdits()
        // `https://` parses, has a scheme and a non-empty raw word, and is not a request. A URL
        // written as a variable has no host to check and is left alone.
        let url = model.serialisedCommand.url
        guard !url.host.isEmpty || url.raw.containsVariable else {
            NSSound.beep()
            view.window?.makeFirstResponder(urlField)
            return
        }
        onFinish?(model.runLine)
    }

    @objc private func copyCommand() {
        commitEdits()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.copyLine, forType: .string)
    }

    @objc private func exportAs(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let format = ExportFormat(rawValue: raw) else { return }
        commitEdits()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RequestExport.render(model.serialisedCommand, as: format),
                                       forType: .string)
    }

    private func item(_ title: String, _ action: Selector, _ plan: WatchPlanRequest) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = Plan(plan)
        return item
    }

    /// `WatchPlanRequest` is an enum, and `representedObject` takes an object.
    private final class Plan: NSObject {
        let request: WatchPlanRequest
        init(_ request: WatchPlanRequest) { self.request = request }
    }

    @objc private func runWatch(_ sender: NSMenuItem) {
        guard let plan = (sender.representedObject as? Plan)?.request else { return }
        commitEdits()
        guard case .every = plan else {
            finishWatch(plan)
            return
        }
        askForInterval()
    }

    /// "Run every…" asks how often. A sheet, never `runModal()`: a modal run loop stops every
    /// session in every window, which is the rule `confirmPaste` follows for the same reason.
    private func askForInterval() {
        guard let window = view.window else { return finishWatch(.every(seconds: watchInterval)) }
        let (alert, field) = RequestEditor.intervalPrompt(seconds: watchInterval)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let seconds = Double(field.stringValue) ?? self.watchInterval
            self.finishWatch(.every(seconds: max(0.5, seconds)))
        }
    }

    /// The prompt itself, built apart from the presenting so a snapshot renders the alert this
    /// sheet really shows rather than a copy of it that can drift.
    static func intervalPrompt(seconds: Double) -> (NSAlert, NSTextField) {
        let alert = NSAlert()
        alert.messageText = "Run this request repeatedly"
        alert.informativeText = "How many seconds between runs?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        field.stringValue = number(seconds)
        field.alignment = .right
        field.describeForAccessibility("Seconds between runs", role: .textField)
        alert.accessoryView = field
        // Explicit, not implied: an `NSAlert` assigns the return key to its first button when it
        // is *run*, and this alert is also built for a snapshot, where it never is -- so the
        // picture showed two identical grey buttons and no default at all.
        let start = alert.addButton(withTitle: "Start")
        start.keyEquivalent = "\r"
        alert.addButton(withTitle: "Cancel")
        return (alert, field)
    }

    /// The button this request would be saved as, prefilled the way `Save as Button…` prefills it.
    /// The rule is `RequestEditorModel.quickActionDraft`, so this sheet, a block's ⋯ menu and the
    /// snapshot of the sheet cannot suggest three different names for one request.
    func quickActionDraft() -> QuickAction { model.quickActionDraft }

    private func finishWatch(_ plan: WatchPlanRequest) {
        onWatch?(plan)
        // The sheet's job is done either way; whoever took the plan owns the running of it.
        onFinish?(nil)
    }

    // MARK: - Saving

    @objc private func saveAsButton() {
        commitEdits()
        let editor = QuickActionEditor(editing: quickActionDraft(), heading: "New Button", verb: "Save")
        editor.onFinish = { [weak self] action in
            self?.dismiss(editor)
            guard let action else { return }
            // The same path the tab bar's own editor uses: the list goes back through the config
            // file, so a button added here appears in every window and is a line someone can read.
            let delegate = NSApp.delegate as? AppDelegate
            delegate?.setQuickActions((delegate?.quickActions ?? []) + [action])
        }
        presentAsSheet(editor)
    }

    @objc private func saveToProject() {
        commitEdits()
        let editor = QuickActionEditor(editing: quickActionDraft(), heading: "New Button", verb: "Save")
        editor.onFinish = { [weak self] action in
            self?.dismiss(editor)
            guard let self, let action else { return }
            // The menu item is disabled without one, so this is belt and braces.
            self.onSaveToProject?(action.name, "quick = " + action.configValue)
        }
        presentAsSheet(editor)
    }
}

/// The sheet's content view, which exists only to report its own layout passes.
///
/// `NSViewController.viewDidLayout` is called for a view inside a window, and the snapshot renderer
/// lays this sheet out with no window at all -- so the row snapping would never run in exactly the
/// pictures that exist to catch a sliced row.
private final class ContentView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - Text delegates

extension RequestEditor: NSTextFieldDelegate, NSTextViewDelegate, NSComboBoxDelegate {
    /// The URL field commits when editing ends and *runs* only on Return. A plain `action` would
    /// fire on both, so tabbing out of the field would have sent the request.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === urlField else { return }
        commitURL()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === urlField, selector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        runOnce()
        return true
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === bodyTextView else { return }
        bodyChanged()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The combo box sends its action on Return but not on a click in the list.
        DispatchQueue.main.async { [weak self] in self?.bodyChanged() }
    }
}

// MARK: - The two tables

/// A name/value table with `+` and `−`, used for both Params and Headers. It draws the rows the
/// model gives it and reports every edit straight back: it decides nothing, not even whether a row
/// can be edited.
final class FieldTable: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case params, headers }

    private let kind: Kind
    private weak var owner: RequestEditor?
    private let table = NSTableView(frame: .zero)
    private let scroller = NSScrollView(frame: .zero)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "+", target: nil, action: nil)
    private let removeButton = NSButton(title: "−", target: nil, action: nil)
    private var rows: [RequestEditorModel.Field] = []
    /// The table's own height, so it can be held to a whole number of rows; `layout()` grows it to
    /// whatever the page allows.
    private lazy var scrollerHeight = scroller.heightAnchor.constraint(equalToConstant: 108)
    /// How many of `rows` are the command's own -- the rest are derived and cannot be removed.
    private var editableCount = 0

    init(kind: Kind, owner: RequestEditor) {
        self.kind = kind
        self.owner = owner
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        for (title, width) in [("Name", 200.0), ("Value", 380.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.width = width
            column.minWidth = 80
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.allowsMultipleSelection = false
        table.setAccessibilityLabel(kind == .params ? "Query parameters" : "Headers")

        scroller.documentView = table
        scroller.hasVerticalScroller = true
        scroller.borderType = .bezelBorder
        scroller.translatesAutoresizingMaskIntoConstraints = false

        addButton.target = self
        addButton.action = #selector(addRow)
        removeButton.target = self
        removeButton.action = #selector(removeRow)
        for button in [addButton, removeButton] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        addButton.describeForAccessibility(kind == .params ? "Add a parameter" : "Add a header",
                                           role: .button)
        removeButton.describeForAccessibility("Remove the selected row", role: .button)

        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false

        // An empty table is otherwise an unexplained black rectangle: it has to say that there is
        // nothing here and how to put something here.
        empty.stringValue = kind == .params
            ? "No query parameters — + adds one, or type them into the URL."
            : "No headers — + adds one."
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroller)
        addSubview(empty)
        addSubview(addButton)
        addSubview(removeButton)
        addSubview(note)
        NSLayoutConstraint.activate([
            scroller.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollerHeight,

            empty.centerXAnchor.constraint(equalTo: scroller.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroller.centerYAnchor),

            addButton.topAnchor.constraint(equalTo: scroller.bottomAnchor, constant: 6),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 28),
            removeButton.topAnchor.constraint(equalTo: addButton.topAnchor),
            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 6),
            removeButton.widthAnchor.constraint(equalToConstant: 28),

            note.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: addButton.bottomAnchor, constant: 4),
        ])
    }

    /// The table shows whole rows or none: see `RequestEditor.floorToWholeRows`. Done here rather
    /// than from the controller because the height is resolved by Auto Layout from whatever space
    /// the sheet has, so the only moment the answer is known is this view's own layout pass.
    override func layout() {
        super.layout()
        // Everything under the table: the gap, the +/− row, and the margin below it. What is left
        // is the table's, and the table shows whole rows or none.
        let below = 6 + addButton.frame.height + 4
        let available = bounds.height - 8 - below
        // The pitch AppKit actually lays rows out at, taken from two of them: `rowHeight` plus
        // `intercellSpacing` is the documented arithmetic and it is two points out per row in this
        // style -- six rows of that is a third of a row, which is exactly a sliced glyph.
        let pitch = table.numberOfRows > 1
            ? table.rect(ofRow: 1).minY - table.rect(ofRow: 0).minY
            : table.rowHeight + table.intercellSpacing.height
        // How much of the height is *not* rows, measured from the three places AppKit hides it:
        // the bezel, the column header -- which sits inside the clip view, so the document's
        // visible rect starts at a *negative* y by exactly its height -- and a five-point gap above
        // the first row that `rect(ofRow: 0)` is the only witness to. Two earlier attempts assumed
        // parts of this and were a row out: the pixels said 5.7 rows while every number the view
        // reported said 6.
        let visible = scroller.documentVisibleRect
        let headerBand = -min(0, visible.minY)
        let firstRowTop = table.numberOfRows > 0 ? table.rect(ofRow: 0).minY : 0
        let rowsShowing = max(0, visible.height - headerBand - firstRowTop)
        guard pitch > 0, rowsShowing > 0 else { return }
        let chrome = scroller.frame.height - rowsShowing
        // The target is a function of the space the page gives this view and of that fixed chrome,
        // never of the current height: a target that depended on the height it sets would grow and
        // shrink on alternate passes, which is a table that flickers by a row.
        let rows = max(1, floor((available - chrome) / pitch))
        let target = rows * pitch + chrome
        if abs(scrollerHeight.constant - target) > 0.5 { scrollerHeight.constant = target }
    }

    func show(rows: [RequestEditorModel.Field], note text: String?, canAdd: Bool, editableCount: Int) {
        self.rows = rows
        self.editableCount = editableCount
        note.stringValue = text ?? ""
        addButton.isEnabled = canAdd
        removeButton.isEnabled = table.selectedRow >= 0 && table.selectedRow < editableCount
        empty.isHidden = !rows.isEmpty
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn else { return nil }
        let isName = column.identifier.rawValue == "Name"
        let field = NSTextField(frame: .zero)
        field.stringValue = isName ? rows[row].name : rows[row].value
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = rows[row].isEditable
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingTail
        field.target = self
        field.action = #selector(cellEdited(_:))
        field.tag = row * 2 + (isName ? 0 : 1)
        field.textColor = rows[row].isEditable ? .labelColor : .secondaryLabelColor
        field.toolTip = rows[row].isEditable ? nil
            : "Reveal secrets to edit this, or edit it where it is written."
        field.describeForAccessibility((isName ? "Name" : "Value") + " of row \(row + 1)",
                                       role: .textField)
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0 && table.selectedRow < editableCount
    }

    @objc private func cellEdited(_ sender: NSTextField) {
        let row = sender.tag / 2
        let isName = sender.tag % 2 == 0
        guard let owner, row < editableCount else { return }
        owner.tableEdited(kind: kind, row: row, isName: isName, text: sender.stringValue)
    }

    @objc private func addRow() {
        owner?.tableAdded(kind: kind)
        // Straight into the new row's name: a row added and left empty is a row that says nothing.
        // `editableCount` has already been updated by the re-render above, so the row that was
        // just appended is the last editable one -- not the one after it, which is either past the
        // end or the first of the derived rows nothing can type into.
        let index = editableCount - 1
        guard index >= 0, index < table.numberOfRows else { return }
        table.editColumn(0, row: index, with: nil, select: true)
    }

    @objc private func removeRow() {
        let row = table.selectedRow
        guard row >= 0, row < editableCount else { return }
        owner?.tableRemoved(kind: kind, row: row)
    }
}

extension RequestEditor {
    /// One cell of one table, written back into the command. The table knows the row index; which
    /// list that index belongs to is decided here, where the model is.
    func tableEdited(kind: FieldTable.Kind, row: Int, isName: Bool, text: String) {
        switch kind {
        case .params:
            var items = model.command.url.query
            guard items.indices.contains(row) else { return }
            if isName {
                items[row].name = text
            } else {
                items[row].value = text
            }
            model.setQuery(items)
        case .headers:
            var headers = model.command.headers
            guard headers.indices.contains(row) else { return }
            if isName {
                headers[row].name = text
            } else {
                headers[row].value = ShellWords.word(literal: text)
                headers[row].removes = false
            }
            model.setHeaders(headers)
        }
        render()
    }

    func tableAdded(kind: FieldTable.Kind) {
        switch kind {
        case .params:
            model.setQuery(model.command.url.query + [CurlCommand.QueryItem(name: "", value: "")])
        case .headers:
            model.setHeaders(model.command.headers
                + [CurlCommand.Header(name: "", value: ShellWord(""), removes: false)])
        }
        render()
    }

    func tableRemoved(kind: FieldTable.Kind, row: Int) {
        switch kind {
        case .params:
            var items = model.command.url.query
            guard items.indices.contains(row) else { return }
            items.remove(at: row)
            model.setQuery(items)
        case .headers:
            var headers = model.command.headers
            guard headers.indices.contains(row) else { return }
            headers.remove(at: row)
            model.setHeaders(headers)
        }
        render()
    }
}
