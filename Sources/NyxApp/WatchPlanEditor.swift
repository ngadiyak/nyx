import AppKit
import NyxCore

/// The `Watch…` popover: how often, until when, and a sentence saying what that adds up to.
///
/// A popover rather than a sheet because it is three fields attached to one block, and a sheet that
/// covers the window to ask "how many seconds?" is the wrong weight for it -- the same judgement
/// `LensFieldView` is built on. Every rule about what the fields mean is `WatchPlanEditorModel` in
/// NyxCore: this converts typing into model edits and draws what the model says. The Start button
/// is `model.plan != nil` and nothing else, so a form that cannot start cannot claim it can.
final class WatchPlanEditor: NSViewController, NSTextFieldDelegate {
    /// The plan the user pressed Start on. Never called with an invalid one.
    var onStart: ((WatchPlan) -> Void)?

    private var model: WatchPlanEditorModel

    private let intervalField = NSTextField()
    private let stopPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let countField = NSTextField()
    private let conditionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let valueField = NSTextField()
    private let summary = NSTextField(labelWithString: "")
    private let problem = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    /// The count row and the condition row, shown one at a time: a form that offers every field of
    /// every stop rule at once is three questions where the user was asked one.
    private var countRow = NSStackView()
    private var conditionRow = NSStackView()

