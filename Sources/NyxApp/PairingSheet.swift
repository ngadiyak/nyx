import AppKit
import NyxCore

/// The sheet's own window, which exists as a class only so that ⎋ dismisses a state whose Cancel
/// button has gone (`.paired`, `.failed`). AppKit answers ⎋ by looking for a *visible* button with
/// that key equivalent first, and only then sends `cancelOperation` down the responder chain -- whose
/// last stop is the window. The content view cannot do this job: to receive `cancelOperation` it
/// would have to accept first responder, and then it takes the ring away from the code field, so the
/// client's sheet opens with nowhere to type (measured: typing a character reached nothing at all).
private final class PairingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

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
    /// The example a person needs *before* typing, as a caption rather than as placeholder text
    /// inside the field -- see `codeField.placeholderString` in `init`.
    private let codeHintLabel = NSTextField(labelWithString: "")
    /// "A code is six letters and digits, like K7M-4QZ" -- shown under the field when submitting
    /// doesn't normalise; cleared the moment the person edits the field again, not just on retry.
    private let codeErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    /// A spinner that appears the instant a sheet does is a flicker, not a signal: the relay
    /// answers in about 400 ms, so anything shorter than this was never a wait worth drawing.
    private static let progressDelay: TimeInterval = 0.3
    private var progressItem: DispatchWorkItem?
    private let primaryButton: NSButton
    private let secondaryButton: NSButton
    private let content: NSView

    private static let width: CGFloat = 360
    private static let codeFieldAccessibilityLabel = "Enter the code shown on the other Mac"
    private static let invalidCodeMessage = "A code is six letters and digits, like K7M-4QZ"

    private var state: PairingFlow.State = .idle
    /// The code in the field has been sent for this state. Return in the field and the default
    /// button are two routes to one act, and AppKit does not promise which of them a Return press
    /// takes; without this, a build where it took both would join the pairing twice.
    private var submitted = false

    init(side: PairingFlow.Side) {
        self.side = side
        let sheetPanel = PairingPanel(contentRect: NSRect(x: 0, y: 0,
                                                          width: PairingSheet.width, height: 100),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        panel = sheetPanel
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
        // No placeholder. A grey, centred `K7M-4QZ` inside the box reads as a filled value, so
        // people pressed Pair and were told "A code is six letters and digits, like K7M-4QZ" --
        // the message restating the thing that had misled them. The example is a caption instead.
        codeField.placeholderString = nil
        codeHintLabel.stringValue = "Six characters, like K7M-4QZ"
        codeHintLabel.font = .systemFont(ofSize: 11)
        codeHintLabel.textColor = .secondaryLabelColor
        codeHintLabel.alignment = .center
        codeField.describeForAccessibility(PairingSheet.codeFieldAccessibilityLabel)
        codeField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        codeField.delegate = self

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true
        progress.setAccessibilityLabel("Waiting for the relay")

        codeErrorLabel.font = .systemFont(ofSize: 11)
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
        let variableStack = NSStackView(views: [codeLabel, progress, codeField, codeHintLabel,
                                               codeErrorLabel, fingerprintLabel])
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
        sheetPanel.onCancel = { [weak self] in self?.onEvent?(.cancel) }

        update(state: .idle)
    }

    /// Re-renders the sheet from a state alone -- no live `PairingFlow` needed, which is what lets
    /// `UISnapshot` picture every state directly -- then resizes the panel to fit.
    func update(state: PairingFlow.State) {
        self.state = state
        submitted = false
        let text = PairingFlow.sheetText(for: state, side: side)
        titleLabel.stringValue = text.title
        bodyLabel.stringValue = text.body
        bodyLabel.isHidden = text.body.isEmpty

        // Delayed, and cancelled by any state change: a sheet that reaches `showingCode` inside the
        // delay never spins.
        progressItem?.cancel()
        progress.stopAnimation(nil)
        progress.isHidden = true
        if PairingFlow.showsProgress(for: state, side: side) {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.progress.isHidden = false
                self.progress.startAnimation(nil)
                self.resizeToFitContent()
            }
            progressItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + PairingSheet.progressDelay, execute: item)
        }

        // A stale "that code isn't valid" from a previous attempt has no place once the state has
        // actually moved on (e.g. `.idle` -> `.joining`); only editing the field clears it mid-state.
        setCodeError(hidden: true)

        switch state {
        case .showingCode(let code, _):
            codeLabel.stringValue = PairCode.display(code)
            codeLabel.isHidden = false
            codeField.isHidden = true
            codeHintLabel.isHidden = true
            fingerprintLabel.isHidden = true
        case .idle where side == .client:
            codeLabel.isHidden = true
            codeField.isHidden = false
            codeHintLabel.isHidden = false
            codeField.stringValue = ""
            fingerprintLabel.isHidden = true
        case .confirming(_, _, let fingerprint, _, _):
            fingerprintLabel.stringValue = fingerprint
            fingerprintLabel.isHidden = false
            codeLabel.isHidden = true
            codeField.isHidden = true
            codeHintLabel.isHidden = true
        default:
            codeLabel.isHidden = true
            codeField.isHidden = true
            codeHintLabel.isHidden = true
            fingerprintLabel.isHidden = true
        }

        switch state {
        case .paired, .failed:
            // The word goes on the *primary* button, not onto Cancel. Cancel carries ⎋, so moving
            // "Done"/"Close" there left Return doing nothing at all on the two states where it is
            // the only thing a person wants to press. There is nothing to cancel here either way.
            primaryButton.isHidden = false
            primaryButton.title = text.primary ?? "Close"
            secondaryButton.isHidden = true
        default:
            primaryButton.isHidden = text.primary == nil
            primaryButton.title = text.primary ?? ""
            secondaryButton.isHidden = false
            secondaryButton.title = "Cancel"
        }
        // Re-asserted on every update rather than set once in `init`. The sheet is presented with
        // `beginSheet` while it is still `.idle`, which on the host hides the primary button -- and
        // presenting a sheet whose default button is hidden makes AppKit clear that button's
        // `keyEquivalent` outright, for good. Measured in the built app: `[13]` after `init`, `[]`
        // immediately after `beginSheet`. Every later state's primary button -- "Pair", "Accept",
        // "Confirm", "Done", "Close" -- therefore had no Return on it at all.
        primaryButton.keyEquivalent = primaryButton.isHidden ? "" : "\r"
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

    /// The red the error is drawn in, moved far enough to be readable on *this* sheet.
    ///
    /// `NSColor.systemRed` is chosen against a system background in the abstract, and on the sheet's
    /// own `windowBackgroundColor` it measures 3.0:1 in the light appearance and 3.6:1 in the dark
    /// -- both below the 4.5 a line of text needs, and neither visible without rendering the sheet
    /// and measuring it.
    ///
    /// A *dynamic* colour rather than one resolved once, because the two appearances need moving in
    /// opposite directions -- towards black on one, towards white on the other -- and the provider
    /// is called again whenever the appearance changes under a live window.
    ///
    /// The floor is 5, not 4.5: the ratio is computed in sRGB and the window is painted through a
    /// device profile, and the couple of levels between them cost about 0.2 of a ratio. Aiming at
    /// the floor exactly left the rendered pixels measuring 4.26:1.
    private static let readableErrorColor = NSColor(name: nil) { appearance in
        var result = NSColor.systemRed
        appearance.performAsCurrentDrawingAppearance {
            let fixed = RGB.readable(rgb(of: .systemRed), on: rgb(of: .windowBackgroundColor),
                                     towards: rgb(of: .labelColor), minimum: 5)
            result = nsColor(fixed, alpha: 1)
        }
        return result
    }

    private func setCodeError(hidden: Bool) {
        codeErrorLabel.textColor = PairingSheet.readableErrorColor
        codeErrorLabel.isHidden = hidden
        // One example, not two. The error carries the same "like K7M-4QZ" with the reason attached,
        // so the caption steps aside while it is up rather than stacking a grey copy above a red
        // one. Restored only when the field is on screen -- `update(state:)` clears the error before
        // it decides which controls this state shows, and owns the answer for every other state.
        codeHintLabel.isHidden = hidden ? codeField.isHidden : true
        codeField.setAccessibilityLabel(hidden
            ? PairingSheet.codeFieldAccessibilityLabel
            : "\(PairingSheet.codeFieldAccessibilityLabel). \(codeErrorLabel.stringValue)")
    }

    @objc private func primaryPressed() {
        switch state {
        case .requested: onEvent?(.accept)
        case .confirming: onEvent?(.confirmMine)
        // "Done" and "Close": the sheet is finished either way, and dismissing it is all that is
        // left, which is what `.cancel` does to a flow already in a terminal state.
        case .paired, .failed: onEvent?(.cancel)
        // The client's idle sheet: "Pair" submits the field, which is the same act as Return in it.
        case .idle where side == .client: codeSubmitted()
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
        guard !submitted else { return }
        guard let normalised = PairCode.normalise(codeField.stringValue) else {
            codeErrorLabel.stringValue = PairingSheet.invalidCodeMessage
            setCodeError(hidden: false)
            codeField.selectText(nil)
            resizeToFitContent()
            return
        }
        submitted = true
        // `now` starts the five-minute deadline the flow times every later state against; the
        // relay forgets the code at the same point, so this is when the pairing really began.
        onEvent?(.join(code: normalised, now: Date()))
    }
}

extension PairingSheet: NSTextFieldDelegate {
    /// Clears "that code isn't valid" the moment the person starts fixing it -- not only once they
    /// resubmit -- so the message doesn't sit there describing text that no longer exists.
    func controlTextDidChange(_ obj: Notification) {
        submitted = false
        guard obj.object as? NSTextField === codeField, !codeErrorLabel.isHidden else { return }
        setCodeError(hidden: true)
        resizeToFitContent()
    }
}
