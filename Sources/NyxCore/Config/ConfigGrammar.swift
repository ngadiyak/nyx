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
}
