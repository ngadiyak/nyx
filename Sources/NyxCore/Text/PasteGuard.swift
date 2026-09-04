import Foundation

/// What the confirmation sheet says. Assembled in `NyxCore` so the wording is testable and the
/// view only has to place three strings and two buttons.
public struct PasteConfirmation: Equatable {
    public let title: String
    public let detail: String
    /// The first line, made safe to display.
    public let preview: String
    /// How many lines the paste would run.
    public let lineCount: Int

    public init(title: String, detail: String, preview: String, lineCount: Int) {
        self.title = title
        self.detail = detail
        self.preview = preview
        self.lineCount = lineCount
    }

    /// The line under the preview: how much is coming, when there is more than the one line shown.
    public var summary: String {
        lineCount > 1 ? "\(lineCount) lines, first shown above." : ""
    }
}

/// Why a paste is worth stopping to look at, or `nil` when it is not.
public enum PasteWarning: Equatable {
    /// More than one line, so pressing nothing else will run every one of them.
    case multipleLines(count: Int)
    /// One line, but long enough that what is actually being run has scrolled out of sight.
    case veryLong(characters: Int)
    /// Contains a control character the shell would act on rather than display.
    case containsControlCharacters
}

/// Deciding whether a paste should be confirmed.
///
/// Pasting into a shell is the one routine action that runs code you did not read. A block copied
/// from a web page carries its trailing newline, so the last command runs the instant it lands --
/// and if the block was assembled from a page that hid something after a long run of spaces, the
/// user never saw it at all. Every terminal that has been bitten by this ends up with this check.
///
/// The rules are pure so they can be tested exhaustively; the view only decides how to ask.
public enum PasteGuard {
    /// A single line longer than this has content the user cannot see at once.
    public static let longPasteThreshold = 512

    /// Whether `text` deserves a confirmation, given the terminal's own state.
    ///
    /// `bracketedPaste` matters: with it on, the shell is told the text is a paste and will not
    /// execute embedded newlines -- zsh and bash both leave it on the command line for the user to
    /// look at and press return themselves. That is the whole protection, so with it on only truly
    /// exotic content is worth a dialog. With it off, a newline runs.
    public static func warning(for text: String, bracketedPaste: Bool) -> PasteWarning? {
        guard !text.isEmpty else { return nil }

        if containsDangerousControlCharacters(text) { return .containsControlCharacters }

        // With bracketed paste on, the shell shows the text rather than running it, so line count
        // alone is not a reason to interrupt.
        guard !bracketedPaste else { return nil }

        let lines = lineCount(text)
        if lines > 1 { return .multipleLines(count: lines) }
        if text.count > longPasteThreshold { return .veryLong(characters: text.count) }
        return nil
    }

    /// Lines that would be executed: a single trailing newline is how a copied command ends and is
    /// not a second line, but a newline in the middle is.
    public static func lineCount(_ text: String) -> Int {
        var body = Substring(text)
        // `\r\n` is a single Character in Swift, so it has to be named explicitly -- the same trap
        // that once made a whole CRLF config file parse as one line.
        while let last = body.last, last == "\n" || last == "\r" || last == "\r\n" {
            body = body.dropLast()
        }
        guard !body.isEmpty else { return 1 }
        return body.reduce(into: 1) { count, character in
            if character == "\n" || character == "\r\n" || character == "\r" { count += 1 }
        }
    }

    /// The first line, for showing the user what is about to run.
    public static func firstLine(of text: String) -> String {
        String(text.prefix { $0 != "\n" && $0 != "\r" && $0 != "\r\n" })
    }

    /// How much of the first line the sheet shows. Past this the line is quoting itself rather
    /// than informing anyone, and a dialog wide enough for 512 characters cannot be read at all.
    public static let previewLimit = 160

    /// Everything the confirmation needs to say, decided here rather than in the view: what the
    /// paste is, why it is worth stopping for, and the text itself.
    ///
    /// The preview is the point. A dialog that says "this paste has 3 lines" and shows none of
    /// them teaches the user to press the confirming button without reading, which is worse than
    /// having no dialog -- so the first line is always shown, control characters and all, with the
    /// unprintable ones made visible rather than silently dropped.
    public static func confirmation(for warning: PasteWarning, text: String) -> PasteConfirmation {
        let lines = lineCount(text)
        let preview = printablePreview(of: firstLine(of: text))
        switch warning {
        case .multipleLines(let count):
            return PasteConfirmation(
                title: "Paste and run \(count) commands?",
                detail: "The shell is not in bracketed-paste mode, so every line runs the moment "
                    + "it arrives. You will not get a chance to read them first.",
                preview: preview,
                lineCount: count)
        case .veryLong(let characters):
            return PasteConfirmation(
                title: "Paste \(characters) characters?",
                detail: "It is one line, and longer than the window -- what runs may not be what "
                    + "you can see.",
                preview: preview,
                lineCount: lines)
        case .containsControlCharacters:
            return PasteConfirmation(
                title: "Paste text containing control characters?",
                detail: "It carries characters the shell acts on rather than prints. A paste like "
                    + "this can rewrite what is on screen, so what you read need not be what runs.",
                preview: preview,
                lineCount: lines)
        }
    }

    /// The first line with its control characters shown as `^X` and `\u{2400}`-style escapes, cut
    /// to `previewLimit` with an ellipsis. Never returns something a terminal would act on.
    static func printablePreview(of line: String) -> String {
        var out = ""
        var truncated = false
        for scalar in line.unicodeScalars {
            if out.count >= previewLimit {
                truncated = true
                break
            }
            switch scalar.value {
            // A caret escape, the way `cat -v` writes one: the control character's printable
            // partner sixty-four positions up.
            case 0x00...0x1F:
                out += "^"
                out.unicodeScalars.append(Unicode.Scalar(0x40 + scalar.value)!)
            case 0x7F, 0x80...0x9F: out += "^?"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return truncated ? out + "\u{2026}" : out
    }

    /// Control characters a shell acts on rather than prints. Escape is the one that matters: a
    /// paste carrying escape sequences can move the cursor, rewrite what is on screen, or -- with
    /// some shells -- push text into the input buffer, so what the user reads is not what runs.
    ///
    /// Tab is excluded deliberately: pasted code is full of tabs, and warning about every indented
    /// snippet would train people to click through the dialog without reading it, which is worse
    /// than not having one.
    private static func containsDangerousControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: return false          // tab, newline, carriage return
            case 0x00...0x1F, 0x7F: return true          // everything else C0, and delete
            case 0x80...0x9F: return true                // C1
            default: return false
            }
        }
    }
}
