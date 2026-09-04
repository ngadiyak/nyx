import Foundation

/// Turning the buffer back into the escape sequences that would reproduce it.
///
/// Two things need this. Saving a session's scrollback so it survives a restart -- the complaint
/// people make about terminals more than any other -- and writing what is on screen out to a file
/// so it can be attached to a bug report or pasted into a review.
///
/// Emitting ANSI rather than a private format is the whole trick: restoring is `terminal.feed(text)`
/// through the parser that is already there and already tested, the file is readable with `cat` and
/// `less -R`, and there is no second representation of a cell to keep in step with the first.
public enum Transcript {
    /// What to write for each cell's appearance.
    public struct Options {
        /// Colours and attributes, or plain text. Off is for a file meant to be read, on for one
        /// meant to be restored or looked at in a terminal.
        public var includeAttributes: Bool
        /// Trailing blanks on a line are padding, not content, and stripping them keeps a saved
        /// session from being mostly spaces.
        public var trimTrailingBlanks: Bool
        /// End lines with `\r\n` rather than `\n`.
        ///
        /// Required for anything fed back into a terminal: a bare `\n` moves down a line without
        /// returning to column zero, so a restored scrollback comes back as a staircase. A file
        /// meant to be read by a person wants plain `\n` instead.
        public var carriageReturns: Bool

        public init(includeAttributes: Bool = true, trimTrailingBlanks: Bool = true,
                    carriageReturns: Bool = true) {
            self.includeAttributes = includeAttributes
            self.trimTrailingBlanks = trimTrailingBlanks
            self.carriageReturns = carriageReturns
        }

        public static let forRestoring = Options()
        public static let plainText = Options(includeAttributes: false, carriageReturns: false)

        var lineEnding: String { carriageReturns ? "\r\n" : "\n" }
    }
}

public extension Terminal {
    /// The transcript of a range of absolute rows.
    ///
    /// Only what changed is emitted between cells, so a run of ordinary text costs nothing beyond
    /// the text itself -- which matters when a 10,000-line scrollback is being written on every
    /// quit.
    func transcript(rows: Range<Int>, options: Transcript.Options = .forRestoring) -> String {
        var out = ""
        var pen = Pen()
        var penIsDefault = true

        for absolute in rows.clamped(to: 0..<totalRows) {
            guard let row = absoluteRow(absolute) else { continue }
            var lastContentColumn = row.cells.count - 1
            if options.trimTrailingBlanks {
                while lastContentColumn >= 0 && isBlank(row.cells[lastContentColumn]) { lastContentColumn -= 1 }
            }

            var column = 0
            while column <= lastContentColumn {
                let cell = row.cells[column]
                column += 1
                // The second half of a wide glyph is not a character; the parser will place it
                // again from the width tables when this is read back.
                if cell.attrs.contains(.wideSpacer) { continue }

                if options.includeAttributes {
                    let wanted = penFor(cell)
                    if wanted != pen {
                        out += Transcript.sgr(from: pen, to: wanted, penIsDefault: penIsDefault)
                        pen = wanted
                        penIsDefault = false
                    }
                }
                out += cell.content == 0 ? " " : clusterText(of: cell)
            }

            // Attributes must not bleed past the line they were written on: a background colour
            // left set would paint every following line in a saved transcript.
            if options.includeAttributes && pen != Pen() {
                out += "\u{1b}[0m"
                pen = Pen()
                penIsDefault = true
            }
            // A soft-wrapped row continues the same logical line; a newline here would turn one
            // wrapped command into two lines that no longer reflow.
            if !row.wrapped { out += options.lineEnding }
        }
        return out
    }

    /// The whole buffer: scrollback and screen.
    func transcript(options: Transcript.Options = .forRestoring) -> String {
        transcript(rows: 0..<totalRows, options: options)
    }

    private func isBlank(_ cell: Cell) -> Bool {
        (cell.content == 0 || cell.scalar == " ") && cell.bg == .default && cell.attrs.isEmpty
    }

    private func penFor(_ cell: Cell) -> Pen {
        var pen = Pen()
        pen.fg = cell.fg
        pen.bg = cell.bg
        pen.ul = cell.ul
        // The width flags describe where a glyph sits, not how it looks, and are re-derived when
        // the text is read back -- carrying them here would emit meaningless SGR.
        pen.attrs = cell.attrs.subtracting([.wide, .wideSpacer, CellAttrs.underlineMask])
        pen.underline = cell.underline
        return pen
    }
}

