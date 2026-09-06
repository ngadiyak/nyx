import Foundation

/// One shell word as `ShellWords.split` sees it: a sequence of literal text and variable
/// references, kept separate so a later stage can substitute `$TOKEN` without guessing which
/// slice of the joined string used to be a variable.
public struct ShellWord: Equatable {
    /// A slice of a word. `.variable` keeps the reference's exact source spelling (`$TOKEN`,
    /// `${TOKEN}`, `$(cmd)`) rather than a resolved value -- nothing here has a shell to run.
    public enum Piece: Equatable {
        case text(String)
        case variable(String)
    }

    public let pieces: [Piece]

    /// A word made of a single literal piece -- the common case for flags and bare arguments.
    public init(_ text: String) {
        self.pieces = [.text(text)]
    }

    /// An empty list becomes `[.text("")]` so the empty word has exactly one spelling. Without
    /// this, `split("''")` -- which accumulates no pieces at all -- produces a word whose `text`
    /// is `""` but which is not `==` to `ShellWord("")`, and `curl -d ''` becomes a body no
    /// caller can construct or compare against.
    public init(pieces: [Piece]) {
        self.pieces = pieces.isEmpty ? [.text("")] : pieces
    }

    /// Pieces joined back into one string, variables spelled verbatim (`$TOKEN`, not a value).
    public var text: String {
        pieces.map {
            switch $0 {
            case .text(let t): return t
            case .variable(let v): return v
            }
        }.joined()
    }

    /// True when the whole word is one variable reference and nothing else, e.g. bare `$TOKEN`
    /// as a curl argument. `quote` writes these bare since quoting would change their meaning.
    public var isVariable: Bool {
        if case .variable = pieces.first, pieces.count == 1 { return true }
        return false
    }

    public var containsVariable: Bool {
        pieces.contains { if case .variable = $0 { return true }; return false }
    }
}

