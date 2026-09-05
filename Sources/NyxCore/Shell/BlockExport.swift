import Foundation

/// A block as something to paste somewhere else.
public enum BlockExport {
    /// One fence: the command with a `$ ` prefix, then the output. No metadata -- the target is a
    /// chat message or a ticket, and people delete metadata before pasting.
    public static func markdown(command: String, output: String) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompted = trimmedCommand.hasPrefix("$ ") || trimmedCommand.hasPrefix("% ")
            ? trimmedCommand : "$ " + trimmedCommand
        var body = "```\n" + prompted + "\n"
        if !output.isEmpty { body += output + "\n" }
        return body + "```\n"
    }
}

public extension Terminal {
    /// The output rows as plain text, trailing blank lines dropped.
    ///
    /// `rowText` pads every empty cell with a space so a column stays a column (see its doc
    /// comment); a line pasted into a chat message has no columns to preserve, so each row is
    /// right-trimmed first -- the same rule `Terminal.text(in:)` applies to a character selection.
    func outputText(of region: CommandRegion) -> String {
        let rows = region.outputRows
        guard !rows.isEmpty else { return "" }
        var lines = rows.map { row -> String in
            var line = rowText(absoluteRow: row).text
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
