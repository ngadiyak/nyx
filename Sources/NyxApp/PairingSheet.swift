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
final class PairingSheet {
    let panel: NSPanel
    let side: PairingFlow.Side
    var onEvent: ((PairingFlow.Event) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    /// 28pt monospaced: the one piece of text on this sheet somebody reads aloud to another person
    /// standing at a different keyboard, so it has to be legible across a room, not just on screen.
    private let codeLabel = NSTextField(labelWithString: "")
    private let codeField = NSTextField()
    private let fingerprintLabel = NSTextField(labelWithString: "")
    private let primaryButton: NSButton
    private let secondaryButton: NSButton

    private static let size = NSSize(width: 360, height: 230)

    init(side: PairingFlow.Side) {
        self.side = side
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: PairingSheet.size),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.isFloatingPanel = true

        primaryButton = NSButton(title: "", target: nil, action: nil)
        secondaryButton = NSButton(title: "Cancel", target: nil, action: nil)

        let content = NSView(frame: NSRect(origin: .zero, size: PairingSheet.size))

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.font = .monospacedSystemFont(ofSize: 28, weight: .semibold)
        codeLabel.alignment = .center
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.describeForAccessibility("Pairing code", role: .staticText)

        codeField.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        codeField.alignment = .center
        codeField.placeholderString = "K7M-4QZ"
        codeField.translatesAutoresizingMaskIntoConstraints = false
        codeField.describeForAccessibility("Enter the code shown on the other Mac")

        fingerprintLabel.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        fingerprintLabel.alignment = .center
        fingerprintLabel.translatesAutoresizingMaskIntoConstraints = false
        fingerprintLabel.describeForAccessibility("Fingerprint", role: .staticText)

        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.keyEquivalent = "\r"
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.keyEquivalent = "\u{1b}"

        content.addSubview(titleLabel)
        content.addSubview(bodyLabel)
        content.addSubview(codeLabel)
        content.addSubview(codeField)
        content.addSubview(fingerprintLabel)
        content.addSubview(secondaryButton)
        content.addSubview(primaryButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            bodyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            codeLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 16),
            codeLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),

            codeField.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 16),
            codeField.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            codeField.widthAnchor.constraint(equalToConstant: 160),

            fingerprintLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 16),
            fingerprintLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            fingerprintLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            secondaryButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -10),

            primaryButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            primaryButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
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

    private var state: PairingFlow.State = .idle

    /// Re-renders the sheet from a state alone -- no live `PairingFlow` needed, which is what lets
    /// `UISnapshot` picture every state directly.
    func update(state: PairingFlow.State) {
        self.state = state
        let text = PairingFlow.sheetText(for: state)
        titleLabel.stringValue = text.title
        bodyLabel.stringValue = text.body
        bodyLabel.isHidden = text.body.isEmpty

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

    @objc private func codeSubmitted() {
        guard let normalised = PairCode.normalise(codeField.stringValue) else {
            NSSound.beep()
            return
        }
        onEvent?(.join(code: normalised))
    }
}
