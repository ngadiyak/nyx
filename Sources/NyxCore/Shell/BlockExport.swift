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

    /// The output as the **logical** lines the program printed: a row the terminal wrapped is the
    /// middle of a line and joins with nothing, a row the program ended is a line of its own.
    ///
    /// `outputText` above is the *visual* transcript -- what is on the screen, one string per row --
    /// which is right for pasting into a chat message and wrong for anything that has to read the
    /// output as data. A JSON body is one line however wide the pane is, and splitting it at column
    /// 80 puts a newline inside a string literal: `JSONDocument.parse` refuses control characters in
    /// strings, so the pretty lens degraded to raw for every response longer than one row -- which
    /// is every response anybody actually looks at. Two rules, the same pair `Terminal.text(in:)`
    /// and `commandLine(of:)` already apply: only an unwrapped row has padding to strip, because a
    /// wrapped one is full to its last column by definition.
    func outputLines(of region: CommandRegion) -> [String] {
        let rows = region.outputRows
        guard !rows.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for row in rows {
            var piece = rowText(absoluteRow: row).text
            let wrapped = absoluteRow(row)?.wrapped ?? false
            if !wrapped { while piece.hasSuffix(" ") { piece.removeLast() } }
            current += piece
            if !wrapped {
                lines.append(current)
                current = ""
            }
        }
        // A run that ends on a wrapped row -- output still arriving, or a last row exactly filled --
        // still has a line in hand.
        if !current.isEmpty { lines.append(current) }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}
