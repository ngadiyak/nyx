import AppKit
import NyxCore

/// A non-blocking strip across the top of a window: names config problems, or an informational
/// note, without ever taking focus or interrupting input. Never a modal, never an alert -- a typo
/// in the config must not stop the terminal from working. Slides in on `showProblems`/`showNote`,
/// slides back out on `hide` or the dismiss button.
final class ConfigBanner: NSView {
    var onOpenConfig: (() -> Void)?

    private static let height: CGFloat = 32
    private let messageLabel = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = .systemFont(ofSize: 12)

        let openButton = NSButton(title: "Edit Config", target: self, action: #selector(openConfig))
        openButton.bezelStyle = .inline
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let dismissButton = NSButton(title: "\u{2715}", target: self, action: #selector(dismiss))
        dismissButton.isBordered = false
        // A multiplication sign is the button's whole title, which a screen reader reads out as
        // exactly that.
        dismissButton.describeForAccessibility("Dismiss this message", role: .button)
        openButton.setAccessibilityHelp("Opens ~/.config/nyx/config in your editor.")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Configuration message")
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(messageLabel)
        addSubview(openButton)
        addSubview(dismissButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -8),
            openButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -8),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// `diagnostics.count` problems and the first message with its line number.
    func showProblems(_ diagnostics: [ConfigDiagnostic]) {
        guard let first = diagnostics.first else { hide(); return }
        let suffix = diagnostics.count > 1 ? " (+\(diagnostics.count - 1) more)" : ""
        show(text: "Config error, line \(first.line): \(first.message)\(suffix)", color: .systemYellow)
    }

    /// A non-error notice, e.g. a setting that only takes effect for a new window or session.
    func showNote(_ text: String) {
        show(text: text, color: .systemBlue)
    }

    /// Something went wrong. The same yellow as a config error, because that is what this strip
    /// already means by yellow -- `command not found` announced in the blue "by the way" colour
    /// reads as a note about a setting rather than as the button having failed.
    func showFailure(_ text: String) {
        show(text: text, color: .systemYellow)
    }

    /// Disappears on the next clean reload -- the caller calls this whenever a reload leaves
    /// nothing to report.
    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            heightConstraint.animator().constant = 0
        } completionHandler: { [weak self] in self?.isHidden = true }
    }

    private func show(text: String, color: NSColor) {
        messageLabel.stringValue = text
        setAccessibilityValue(text)
        layer?.backgroundColor = color.withAlphaComponent(0.95).cgColor
        // Dark text on the fill, always. The label followed the system appearance, so in dark mode
        // it drew white on yellow at 2:1 -- the one strip on screen whose entire job is to be read.
        messageLabel.textColor = ConfigBanner.textColor(on: color)
        // `contentTintColor` colours a borderless button's image and leaves a bezelled button's
        // *title* to the system appearance -- so "Edit Config", the only control here that does
        // anything, stayed white on yellow in dark mode. An attributed title is the one that wins.
        let ink = ConfigBanner.textColor(on: color)
        for button in subviews.compactMap({ $0 as? NSButton }) {
            button.contentTintColor = ink
            guard !button.title.isEmpty else { continue }
            button.attributedTitle = NSAttributedString(
                string: button.title,
                attributes: [.foregroundColor: ink,
                             .font: button.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        }
        isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            heightConstraint.animator().constant = Self.height
        }
    }

    /// Black or white, whichever the fill can carry. Relative luminance, not a guess: `systemYellow`
    /// and `systemBlue` need opposite answers.
    static func textColor(on fill: NSColor) -> NSColor {
        guard let rgb = fill.usingColorSpace(.sRGB) else { return .black }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
        return luminance > 0.45 ? .black : .white
    }

    @objc private func openConfig() { onOpenConfig?() }
    @objc private func dismiss() { hide() }
}