extension Transcript {
    /// The shortest SGR that turns `old` into `new`.
    ///
    /// A reset is emitted whenever an attribute has to be *removed*, because there is no single
    /// "not bold, not italic" code -- SGR 22 also clears dim, and the combinations are not worth
    /// enumerating for the sake of a few bytes.
    static func sgr(from old: Pen, to new: Pen, penIsDefault: Bool) -> String {
        var codes: [String] = []
        let losesAttributes = !old.attrs.subtracting(new.attrs).isEmpty
            || (old.underline != .none && new.underline == .none)
        let mustReset = losesAttributes
            || (old.fg != new.fg && new.fg == .default)
            || (old.bg != new.bg && new.bg == .default)
            || (old.ul != new.ul && new.ul == .default)

        var from = old
        if mustReset && !penIsDefault {
            codes.append("0")
            from = Pen()
        }

        for (attribute, code) in [(CellAttrs.bold, "1"), (.dim, "2"), (.italic, "3"),
                                  (.inverse, "7"), (.hidden, "8"), (.strike, "9"), (.blink, "5")]
        where new.attrs.contains(attribute) && !from.attrs.contains(attribute) {
            codes.append(code)
        }
        if new.underline != from.underline, new.underline != .none {
            codes.append("4:\(new.underline.rawValue)")
        }
        if new.fg != from.fg { codes += colour(new.fg, foreground: true) }
        if new.bg != from.bg { codes += colour(new.bg, foreground: false) }
        if new.ul != from.ul, new.ul != .default { codes += ["58", "2", "\(new.ul.r)", "\(new.ul.g)", "\(new.ul.b)"] }

        guard !codes.isEmpty else { return "" }
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    private static func colour(_ colour: Color, foreground: Bool) -> [String] {
        switch colour.kind {
        case .default:
            return [foreground ? "39" : "49"]
        case .indexed:
            let index = colour.index
            // The first sixteen have their own codes, which every terminal understands and which
            // are two bytes rather than eleven.
            if index < 8 { return ["\(Int(index) + (foreground ? 30 : 40))"] }
            if index < 16 { return ["\(Int(index) - 8 + (foreground ? 90 : 100))"] }
            return [foreground ? "38" : "48", "5", "\(index)"]
        case .rgb:
            return [foreground ? "38" : "48", "2", "\(colour.r)", "\(colour.g)", "\(colour.b)"]
        }
    }
}

public extension Transcript {
    /// Which form to write, from the name the user chose.
    ///
    /// The extension is the whole interface: `.txt` says "I want to read this", anything else says
    /// "I want it to look like it did", and there is no third thing to ask about. Matched case
    /// insensitively, because a save panel will happily hand back `Build.TXT`.
    static func options(forFileNamed name: String) -> Options {
        name.lowercased().hasSuffix(".txt") ? .plainText : .forRestoring
    }

    /// What the save panel says about the name currently in its field, so the choice is visible
    /// before the file is written rather than discovered afterwards in `less`.
    static func formatDescription(forFileNamed name: String) -> String {
        options(forFileNamed: name).includeAttributes
            ? "Saved as ANSI: colours and attributes are kept, and `less -R` shows them. "
                + "End the name in .txt for plain text instead."
            : "Saved as plain text: no colours, no escape sequences."
    }

    /// The name to offer. `.ans` rather than `.txt` because the default keeps colours, and a file
    /// full of escape sequences called `.txt` is a small lie that `cat` tells on.
    ///
    /// The timestamp is local and sortable, and the title -- whatever the tab is called -- is
    /// reduced to something a filesystem will take without complaint.
    static func defaultFileName(title: String, date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d-%02d%02d%02d", p.year ?? 0, p.month ?? 0,
                           p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
        let slug = fileNameSlug(title)
        return slug.isEmpty ? "nyx-\(stamp).ans" : "\(slug)-\(stamp).ans"
    }

    /// A tab title is whatever the shell felt like setting -- a path, a command line, a directory
    /// with a slash in it. Anything but letters, digits, dash and underscore becomes a dash, runs
    /// collapse, and the result is cut short of anything a filesystem would refuse.
    static func fileNameSlug(_ title: String, limit: Int = 40) -> String {
        var out = ""
        var pendingDash = false
        for character in title {
            if character.isLetter || character.isNumber || character == "_" {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
                if out.count >= limit { break }
            } else {
                pendingDash = true
            }
        }
        return out
    }
}
