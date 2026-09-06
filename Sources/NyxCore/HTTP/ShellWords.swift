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

    public init(pieces: [Piece]) {
        self.pieces = pieces
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

            // Outside quotes, "\" + newline vanishes completely before anything else looks at
            // it: checked here, ahead of the word-boundary logic below, so it never reads as
            // whitespace (which would flush a word that hasn't started) or as content (which
            // would start one) -- either way produces a phantom empty word around it.
            if c == "\\", i + 1 < n, scalars[i + 1] == "\n" {
                i += 2
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
                    if d == "\\", i + 1 < n {
                        let e = scalars[i + 1]
                        switch e {
                        case "\"", "\\", "$":
                            text.unicodeScalars.append(e)
                            i += 2
                        case "\n":
                            i += 2 // backslash-newline vanishes even inside double quotes
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
    /// double-quoted (with `\"`, `\\`, `\$` escaped) when it either contains a `'` or mixes in a
    /// variable that must stay live.
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
        if !t.isEmpty, t.unicodeScalars.allSatisfy(isBareSafe) {
            return t
        }
        if t.contains("'") {
            return "\"" + escapedForDoubleQuotes(t) + "\""
        }
        return "'" + t + "'"
    }

    /// Characters a curl argument can carry unquoted without a shell reinterpreting them. Beyond
    /// the letter/digit/`_./:@%=+,-` set, `?` is included too: query strings like
    /// `.../v1?x=1` are the common case and don't need protecting for a single word with no
    /// spaces or glob-sensitive shell state around it.
    private static func isBareSafe(_ s: Unicode.Scalar) -> Bool {
        if ("A" as Unicode.Scalar) ... ("Z" as Unicode.Scalar) ~= s { return true }
        if ("a" as Unicode.Scalar) ... ("z" as Unicode.Scalar) ~= s { return true }
        if ("0" as Unicode.Scalar) ... ("9" as Unicode.Scalar) ~= s { return true }
        switch s {
        case "_", ".", "/", ":", "@", "%", "=", "+", ",", "-", "?":
            return true
        default:
            return false
        }
    }

    private static func escapedForDoubleQuotes(_ t: String) -> String {
        var out = ""
        for s in t.unicodeScalars {
            if s == "\"" || s == "\\" || s == "$" {
                out.unicodeScalars.append("\\")
            }
            out.unicodeScalars.append(s)
        }
        return out
    }

    /// Reads a `$...` reference at `scalars[i]` (`scalars[i] == "$"` already checked by the
    /// caller): `$(...)`/`${...}` scan to the matching close (counting nested opens so a
    /// parenthesized subcommand or a `${a:-${b}}` default doesn't end early), `$NAME` scans a
    /// C-identifier. Returns `nil` -- meaning "this `$` is not a variable, treat it as literal" --
    /// for anything else (`$`, `$ `, `$5`, `$` at end of input), matching what a shell would
    /// actually expand.
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

        guard isIdentifierStart(scalars[j]) else { return nil }
        j += 1
        while j < n, isIdentifierContinue(scalars[j]) { j += 1 }
        return (String(String.UnicodeScalarView(scalars[i..<j])), j)
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