/// A POSIX-shell-ish word splitter for curl command lines: enough of `sh` quoting to round-trip
/// a copy-pasted `curl` invocation, not a shell. It does not expand variables, glob, or interpret
/// operators (`|`, `&&`, `>`, ...) -- those come back as ordinary words for the caller to read.
public enum ShellWords {
    /// Splits `line` into words. Returns `nil` when a `'` or `"` is never closed -- the one error
    /// this scanner can hit, since everything else (bare `\`, bare `$`, stray operators) has a
    /// literal fallback reading.
    public static func split(_ line: String) -> [ShellWord]? {
        let scalars = Array(line.unicodeScalars)
        let n = scalars.count
        var i = 0

        var words: [ShellWord] = []
        var pieces: [ShellWord.Piece] = []
        var text = ""
        var inWord = false

        func flushText() {
            if !text.isEmpty {
                pieces.append(.text(text))
                text = ""
            }
        }
        func flushWord() {
            flushText()
            if inWord {
                words.append(ShellWord(pieces: pieces))
            }
            pieces = []
            inWord = false
        }

        while i < n {
            let c = scalars[i]

            // Outside quotes, "\" + newline (or "\" + CRLF, from a pasted Windows-style line)
            // vanishes completely before anything else looks at it: checked here, ahead of the
            // word-boundary logic below, so it never reads as whitespace (which would flush a
            // word that hasn't started) or as content (which would start one) -- either way
            // produces a phantom empty word around it.
            if c == "\\", let next = continuationEnd(scalars, at: i) {
                i = next
                continue
            }

            if !inWord {
                if c == " " || c == "\t" || c == "\n" || c == "\r" {
                    i += 1
                    continue
                }
                if c == "#" {
                    // A comment runs to the end of the line; nothing after it is a word.
                    break
                }
                inWord = true
                // Fall through: `c` is the first character of the new word.
            }

            // `$'...'` (ANSI-C quoting, e.g. Chrome's "Copy as cURL" emitting
            // `--data-raw $'{"a":1}'`) is a distinct literal-with-escapes construct, not a
            // variable followed by a quote -- handled here, ahead of the switch below, because
            // it needs its own escape rules and its own closing `'` scanned as one unit.
            if c == "$", i + 1 < n, scalars[i + 1] == "'" {
                guard let (decoded, next) = scanAnsiCQuoted(scalars, at: i) else { return nil }
                text += decoded
                i = next
                continue
            }

            switch c {
            case "'":
                i += 1
                let start = i
                while i < n, scalars[i] != "'" { i += 1 }
                guard i < n else { return nil }
                text += String(String.UnicodeScalarView(scalars[start..<i]))
                i += 1

            case "\"":
                i += 1
                var terminated = false
                while i < n {
                    let d = scalars[i]
                    if d == "\"" {
                        i += 1
                        terminated = true
                        break
                    }
                    if d == "\\", let next = continuationEnd(scalars, at: i) {
                        i = next // backslash-newline (or backslash-CRLF) vanishes even in quotes
                        continue
                    }
                    if d == "\\", i + 1 < n {
                        let e = scalars[i + 1]
                        switch e {
                        case "\"", "\\", "$", "`":
                            text.unicodeScalars.append(e)
                            i += 2
                        default:
                            // Not a recognized double-quote escape: the backslash is literal.
                            text.unicodeScalars.append(d)
                            i += 1
                        }
                        continue
                    }
                    if d == "$", let (spelling, next) = scanVariable(scalars, at: i) {
                        flushText()
                        pieces.append(.variable(spelling))
                        i = next
                        continue
                    }
                    text.unicodeScalars.append(d)
                    i += 1
                }
                guard terminated else { return nil }

            case "\\":
                // The backslash-newline continuation is caught above, ahead of the loop; every
                // other bare `\` escapes exactly the next character.
                if i + 1 < n {
                    text.unicodeScalars.append(scalars[i + 1])
                    i += 2
                } else {
                    text.unicodeScalars.append(c) // trailing backslash with nothing to escape
                    i += 1
                }

            case "$":
                if let (spelling, next) = scanVariable(scalars, at: i) {
                    flushText()
                    pieces.append(.variable(spelling))
                    i = next
                } else {
                    text.unicodeScalars.append(c)
                    i += 1
                }

            case " ", "\t", "\n", "\r":
                flushWord()
                i += 1

            default:
                text.unicodeScalars.append(c)
                i += 1
            }
        }

        flushWord()
        return words
    }

    /// Writes `word` the way `CurlCommand.shellLine` spells a rebuilt curl command: bare when
    /// nothing in it needs protecting from the shell, single-quoted when it is safe literal text,
    /// double-quoted (with `\"`, `\\`, `\$`, `` \` `` escaped) when it either contains a `'` or
    /// mixes in a variable that must stay live. The backtick is escaped even though single
    /// quoting handles most of these cases: unescaped inside double quotes it would start a
    /// command substitution in a real shell, which is exactly the kind of live behaviour a
    /// literal piece must not gain by being written back out.
    public static func quote(_ word: ShellWord) -> String {
        if word.isVariable, case .variable(let v) = word.pieces.first {
            return v
        }

        if word.containsVariable {
            var out = "\""
            for piece in word.pieces {
                switch piece {
                case .text(let t): out += escapedForDoubleQuotes(t)
                case .variable(let v): out += v
                }
            }
            out += "\""
            return out
        }

        let t = word.text
        if t.unicodeScalars.contains(where: isControl) {
            // A newline inside single quotes is legal and reads back correctly, but it puts a bare
            // line in the middle of `shellLine`'s `\`-continued block, which looks like a broken
            // paste. `$'...'` keeps every group on one line. Nyx targets zsh and bash, where this
            // is available; POSIX `sh` is not a target. Note this branch sits *after* the variable
            // one on purpose: `$'...'` does not expand variables, so a word carrying a live
            // reference must keep its double quotes even when it also holds a newline.
            return ansiCQuoted(t)
        }
        if !t.isEmpty, t.unicodeScalars.allSatisfy(isBareSafe) {
            return t
        }
        if t.contains("'") {
            return "\"" + escapedForDoubleQuotes(t) + "\""
        }
        return "'" + t + "'"
    }

