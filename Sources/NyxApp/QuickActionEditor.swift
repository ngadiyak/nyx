import AppKit
import NyxCore

/// The sheet for adding or editing one quick-action button.
///
/// Buttons were configurable only by editing a config file and knowing its syntax, which is a
/// power-user path in a feature whose whole point is not having to type the command again. This is
/// the other path: a name, a command, and what pressing it should do.
///
/// It writes back through `ConfigWriter.settingList`, so the file stays the single source of truth
/// -- comments and ordering survive, and a button added here is a line someone can read, edit by
/// hand, or put under version control like the rest of their configuration.
final class QuickActionEditor: NSViewController {
    /// The finished action, or nil when the sheet was cancelled.
    var onFinish: ((QuickAction?) -> Void)?

    private let existing: QuickAction?
    private let nameField = NSTextField(frame: .zero)
    private let commandField = NSTextField(frame: .zero)
    private let kindControl = NSSegmentedControl(labels: ["Type it", "New tab", "Background"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let explanation = NSTextField(wrappingLabelWithString: "")

    init(editing action: QuickAction? = nil) {
        self.existing = action
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 232))

        let title = NSTextField(labelWithString: existing == nil ? "New Button" : "Edit Button")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        nameField.placeholderString = "Caffeine"
        commandField.placeholderString = "caffeinate -d"
        for field in [nameField, commandField] {
            field.font = .systemFont(ofSize: 13)
            field.target = self
            field.action = #selector(fieldChanged)
        }
        commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        kindControl.target = self
        kindControl.action = #selector(fieldChanged)
        kindControl.selectedSegment = 0
        // The three fields are named only by the text to their left, which nothing connects them
        // to; the explanation under them changes as the segment changes and is the only place the
        // difference between the three is stated at all.
        nameField.describeForAccessibility("Name", role: .textField)
        commandField.describeForAccessibility("Command", role: .textField)
        kindControl.setAccessibilityLabel("When pressed")
        explanation.describeForAccessibility("What this button will do", role: .staticText)

        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: existing == nil ? "Add" : "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"

        if let existing {
            nameField.stringValue = existing.name
            commandField.stringValue = existing.command
            kindControl.selectedSegment = segment(for: existing.kind)
        }

        let grid = NSGridView(views: [
            [label("Name"), nameField],
            [label("Command"), commandField],
            [label("When pressed"), kindControl],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        explanation.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(grid)
        content.addSubview(explanation)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            grid.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),

            explanation.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 12),
            explanation.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: explanation.bottomAnchor, constant: 12),
        ])
        view = content
        updateExplanation()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text + ":")
    }

    // MARK: - Kind

    private func segment(for kind: QuickActionKind) -> Int {
        switch kind {
        case .send: return 0
        case .run: return 1
        case .toggle: return 2
        }
    }

    private var selectedKind: QuickActionKind {
        switch kindControl.selectedSegment {
        case 1: return .run
        case 2: return .toggle
        default: return .send
        }
    }

    /// Says in words what the chosen kind will do, because the three are genuinely different and
    /// the difference is the thing a person gets wrong.
    private func updateExplanation() {
        defer { explanation.setAccessibilityValue(explanation.stringValue) }
        switch selectedKind {
        case .send:
            explanation.stringValue = "Types the command into the current pane and runs it, so it "
                + "lands in your shell history and can be edited or re-run."
        case .run:
            explanation.stringValue = "Opens a new tab and runs it there, leaving the pane you are "
                + "in alone."
        case .toggle:
            explanation.stringValue = "Starts it in the background and stops it when you press "
                + "again — for something like caffeinate that has to stay running but is never "
                + "worth looking at. It stops when Nyx quits."
        }
    }

    @objc private func fieldChanged() { updateExplanation() }

    // MARK: - Finishing

    @objc private func cancel() {
        onFinish?(nil)
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let command = commandField.stringValue.trimmingCharacters(in: .whitespaces)
        // A nameless or commandless button would be a chip that does nothing; refuse rather than
        // writing a line the parser will reject and report as a config error later.
        guard !name.isEmpty, !command.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(name.isEmpty ? nameField : commandField)
            return
        }
        onFinish?(QuickAction(name: name, kind: selectedKind, command: command))
    }
}

extension QuickAction {
    /// The config-file form of this action, for `ConfigWriter.settingList`.
    var configValue: String { "\(name) | \(kind.rawValue) | \(command)" }
}
