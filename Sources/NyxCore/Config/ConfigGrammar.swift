import Foundation

/// The `key = value` grammar shared by the config file (`ConfigParser`) and theme files
/// (`Themes.parse`), factored out so the two parsers can't quietly disagree about what's valid.
enum ConfigGrammar {
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
}