    /// C0 controls plus DEL: the characters that would otherwise be written into the output
    /// literally, where a newline breaks the line structure and the rest are invisible.
    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s.value == 0x7F
    }

    /// Writes `text` as `$'...'`, the inverse of `scanAnsiCQuoted`. Every control character gets an
    /// escape -- the common three by name, the rest as exactly two hex digits, which matters
    /// because the scanner reads *at most* two and a shorter form would swallow a following digit.
    private static func ansiCQuoted(_ text: String) -> String {
        var out = "$'"
        for s in text.unicodeScalars {
            switch s {
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            default:
                if isControl(s) {
                    out += "\\x" + String(format: "%02x", s.value)
                } else {
                    out.unicodeScalars.append(s)
                }
            }
        }
        return out + "'"
    }

    /// Characters a curl argument can carry unquoted without a shell reinterpreting them:
    /// letter/digit plus `_./:@%=+,-`. `?` is deliberately excluded even though it's common in
    /// query strings: it's a glob character in zsh and bash, and under zsh's default `nomatch`
    /// a bare `curl https://x/y?x=1` fails with "no matches found" before curl even runs. A word
    /// containing `?` falls through to single-quoting below.
    private static func isBareSafe(_ s: Unicode.Scalar) -> Bool {
        if ("A" as Unicode.Scalar) ... ("Z" as Unicode.Scalar) ~= s { return true }
        if ("a" as Unicode.Scalar) ... ("z" as Unicode.Scalar) ~= s { return true }
        if ("0" as Unicode.Scalar) ... ("9" as Unicode.Scalar) ~= s { return true }
        switch s {
        case "_", ".", "/", ":", "@", "%", "=", "+", ",", "-":
            return true
        default:
            return false
        }
    }

    private static func escapedForDoubleQuotes(_ t: String) -> String {
        var out = ""
        for s in t.unicodeScalars {
            if s == "\"" || s == "\\" || s == "$" || s == "`" {
                out.unicodeScalars.append("\\")
            }
            out.unicodeScalars.append(s)
        }
        return out
    }

    /// Recognizes a "\" + newline continuation (or "\" + CR + LF, from a pasted Windows-style
    /// line) starting at `scalars[i]` (`scalars[i] == "\\"` already checked by the caller).
    /// Returns the index just past it, or `nil` if this backslash isn't one.
    private static func continuationEnd(_ scalars: [Unicode.Scalar], at i: Int) -> Int? {
        let count = scalars.count
        guard i + 1 < count else { return nil }
        if scalars[i + 1] == "\n" { return i + 2 }
        if scalars[i + 1] == "\r", i + 2 < count, scalars[i + 2] == "\n" { return i + 3 }
        return nil
    }

    /// Scans a bare `$'...'` (ANSI-C quoting) starting at `scalars[i] == "$"`
    /// (`scalars[i + 1] == "'"` already checked by the caller). Decodes `\n \t \r \\ \' \" \xHH`;
    /// any other backslash sequence keeps its backslash literally, matching the fallback the
    /// double-quote scanner uses for an escape it doesn't recognize. Returns the decoded literal
    /// text and the index just past the closing quote, or `nil` if the quote is never closed.
    private static func scanAnsiCQuoted(_ scalars: [Unicode.Scalar], at i: Int) -> (String, Int)? {
        let count = scalars.count
        var j = i + 2 // past "$'"
        var out = ""
        while j < count {
            let d = scalars[j]
            if d == "'" {
                return (out, j + 1)
            }
            if d == "\\", j + 1 < count {
                let e = scalars[j + 1]
                switch e {
                case "n": out += "\n"; j += 2
                case "t": out += "\t"; j += 2
                case "r": out += "\r"; j += 2
                case "\\", "'", "\"":
                    out.unicodeScalars.append(e)
                    j += 2
                case "x":
                    var k = j + 2
                    var hex = ""
                    while k < count, hex.count < 2, isHexDigit(scalars[k]) {
                        hex.unicodeScalars.append(scalars[k])
                        k += 1
                    }
                    if let value = UInt8(hex, radix: 16) {
                        out.unicodeScalars.append(Unicode.Scalar(value))
                        j = k
                    } else {
                        out.unicodeScalars.append(d) // "\x" with no hex digits: literal backslash
                        j += 1
                    }
                default:
                    out.unicodeScalars.append(d) // unrecognized escape: backslash is literal
                    j += 1
                }
                continue
            }
            out.unicodeScalars.append(d)
            j += 1
        }
        return nil // unterminated
    }

    private static func isHexDigit(_ s: Unicode.Scalar) -> Bool {
        (("0" as Unicode.Scalar) ... ("9" as Unicode.Scalar) ~= s)
            || (("a" as Unicode.Scalar) ... ("f" as Unicode.Scalar) ~= s)
            || (("A" as Unicode.Scalar) ... ("F" as Unicode.Scalar) ~= s)
    }

    /// Reads a `$...` reference at `scalars[i]` (`scalars[i] == "$"` already checked by the
    /// caller): `$(...)`/`${...}` scan to the matching close (counting nested opens so a
    /// parenthesized subcommand or a `${a:-${b}}` default doesn't end early), `$NAME` scans a
    /// C-identifier, and a single `$0`-`$9`, `$?`, `$#`, `$@`, `$*` or `$$` is a special
    /// parameter that never extends past that one character -- `$12` is `$1` followed by the
    /// literal `2`, matching how a shell itself reads positional parameters. Returns `nil` --
    /// meaning "this `$` is not a variable, treat it as literal" -- for anything else (`$`, `$ `,
    /// `$` at end of input), matching what a shell would actually expand.
    private static func scanVariable(_ scalars: [Unicode.Scalar], at i: Int) -> (String, Int)? {
        let n = scalars.count
        var j = i + 1
        guard j < n else { return nil }

        if scalars[j] == "(" || scalars[j] == "{" {
            let open = scalars[j]
            let close: Unicode.Scalar = open == "(" ? ")" : "}"
            var depth = 1
            j += 1
            while j < n, depth > 0 {
                if scalars[j] == open { depth += 1 } else if scalars[j] == close { depth -= 1 }
                j += 1
            }
            return (String(String.UnicodeScalarView(scalars[i..<j])), j)
        }

        if isSpecialParameter(scalars[j]) {
            return (String(String.UnicodeScalarView(scalars[i...j])), j + 1)
        }

        guard isIdentifierStart(scalars[j]) else { return nil }
        j += 1
        while j < n, isIdentifierContinue(scalars[j]) { j += 1 }
        return (String(String.UnicodeScalarView(scalars[i..<j])), j)
    }

    private static func isSpecialParameter(_ s: Unicode.Scalar) -> Bool {
        if ("0" as Unicode.Scalar) ... ("9" as Unicode.Scalar) ~= s { return true }
        switch s {
        case "?", "#", "@", "*", "$":
            return true
        default:
            return false
        }
    }

    private static func isIdentifierStart(_ s: Unicode.Scalar) -> Bool {
        s == "_"
            || (("A" as Unicode.Scalar) ... ("Z" as Unicode.Scalar) ~= s)
            || (("a" as Unicode.Scalar) ... ("z" as Unicode.Scalar) ~= s)
    }

    private static func isIdentifierContinue(_ s: Unicode.Scalar) -> Bool {
        isIdentifierStart(s) || (("0" as Unicode.Scalar) ... ("9" as Unicode.Scalar) ~= s)
    }
}
