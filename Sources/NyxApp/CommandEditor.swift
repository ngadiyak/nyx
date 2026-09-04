import AppKit
import NyxCore

/// A sheet for looking at a command properly before it runs, and changing it.
///
/// Two situations, one editor. Pasting a long `curl` and needing to change something in the middle
/// of the body: a shell's line editor is a poor place to do that -- no mouse, no wrapping you can
/// read, and a stray newline runs the thing. And re-running a command from the scrollback with one
/// flag different, which today means retyping it or hunting through history.
///
/// The prompt marks are what make the second one possible: the terminal knows where every command
/// began and ended, so "that one, with a change" is a thing it can actually offer.
final class CommandEditor: NSViewController {
    /// The final text, or nil when the sheet was cancelled.
    var onFinish: ((String?) -> Void)?

    private let initialText: String
    private let heading: String
    private let runTitle: String
    private let palette: Palette

    private let textView = NSTextView()
    private let scroller = NSScrollView()
    private let hint = NSTextField(labelWithString: "")

    init(text: String, heading: String, runTitle: String, palette: Palette) {
        self.initialText = text
        self.heading = heading
        self.runTitle = runTitle
        self.palette = palette
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 360))

        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        // Monospaced and in the terminal's own colours: this is the text as the shell will see it,
        // and reading it in the system font would be reading something else.
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = initialText
        textView.isEditable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.backgroundColor = nsColor(palette.background, alpha: 1)
        textView.textColor = nsColor(palette.foreground, alpha: 1)
        textView.insertionPointColor = nsColor(palette.cursor, alpha: 1)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        // Wrapped, not scrolled sideways: a 900-character curl read through a horizontal scroll bar
        // is the problem this sheet exists to solve.
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        scroller.documentView = textView
        scroller.hasVerticalScroller = true
        scroller.borderType = .lineBorder
        scroller.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        updateHint()

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let run = NSButton(title: runTitle, target: self, action: #selector(runCommand))
        // ⌘⏎, not ⏎: plain return has to insert a newline, because a multi-line command is exactly
        // what this is for.
        run.keyEquivalent = "\r"
        run.keyEquivalentModifierMask = [.command]

        let buttons = NSStackView(views: [cancel, run])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(scroller)
        content.addSubview(hint)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            scroller.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scroller.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            hint.topAnchor.constraint(equalTo: scroller.bottomAnchor, constant: 10),
            hint.leadingAnchor.constraint(equalTo: scroller.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: scroller.trailingAnchor),

            buttons.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        view = content
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        // Caret at the end rather than a full selection: the usual next move is to change something
        // in the middle, and arriving with everything selected means one stray key destroys it.
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged),
                                               name: NSText.didChangeNotification, object: textView)
    }

    @objc private func textChanged() { updateHint() }

    private func updateHint() {
        let text = textView.string
        let lines = PasteGuard.lineCount(text)
        hint.stringValue = lines > 1
            ? "\(lines) lines — ⌘↩ runs all of them. Return adds a line."
            : "⌘↩ to run. Return adds a line."
    }

    // MARK: - Finishing

    @objc private func cancel() { onFinish?(nil) }

    @objc private func runCommand() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }
        onFinish?(text)
    }
}
