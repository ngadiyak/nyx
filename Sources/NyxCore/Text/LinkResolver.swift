import Foundation

/// What ⌘-clicking a token should open.
public enum LinkTarget: Equatable {
    /// Handed to the system as-is. Bare URLs, and e-mail addresses turned into `mailto:`.
    case url(String)
    /// A file that exists on disk, absolute, with whatever line and column the token carried.
    case file(path: String, line: Int?, column: Int?)
}

/// Deciding whether a token is a link, and what opening it means.
///
/// The interesting rule is the one about paths: a path is only a link if it is *there*. Terminal
/// output is full of things shaped like paths that are not files -- `a/b` in a diff header,
/// `Config/init` in a log line, half of a Python traceback -- and underlining them all trains a
/// user to distrust the underline. The check needs the filesystem, so it arrives as a closure and
/// this stays a pure function a test can drive against a made-up disk.
public enum LinkResolver {
    public static func target(for token: TextToken, home: String,
                              workingDirectory: () -> String?,
                              fileExists: (String) -> Bool) -> LinkTarget? {
        switch token.kind {
        case .url:
            return .url(token.text)
        case .email:
            // `mailto:` is what makes the system hand it to a mail client rather than refusing it.
            return .url(token.text.hasPrefix("mailto:") ? token.text : "mailto:\(token.text)")
        case .path(let line, let column):
            let bare = strippingPosition(from: token.text, line: line, column: column)
            guard !bare.isEmpty else { return nil }
            guard let resolved = absolutePath(bare, home: home, workingDirectory: workingDirectory) else { return nil }
            guard fileExists(resolved) else { return nil }
            return .file(path: resolved, line: line, column: column)
        case .commitHash, .ipAddress, .word:
            // Real things, and worth selecting on a double-click, but there is nothing to open.
            return nil
        }
    }

    /// `src/main.swift:12:3` is a path plus a position; the path is the part before the colons, and
    /// only as many of them as the token actually reported.
    static func strippingPosition(from text: String, line: Int?, column: Int?) -> String {
        var result = text
        var suffixes = (line == nil ? 0 : 1) + (column == nil ? 0 : 1)
        while suffixes > 0, let colon = result.lastIndex(of: ":") {
            let tail = result[result.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { break }
            result = String(result[result.startIndex..<colon])
            suffixes -= 1
        }
        return result
    }

    /// A path as the filesystem wants it: `~` expanded, a relative path joined to the pane's
    /// working directory, `.` and `..` resolved. nil when a relative path has no directory to be
    /// relative to, which is the honest answer rather than guessing at `$HOME`.
    private static func absolutePath(_ path: String, home: String,
                                     workingDirectory: () -> String?) -> String? {
        if path.hasPrefix("/") { return (path as NSString).standardizingPath }
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return ((home as NSString).appendingPathComponent(String(path.dropFirst(2))) as NSString).standardizingPath
        }
        guard let directory = workingDirectory(), !directory.isEmpty else { return nil }
        return ((directory as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
}

/// Turning the `open-file-command` template into an argument list.
///
/// The template is what a user writes in their config -- `code -g {file}:{line}` -- and it has to
/// survive a path with a space in it and a token that carried no line number. Both of those are
/// one-line rules that are wrong in half the terminals that have this setting, so they are pinned
/// by tests here rather than discovered in the field.
public enum OpenFileCommand {
    /// nil for a template with nothing runnable in it.
    public static func arguments(template: String, path: String, line: Int?, column: Int?) -> [String]? {
        let words = split(template)
        guard !words.isEmpty else { return nil }
        let substituted = words.map { word -> String in
            var text = word
            text = text.replacingOccurrences(of: "{file}", with: path)
            text = text.replacingOccurrences(of: "{line}", with: line.map(String.init) ?? "")
            text = text.replacingOccurrences(of: "{column}", with: column.map(String.init) ?? "")
            return tidy(text, changed: text != word)
        }.filter { !$0.isEmpty }
        return substituted.isEmpty ? nil : substituted
    }

    /// `{file}:{line}` with no line leaves a dangling colon, and `{file}:{line}:{column}` with
    /// neither leaves two. A path is never opened with punctuation glued to it.
    private static func tidy(_ text: String, changed: Bool) -> String {
        guard changed else { return text }
        var result = text
        while result.contains("::") { result = result.replacingOccurrences(of: "::", with: ":") }
        while result.hasSuffix(":") { result.removeLast() }
        return result
    }

    /// Splits on whitespace, honouring single and double quotes so a command or a flag can contain
    /// a space. Quotes are removed; there is no escaping beyond them, which is as much shell as a
    /// setting like this should imitate.
    static func split(_ template: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var hasContent = false
        for character in template {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                hasContent = true
                continue
            }
            if character.isWhitespace {
                if hasContent || !current.isEmpty { words.append(current) }
                current = ""
                hasContent = false
                continue
            }
            current.append(character)
        }
        if hasContent || !current.isEmpty { words.append(current) }
        return words
    }
}