    init(seed: WatchPlan) {
        self.model = WatchPlanEditor.model(from: seed)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The seeded plan back into fields. The ⋯ menu's row carries the *default* plan, so a popover
    /// opened from it starts on the interval the row beside it names.
    private static func model(from plan: WatchPlan) -> WatchPlanEditorModel {
        var model = WatchPlanEditorModel(interval: plan.interval)
        switch plan.stop {
        case .never: model.stop = .never
        case .count(let times):
            model.stop = .count
            model.count = String(times)
        case .until(let condition):
            model.stop = .until
            switch condition {
            case .status(let code): model.condition = .status; model.value = String(code)
            case .statusClass(let hundreds): model.condition = .statusClass; model.value = String(hundreds)
            case .statusNot(let code): model.condition = .statusNot; model.value = String(code)
            case .bodyContains(let text): model.condition = .bodyContains; model.value = text
            case .bodyLacks(let text): model.condition = .bodyLacks; model.value = text
            }
        }
        return model
    }

    override func loadView() {
        for field in [intervalField, countField, valueField] {
            field.delegate = self
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
        }
        intervalField.stringValue = model.interval
        intervalField.alignment = .right
        intervalField.describeForAccessibility("Seconds between runs", role: .textField)
        countField.stringValue = model.count
        countField.alignment = .right
        countField.describeForAccessibility("Number of runs", role: .textField)
        valueField.stringValue = model.value
        valueField.describeForAccessibility("What the condition compares against", role: .textField)

        stopPopUp.target = self
        stopPopUp.action = #selector(stopChanged)
        for kind in WatchPlanEditorModel.StopKind.allCases { stopPopUp.addItem(withTitle: kind.title) }
        stopPopUp.selectItem(at: WatchPlanEditorModel.StopKind.allCases.firstIndex(of: model.stop) ?? 0)
        stopPopUp.setAccessibilityLabel("When to stop")

        conditionPopUp.target = self
        conditionPopUp.action = #selector(conditionChanged)
        for kind in WatchPlanEditorModel.ConditionKind.allCases {
            conditionPopUp.addItem(withTitle: kind.title)
        }
        conditionPopUp.selectItem(at: WatchPlanEditorModel.ConditionKind.allCases
                                    .firstIndex(of: model.condition) ?? 0)
        conditionPopUp.setAccessibilityLabel("The condition to wait for")

        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        // The system accent, not the terminal's: the popover is system chrome on a system ground,
        // and a theme colour chosen for contrast against a *terminal* background was unreadable
        // here -- nyx-dark's pale blue on the light window ground.
        summary.textColor = .controlAccentColor
        summary.setAccessibilityLabel("What this watch will do")
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        problem.textColor = .systemRed
        problem.setAccessibilityLabel("Why this cannot start")
        // Wrapping, not truncating: the sentences say what a field will accept, which is useless
        // cut off at "Seconds must be a number betwee…".
        problem.lineBreakMode = .byWordWrapping
        problem.preferredMaxLayoutWidth = 260

        startButton.target = self
        startButton.action = #selector(start)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        countRow = row("Runs", countField)
        conditionRow = row(nil, conditionPopUp, valueField)

        let content = NSStackView(views: [
            row("Every", intervalField, label("seconds")),
            row("Stop", stopPopUp),
            countRow,
            conditionRow,
            summary,
            problem,
            row(nil, NSView(), startButton),
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            intervalField.widthAnchor.constraint(equalToConstant: 64),
            countField.widthAnchor.constraint(equalToConstant: 64),
            valueField.widthAnchor.constraint(equalToConstant: 96),
        ])
        view = root
        refresh()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(intervalField)
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func row(_ title: String?, _ views: NSView...) -> NSStackView {
        var all: [NSView] = []
        if let title {
            let caption = NSTextField(labelWithString: title)
            caption.font = .systemFont(ofSize: NSFont.systemFontSize)
            caption.setAccessibilityElement(false)
            all.append(caption)
        }
        all += views
        let stack = NSStackView(views: all)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    // MARK: - Edits

    func controlTextDidChange(_ notification: Notification) {
        model.interval = intervalField.stringValue
        model.count = countField.stringValue
        model.value = valueField.stringValue
        refresh()
    }

    @objc private func stopChanged() {
        let kinds = WatchPlanEditorModel.StopKind.allCases
        model.stop = kinds.indices.contains(stopPopUp.indexOfSelectedItem)
            ? kinds[stopPopUp.indexOfSelectedItem] : .never
        refresh()
    }

    @objc private func conditionChanged() {
        let kinds = WatchPlanEditorModel.ConditionKind.allCases
        model.condition = kinds.indices.contains(conditionPopUp.indexOfSelectedItem)
            ? kinds[conditionPopUp.indexOfSelectedItem] : .status
        refresh()
    }

    @objc private func start() {
        guard let plan = model.plan else {
            NSSound.beep()
            return
        }
        // The popover is the pane's, and closing it is the pane's job: this controller was never
        // *presented*, so `dismiss(nil)` here did nothing at all.
        onStart?(plan)
    }

    /// One place where the model decides what the popover looks like: which rows are up, what the
    /// sentence says, whether Start can be pressed.
    private func refresh() {
        countRow.isHidden = model.stop != .count
        conditionRow.isHidden = model.stop != .until
        valueField.placeholderString = model.condition.placeholder
        summary.stringValue = model.title.isEmpty ? "" : "Watch " + model.title
        // Hidden rather than blank: an empty label still claims a line and the popover would keep
        // a gap where the sentence is not.
        summary.isHidden = summary.stringValue.isEmpty
        problem.stringValue = model.problem ?? ""
        problem.isHidden = model.problem == nil
        startButton.isEnabled = model.plan != nil
    }

    /// The popover's own view, for the snapshot renderer, laid out at its natural size.
    static func snapshotView(seed: WatchPlan,
                             editing: (inout WatchPlanEditorModel) -> Void = { _ in }) -> NSView {
        let editor = WatchPlanEditor(seed: seed)
        editor.loadView()
        editing(&editor.model)
        editor.intervalField.stringValue = editor.model.interval
        editor.countField.stringValue = editor.model.count
        editor.valueField.stringValue = editor.model.value
        editor.stopPopUp.selectItem(at: WatchPlanEditorModel.StopKind.allCases
                                        .firstIndex(of: editor.model.stop) ?? 0)
        editor.conditionPopUp.selectItem(at: WatchPlanEditorModel.ConditionKind.allCases
                                            .firstIndex(of: editor.model.condition) ?? 0)
        editor.refresh()
        let size = editor.view.fittingSize
        editor.view.frame = NSRect(x: 0, y: 0, width: max(300, size.width), height: size.height)
        editor.view.layoutSubtreeIfNeeded()
        return editor.view
    }
}
