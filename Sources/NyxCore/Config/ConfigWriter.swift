import Foundation

/// Writes a single setting back into a config file's text.
///
/// The settings window edits the file rather than keeping its own copy of the configuration. That
/// keeps one source of truth: the file watcher already reloads on save, so a change made in the
/// window and a change made in an editor travel exactly the same path, and the two can never show
/// different values.
///
/// Which means this has to be careful with text a human wrote. It preserves comments, blank lines,
/// ordering, and any line it does not recognise -- editing `font-size` must not reformat the file
/// or drop the note somebody left above it.
public enum ConfigWriter {
    /// Sets `key` to `value`, returning the new file text.
    ///
    /// In order of preference: replace the value on the last active line for that key (the last is
    /// the one in force, since `ConfigParser` lets a later line win); otherwise uncomment the
    /// commented default line, so the setting stays where the shipped file put it, under its own
    /// heading; otherwise append it at the end.
    public static func setting(_ key: String, to value: String, in text: String) -> String {
        var lines = ConfigGrammar.lines(text).map(String.init)

        if let index = lastActiveLine(for: key, in: lines) {
            lines[index] = replacingValue(in: lines[index], with: value)
            return lines.joined(separator: "\n")
        }
        if let index = commentedLine(for: key, in: lines) {
            lines[index] = replacingValue(in: uncommented(lines[index]), with: value)
            return lines.joined(separator: "\n")
        }
        if lines.last?.isEmpty == false { lines.append("") }
        lines.append("\(key) = \(value)")
        return lines.joined(separator: "\n")
    }

    /// Applies several settings in one pass, so a window that saves five fields writes the file
    /// once rather than five times -- five writes would be five reload notifications.
    public static func settings(_ values: [(key: String, value: String)], in text: String) -> String {
        values.reduce(text) { setting($1.key, to: $1.value, in: $0) }
    }

    // MARK: - Finding the line

    /// The last uncommented line setting `key`. Last, not first: a file with the key twice is in
    /// the state `ConfigParser` reads as the later one winning, and editing the earlier one would
    /// appear to do nothing.
    private static func lastActiveLine(for key: String, in lines: [String]) -> Int? {
        lines.indices.reversed().first { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("#") && self.key(of: line) == key
        }
    }

    /// A commented-out line for the key, as the shipped default file has for every setting.
    private static func commentedLine(for key: String, in lines: [String]) -> Int? {
        lines.indices.first { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#") else { return false }
            return self.key(of: uncommented(line).trimmingCharacters(in: .whitespaces)) == key
        }
    }

    private static func key(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    // MARK: - Rewriting one line

    /// Drops one leading `#` and a single space after it, leaving any deeper commenting alone --
    /// `## font-size = 13` is somebody's deliberately disabled line, not the default line.
    private static func uncommented(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        var rest = Substring(line.dropFirst(indent.count))
        guard rest.hasPrefix("#") else { return line }
        rest = rest.dropFirst()
        if rest.hasPrefix(" ") { rest = rest.dropFirst() }
        return String(indent) + String(rest)
    }

    /// Keeps the indentation and the spacing around `=` that the line already had, and keeps any
    /// trailing comment on it.
    private static func replacingValue(in line: String, with value: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return line }
        let head = line[line.startIndex...eq]
        let tail = line[line.index(after: eq)...]

        // A `#` after the value is a trailing comment and belongs to the human, so it stays.
        let comment = tail.firstIndex(of: "#").map { String(tail[$0...]) } ?? ""
        let spacer = tail.hasPrefix(" ") ? " " : ""
        return String(head) + spacer + value + (comment.isEmpty ? "" : " " + comment)
    }
}
