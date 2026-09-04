import Foundation

/// What a quick action does when you press it.
public enum QuickActionKind: String, Equatable, CaseIterable {
    /// Type the command into the focused pane and run it, as though you had typed it yourself.
    /// The shell sees it, so it lands in your history and can be edited or re-run.
    case send
    /// Open a new tab and run it there, leaving the pane you were in alone.
    case run
    /// Start it in the background and keep it running until you press again. This is the one for
    /// `caffeinate -d`: something that has to stay alive but that you never want to look at, and
    /// which today costs a whole tab to babysit.
    case toggle
}

/// A user-defined button: a name, what it does, and the command line.
///
/// Configured as `quick = <name> | <kind> | <command>`. The kind may be left out, in which case the
/// command is typed into the current pane -- the common case, and the one worth the least typing.
public struct QuickAction: Equatable {
    public let name: String
    public let kind: QuickActionKind
    public let command: String

    public init(name: String, kind: QuickActionKind, command: String) {
        self.name = name
        self.kind = kind
        self.command = command
    }

    /// Parses one `quick` line's value, or nil when it is not usable.
    ///
    /// Splitting stops after two separators, so a command may contain pipes -- `Logs | run | tail -f
    /// x | grep err` is a perfectly ordinary thing to want, and a naive split would cut it in half.
    public static func parse(_ value: String) -> QuickAction? {
        let fields = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        switch fields.count {
        case 2:
            // `name | command`, with the kind left out.
            guard !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return QuickAction(name: fields[0], kind: .send, command: fields[1])
        case 3:
            guard !fields[0].isEmpty, !fields[2].isEmpty,
                  let kind = QuickActionKind(rawValue: fields[1].lowercased()) else { return nil }
            return QuickAction(name: fields[0], kind: kind, command: fields[2])
        default:
            return nil
        }
    }

    /// The bytes to write to a pane's shell for a `send` action: the command and a newline, so it
    /// runs rather than sitting on the prompt waiting to be noticed.
    public var bytesToSend: [UInt8] {
        Array((command + "\n").utf8)
    }

    /// A `toggle` runs detached rather than through a shell, so the command has to be split into an
    /// executable and its arguments. Honours single and double quotes, which is as much shell
    /// grammar as is reasonable here -- anything needing more belongs in a script.
    public var argv: [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var any = false

        for character in command {
            if let q = quote {
                if character == q { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
                any = true            // `""` is an argument, even though it adds no characters
            case " ", "\t":
                if !current.isEmpty || any { out.append(current); current = ""; any = false }
            default:
                current.append(character)
            }
        }
        if !current.isEmpty || any { out.append(current) }
        return out
    }
}
