import Foundation

/// What a run of text on a row turned out to be.
///
/// One table serves two features, deliberately. Double-clicking a thing and ⌘-clicking a thing
/// should agree about where that thing begins and ends: a path you can open is a path you can
/// select in one gesture, and a terminal where those two disagree feels broken in a way users
/// notice without being able to say why.
public enum TokenKind: Equatable {
    case url
    /// A filesystem path, with the line and column a compiler printed after it, when present.
    case path(line: Int?, column: Int?)
    /// A git object name -- 7 to 40 hex characters standing alone.
    case commitHash
    case ipAddress
    case email
    /// Nothing matched; the word under the pointer by the configured separators.
    case word
}

public struct TextToken: Equatable {
    /// Columns on the row, as a half-open range.
    public let columns: Range<Int>
    public let text: String
    public let kind: TokenKind

    public init(columns: Range<Int>, text: String, kind: TokenKind) {
        self.columns = columns
        self.text = text
        self.kind = kind
    }
}

/// Finds URLs, paths and other structured runs in a line of terminal text.
///
/// Written against a plain `String` and a column mapping rather than against `Row`, so it can be
/// tested on text alone -- and so a wide glyph, which occupies two columns but one character,
/// cannot quietly shift every column to its right.
public enum TextPatterns {
    /// Ordered by priority: the first pattern that matches a run wins. URLs come before paths
    /// because `https://example.com/a/b` is a path as far as a path pattern is concerned.
    private static let patterns: [(NSRegularExpression, (NSTextCheckingResult, String) -> TokenKind)] = {
        func re(_ p: String) -> NSRegularExpression {
            // The patterns are literals written here; a failure is a programming error, not input.
            try! NSRegularExpression(pattern: p, options: [])
        }
        return [
            (re(#"\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s<>"'`\\|{}\^\[\]]+"#), { _, _ in .url }),
            (re(#"\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b"#), { _, _ in .email }),
            (re(#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#), { _, _ in .ipAddress }),
            // A path in any of the shapes that actually turn up in terminal output: absolute or
            // home-relative, explicitly relative, relative with slashes and no leading dot (which
            // is how every compiler prints them), or a bare filename with an extension. The
            // optional `:line:column` suffix is what makes the match jumpable.
            (re(#"(?:(?:~|\.{1,2})?/[^\s:<>"'`|]+|[\w.-]+(?:/[\w.-]+)+|\b[\w.-]+\.[A-Za-z]\w*)(?::\d+){0,2}"#),
             { match, line in
                 let text = (line as NSString).substring(with: match.range)
                 let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                 guard parts.count > 1 else { return .path(line: nil, column: nil) }
                 return .path(line: Int(parts[1]), column: parts.count > 2 ? Int(parts[2]) : nil)
             }),
            (re(#"\b[0-9a-f]{7,40}\b"#), { _, _ in .commitHash }),
        ]
    }()

    /// Every structured token on a line, in column order and never overlapping.
    ///
    /// `columnOf` maps a character offset in `line` to the terminal column it starts at. Callers
    /// working on plain text with no wide characters can pass `nil` for the identity mapping.
    public static func tokens(in line: String, columnOf: [Int]? = nil) -> [TextToken] {
        guard !line.isEmpty else { return [] }
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var claimed: [Range<Int>] = []
        var found: [TextToken] = []

        for (regex, classify) in patterns {
            for match in regex.matches(in: line, options: [], range: whole) {
                let matched = match.range.location..<(match.range.location + match.range.length)
                guard !claimed.contains(where: { $0.overlaps(matched) }) else { continue }
                let kind = classify(match, line)
                let text = TextPatterns.trimmingTrailingPunctuation(ns.substring(with: match.range),
                                                                    kind: kind)
                guard !text.isEmpty else { continue }
                let chars = matched.lowerBound..<(matched.lowerBound + text.count)
                // A "commit hash" that is really a decimal number, or part of a longer word, is
                // noise -- requiring at least one letter keeps `1234567` from being a hash.
                if kind == .commitHash, !text.contains(where: { $0.isLetter }) { continue }
                claimed.append(chars)
                found.append(TextToken(columns: columnRange(chars, columnOf, ns.length),
                                       text: text, kind: kind))
            }
        }
        return found.sorted { $0.columns.lowerBound < $1.columns.lowerBound }
    }

    /// Trailing punctuation belongs to the sentence, not the thing.
    ///
    /// `see https://example.com, then` ends the URL at the comma, and `(https://example.com)` at
    /// the bracket -- but only when that bracket is unbalanced, because a closing paren really can
    /// be part of a URL. Opening a link with a comma glued on is the most familiar version of this
    /// bug, and it is one users hit within a minute.
    static func trimmingTrailingPunctuation(_ text: String, kind: TokenKind) -> String {
        guard kind != .word else { return text }
        var characters = Array(text)
        let alwaysTrailing: Set<Character> = [".", ",", ";", ":", "!", "?", "'", "\"", "`"]
        while let last = characters.last {
            if alwaysTrailing.contains(last) {
                characters.removeLast()
                continue
            }
            if last == ")" || last == "]" || last == "}" {
                let open: Character = last == ")" ? "(" : (last == "]" ? "[" : "{")
                let opens = characters.filter { $0 == open }.count
                let closes = characters.filter { $0 == last }.count
                if closes > opens { characters.removeLast(); continue }
            }
            break
        }
        return String(characters)
    }

    /// The token at a column, or nil when that column is not inside one.
    public static func token(at column: Int, in line: String, columnOf: [Int]? = nil) -> TextToken? {
        tokens(in: line, columnOf: columnOf).first { $0.columns.contains(column) }
    }

    /// The word around a column, by the same separators the selection uses. This is what a
    /// double-click falls back to when nothing structured is under the pointer.
    public static func word(at column: Int, in line: String, separators: Set<Character>,
                            columnOf: [Int]? = nil) -> TextToken? {
        let characters = Array(line)
        let index = characterIndex(forColumn: column, columnOf: columnOf, count: characters.count)
        guard let index, index < characters.count, !isSeparator(characters[index], separators) else { return nil }

        var start = index
        while start > 0 && !isSeparator(characters[start - 1], separators) { start -= 1 }
        var end = index
        while end + 1 < characters.count && !isSeparator(characters[end + 1], separators) { end += 1 }

        return TextToken(columns: columnRange(start..<(end + 1), columnOf, characters.count),
                         text: String(characters[start...end]), kind: .word)
    }

    /// A structured token if there is one, otherwise the plain word -- what a double-click selects.
    public static func selectionToken(at column: Int, in line: String, separators: Set<Character>,
                                      columnOf: [Int]? = nil) -> TextToken? {
        token(at: column, in: line, columnOf: columnOf)
            ?? word(at: column, in: line, separators: separators, columnOf: columnOf)
    }

    // MARK: - Column mapping

    private static func isSeparator(_ c: Character, _ separators: Set<Character>) -> Bool {
        c == " " || separators.contains(c)
    }

    private static func columnRange(_ characters: Range<Int>, _ columnOf: [Int]?, _ count: Int) -> Range<Int> {
        guard let columnOf, !columnOf.isEmpty else { return characters }
        let lower = characters.lowerBound < columnOf.count ? columnOf[characters.lowerBound] : columnOf[columnOf.count - 1] + 1
        let upper = characters.upperBound < columnOf.count ? columnOf[characters.upperBound] : columnOf[columnOf.count - 1] + 1
        return lower..<max(lower + 1, upper)
    }

    private static func characterIndex(forColumn column: Int, columnOf: [Int]?, count: Int) -> Int? {
        guard let columnOf, !columnOf.isEmpty else { return column < count ? column : nil }
        // The last character whose column is at or before the one asked for: a click on the second
        // cell of a wide glyph belongs to that glyph, not to the character after it.
        var answer: Int?
        for (index, start) in columnOf.enumerated() where start <= column { answer = index }
        return answer
    }
}
