import AppKit
import NyxCore

/// The sheet that carries a pairing (spec §5.2) from a code, through a fingerprint both people read
/// aloud, to "paired". One sheet for both roles -- host, showing a code; client, typing one -- and
/// for every step after, because the states differ only in which parts show, not in the shape.
///
/// This view knows nothing about the relay. It renders whatever `PairingFlow.State` it is given and
/// turns a button press or a submitted code into a `PairingFlow.Event`; the owner runs that event
/// through the actual `PairingFlow` (and, in Task 9, the real connection) and calls `update(state:)`
/// with the result. `onEvent` is the only way anything leaves this object.
///
/// Sized to its content rather than a fixed box: a state with nothing to show below the body (e.g.
/// `.paired`) would otherwise sit inside the same tall box as `.confirming`, all dead space. Width
/// is fixed at 360; height is `content`'s `fittingSize` at that width, recomputed and applied to the
/// panel on every `update(state:)`.
final class PairingSheet: NSObject {
    let panel: NSPanel
    let side: PairingFlow.Side
    var onEvent: ((PairingFlow.Event) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    /// 28pt monospaced: the one piece of text on this sheet somebody reads aloud to another person
    /// standing at a different keyboard, so it has to be legible across a room, not just on screen.
    private let codeLabel = NSTextField(labelWithString: "")
    private let codeField = NSTextField()
    /// "A code is six letters and digits, like K7M-4QZ" -- shown under the field when submitting
    /// doesn't normalise; cleared the moment the person edits the field again, not just on retry.
    private let codeErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private let primaryButton: NSButton
    private let secondaryButton: NSButton
    private let content: NSView

    private static let width: CGFloat = 360
    private static let codeFieldAccessibilityLabel = "Enter the code shown on the other Mac"
    private static let invalidCodeMessage = "A code is six letters and digits, like K7M-4QZ"

    private var state: PairingFlow.State = .idle

    init(side: PairingFlow.Side) {
        self.side = side
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: PairingSheet.width, height: 100),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.isFloatingPanel = true

        primaryButton = NSButton(title: "", target: nil, action: nil)
        secondaryButton = NSButton(title: "Cancel", target: nil, action: nil)
        content = NSView()
        super.init()

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor

        codeLabel.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.describeForAccessibility("Pairing code", role: .staticText)

        codeField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        codeField.alignment = .center
        codeField.placeholderString = "K7M-4QZ"
        codeField.describeForAccessibility(PairingSheet.codeFieldAccessibilityLabel)
        codeField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        codeField.delegate = self

        codeErrorLabel.font = .systemFont(ofSize: 11)
        codeErrorLabel.textColor = .systemRed
        codeErrorLabel.alignment = .center
        codeErrorLabel.isHidden = true

        fingerprintLabel.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        fingerprintLabel.alignment = .center
        fingerprintLabel.describeForAccessibility("Fingerprint", role: .staticText)

        primaryButton.keyEquivalent = "\r"
        secondaryButton.keyEquivalent = "\u{1b}"

        // The code/field/fingerprint group centres itself as a block; the title and body stay
        // left-aligned. `contentStack.alignment = .width` looked like the way to stretch every
        // arranged view to the full content width, but it does not hold up when `variableStack`'s
        // children are *all* hidden (every state but `.showingCode`/`.confirming`/idle-client): an
        // empty nested stack collapses to zero width, and `.width` resolved that by pinning
        // everything to the *trailing* edge instead of stretching it -- every row in those states
        // came out right-aligned. Explicit widths on the two rows that need one, with `.leading`
        // alignment (which reliably pins the leading edge regardless of a sibling's width), avoids
        // the interaction entirely.
        let rowWidth = PairingSheet.width - 40   // the 20pt margin on each side
        let variableStack = NSStackView(views: [codeLabel, codeField, codeErrorLabel, fingerprintLabel])
        variableStack.orientation = .vertical
        variableStack.alignment = .centerX
        variableStack.spacing = 6
        variableStack.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        bodyLabel.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true

        let contentStack = NSStackView(views: [titleLabel, bodyLabel, variableStack])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentStack)
        content.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: PairingSheet.width),

            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
        panel.contentView = content

        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed)
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryPressed)
        codeField.target = self
        codeField.action = #selector(codeSubmitted)

        update(state: .idle)
    }

    /// Re-renders the sheet from a state alone -- no live `PairingFlow` needed, which is what lets
    /// `UISnapshot` picture every state directly -- then resizes the panel to fit.
    func update(state: PairingFlow.State) {
        self.state = state
        let text = PairingFlow.sheetText(for: state)
        titleLabel.stringValue = text.title
        bodyLabel.stringValue = text.body
        bodyLabel.isHidden = text.body.isEmpty

        // A stale "that code isn't valid" from a previous attempt has no place once the state has
        // actually moved on (e.g. `.idle` -> `.joining`); only editing the field clears it mid-state.
        setCodeError(hidden: true)

        switch state {
        case .showingCode(let code, _):
            codeLabel.stringValue = PairCode.display(code)
            codeLabel.isHidden = false
            codeField.isHidden = true
            fingerprintLabel.isHidden = true
        case .idle where side == .client:
            codeLabel.isHidden = true
            codeField.isHidden = false
            codeField.stringValue = ""
            fingerprintLabel.isHidden = true
        case .confirming(_, _, let fingerprint, _, _):
            fingerprintLabel.stringValue = fingerprint
            fingerprintLabel.isHidden = false
            codeLabel.isHidden = true
            codeField.isHidden = true
        default:
            codeLabel.isHidden = true
            codeField.isHidden = true
            fingerprintLabel.isHidden = true
        }

        // A terminal state (paired/failed) has nothing left to accept or confirm, so the primary
        // button -- "Accept"/"Confirm" -- steps aside and the dismiss button carries the state's
        // own word ("Done"/"Close") instead of the generic "Cancel".
        switch state {
        case .paired, .failed:
            primaryButton.isHidden = true
            secondaryButton.title = text.primary ?? "Close"
        default:
            primaryButton.isHidden = text.primary == nil
            primaryButton.title = text.primary ?? ""
            secondaryButton.title = "Cancel"
        }
        primaryButton.describeForAccessibility(primaryButton.title)
        secondaryButton.describeForAccessibility(secondaryButton.title)

        resizeToFitContent()
    }

    /// Recomputes `content`'s required height at the fixed width and applies it to the panel.
    /// Hidden arranged views take no space in an `NSStackView`, so this alone is what keeps
    /// `.paired`/`.failed` short and `.confirming` tall, instead of one fixed box for every state.
    private func resizeToFitContent() {
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        panel.setContentSize(NSSize(width: PairingSheet.width, height: max(height, 1)))
    }

    private func setCodeError(hidden: Bool) {
        codeErrorLabel.isHidden = hidden
        codeField.setAccessibilityLabel(hidden
            ? PairingSheet.codeFieldAccessibilityLabel
            : "\(PairingSheet.codeFieldAccessibilityLabel). \(codeErrorLabel.stringValue)")
    }

    @objc private func primaryPressed() {
        switch state {
        case .requested: onEvent?(.accept)
        case .confirming: onEvent?(.confirmMine)
        default: break
        }
    }

    @objc private func secondaryPressed() {
        onEvent?(.cancel)
    }

    /// Drives exactly the path a bad code takes, without duplicating it -- used only by
    /// `UISnapshot`, so the error state can be pictured (client side, an invalid code just typed)
    /// without hand-rolling what `codeSubmitted` already does end to end.
    func simulateInvalidCodeSubmission(_ text: String) {
        codeField.stringValue = text
        codeSubmitted()
    }

    @objc private func codeSubmitted() {
        guard let normalised = PairCode.normalise(codeField.stringValue) else {
            codeErrorLabel.stringValue = PairingSheet.invalidCodeMessage
            setCodeError(hidden: false)
            codeField.selectText(nil)
            resizeToFitContent()
            return
        }
        onEvent?(.join(code: normalised))
    }
}

extension PairingSheet: NSTextFieldDelegate {
    /// Clears "that code isn't valid" the moment the person starts fixing it -- not only once they
    /// resubmit -- so the message doesn't sit there describing text that no longer exists.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === codeField, !codeErrorLabel.isHidden else { return }
        setCodeError(hidden: true)
        resizeToFitContent()
    }
}
