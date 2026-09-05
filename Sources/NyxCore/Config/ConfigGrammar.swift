import Foundation

/// The `key = value` grammar shared by the config file (`ConfigParser`) and theme files
/// (`Themes.parse`), factored out so the two parsers can't quietly disagree about what's valid.
enum ConfigGrammar {
    /// Keys whose value is not comment-stripped on parse, because the value may legitimately
    /// contain `#`: a command line (`quick`), a template (`open-file-command`), an opaque secret
    /// (`remote-relay-token`). `ConfigWriter` reads this too -- a `#` inside the *old* value of one
    /// of these keys is not a trailing human comment to preserve, and treating it as one is what let
    /// writing `xyz#456` over `remote-relay-token = abc#123` come back as `xyz#456 #123`.
    static let commentExemptKeys: Set<String> = ["quick", "open-file-command", "remote-relay-token"]
    /// Splits text into logical lines. Recognises `\n`, `\r\n` (a single grapheme cluster in
    /// Swift, and therefore invisible to a plain `split(separator: "\n")`) and a lone `\r` as line
    /// terminators, so a CRLF or classic-Mac file parses identically to the same file saved with
    /// LF endings instead of being swallowed whole as the value of the first key.
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
    }

    /// Parses one `palette` value of the form `index=colour`. Returns nil if malformed, or if the
    /// index falls outside the valid `0..<256` palette range -- matching `Palette.colors`, which
    /// always has exactly 256 entries.
    static func paletteEntry(_ value: some StringProtocol) -> (index: Int, rgb: RGB)? {
        let parts = value.split(separator: "=", maxSplits: 1)
        guard parts.count == 2,
              let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              (0..<256).contains(idx),
              let rgb = RGB(spec: parts[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (idx, rgb)
    }

    /// The value on a `key = value` line, with any trailing comment removed.
    ///
    /// A comment is a `#` with whitespace in front of it. That qualifier is load-bearing: colours
    /// are written `palette = 1=#ff0000`, and a rule that stripped from the first `#` would turn
    /// every palette line into an empty value.
    static func value(after text: Substring, stripComments: Bool = true) -> String {
        guard stripComments else { return text.trimmingCharacters(in: .whitespaces) }
        var previousWasSpace = true   // a `#` immediately after the `=` still starts a comment
        for index in text.indices {
            if text[index] == "#" && previousWasSpace {
                return text[text.startIndex..<index].trimmingCharacters(in: .whitespaces)
            }
            previousWasSpace = text[index] == " " || text[index] == "\t"
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
