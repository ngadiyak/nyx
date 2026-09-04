import AppKit
import NyxCore

/// The strip that appears when the pane's directory has a `.nyx` file the user has not agreed to.
///
/// It offers to *show* the actions, never to run them: nothing from a project file may run, appear
/// as a button, or reach the palette before the user has read the commands and approved that
/// directory. The bar is the only thing an unapproved project gets, and it is not modal -- a
/// repository must not be able to interrupt anyone's typing by existing.
///
/// Which of the two messages it shows, and the wording of each, are `ProjectActionsGate` in
/// NyxCore.
final class ProjectActionsBar: NSView {
    /// Show the commands and offer to approve them.
    var onReview: (() -> Void)?
    /// Leave this directory alone for now.
    var onIgnore: (() -> Void)?

    private static let height: CGFloat = 32
    private let messageLabel = NSTextField(labelWithString: "")
    private let reviewButton = NSButton(title: "Review\u{2026}", target: nil, action: nil)
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .systemFont(ofSize: 12)

        reviewButton.target = self
        reviewButton.action = #selector(review)
        reviewButton.bezelStyle = .inline
        reviewButton.translatesAutoresizingMaskIntoConstraints = false

        let ignoreButton = NSButton(title: "Ignore", target: self, action: #selector(ignore))
        ignoreButton.bezelStyle = .inline
        // "Review…" and "Ignore" name themselves; what they are about is the strip, and this is
        // the one strip in the application where pressing the wrong thing runs somebody else's
        // commands.
        reviewButton.describeForAccessibility("Review this folder’s actions before approving them",
                                              role: .button)
        ignoreButton.describeForAccessibility("Ignore this folder’s actions for now", role: .button)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Project actions")
        ignoreButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(messageLabel)
        addSubview(reviewButton)
        addSubview(ignoreButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: reviewButton.leadingAnchor, constant: -8),
            reviewButton.trailingAnchor.constraint(equalTo: ignoreButton.leadingAnchor, constant: -8),
            reviewButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ignoreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ignoreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// nil hides the bar.
    func show(message: String?, changed: Bool) {
        guard let message else {
            hide()
            return
        }
        messageLabel.stringValue = message
        setAccessibilityValue(message)
        // A project whose actions *changed* under an existing approval is the case worth a warning
        // colour: the user already said yes once, and this is telling them that yes no longer
        // covers what is in the file.
        layer?.backgroundColor = (changed ? NSColor.systemYellow : NSColor.systemBlue)
            .withAlphaComponent(0.85).cgColor
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            heightConstraint.animator().constant = Self.height
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            heightConstraint.animator().constant = 0
        } completionHandler: { [weak self] in self?.isHidden = true }
    }

    @objc private func review() { onReview?() }
    @objc private func ignore() { onIgnore?() }
}
