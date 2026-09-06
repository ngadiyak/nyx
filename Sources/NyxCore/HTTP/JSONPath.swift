import Foundation

/// The slice of jq's path language the response box understands, and what it does with a value.
///
/// Deliberately a *subset*. The field above a response is one line wide and the person typing in it
/// wants `.items[] | .id`, not a program; implementing more of jq badly would mean a filtered list
/// with no way to tell it was filtered wrongly. Anything outside the subset is refused at parse
/// time, and the box says `unsupportedMessage`, with the `Run with jq` button beside it.
///
/// Where the two differ inside the subset it is said at the member that differs (`keys` does not
/// sort). Everything else follows jq: iteration fans a value out into several, a missing key is
/// `null` rather than an error, slices clamp, negative indices count from the end.
public enum JSONPath {
    public indirect enum Expr: Equatable {
        /// `.` -- the value itself.
        case identity
        /// `.name` or `["name with spaces"]`.
        case key(String)
        /// `[3]`, `[-1]`.
        case index(Int)
        /// `[1:3]`, `[:3]`, `[2:]`. Either end may be negative.
        case slice(Int?, Int?)
        /// `[]`, `[]?`.
        case iterate(optional: Bool)
        case keys
        case length
        /// `..name` -- every value under a key of that name, at any depth.
        case recurse(String)
        /// One `|`. Two would be a program.
        case pipe(Expr, Expr)
        /// `.a.b[0]` -- steps applied left to right.
        case chain([Expr])
    }

    /// What the box says when the text is jq but not *this* jq.
    ///
    /// The sentence does not name the way out, because the button that *is* the way out sits
    /// immediately beside it: "Not supported here — Run with jq" next to a button labelled `Run
    /// with jq` said the same three words twice and read as an instruction to press the sentence.
    public static let unsupportedMessage = "Not supported here."

    // MARK: - Parsing

    /// Reads a path, or nil when it is outside the subset.
    ///
    /// Nil is not an error message: the caller shows `unsupportedMessage`. Refusing is the whole
    /// design -- a half-understood `select(.a > 2)` that quietly became `.a` would be worse than
    /// no answer at all.
    public static func parse(_ s: String) -> Expr? {
        let text = s.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let stages = splitOnPipe(text)
        switch stages.count {
        case 1: return stage(stages[0])
        case 2:
            guard let first = stage(stages[0]), let second = stage(stages[1]) else { return nil }
            return .pipe(first, second)
        default: return nil    // two pipes is a program, not a path
        }
    }

    /// Splits on a top-level `|`. A `|` inside a quoted key (`.["a|b"]`) is part of the key.
    private static func splitOnPipe(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                current.append(character)
                escaped = true
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "|" where !inQuotes:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    private static func stage(_ raw: String) -> Expr? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text == "keys" { return .keys }
        if text == "length" { return .length }
        if text.hasPrefix("..") {
            let name = String(text.dropFirst(2))
            guard isIdentifier(name) else { return nil }
            return .recurse(name)
        }
        guard text.hasPrefix(".") else { return nil }

        let characters = Array(text)
        var at = 0
        var steps: [Expr] = []
        while at < characters.count {
            switch characters[at] {
            case ".":
                at += 1
                if at == characters.count {
                    // A trailing `.` is only a path when it is the whole path.
                    guard steps.isEmpty else { return nil }
                    return .identity
                }
                if characters[at] == "[" { continue }
                var name = ""
                while at < characters.count, isIdentifierCharacter(characters[at], first: name.isEmpty) {
                    name.append(characters[at])
                    at += 1
                }
                guard !name.isEmpty else { return nil }
                steps.append(.key(name))
            case "[":
                guard let (step, next) = bracket(characters, from: at) else { return nil }
                steps.append(step)
                at = next
            default:
                return nil
            }
        }
        if steps.isEmpty { return .identity }
        return steps.count == 1 ? steps[0] : .chain(steps)
    }

    /// One `[...]`, plus the `?` a `[]` may carry. Returns the step and the offset after it.
    private static func bracket(_ characters: [Character], from start: Int) -> (Expr, Int)? {
        var at = start + 1
        var inner = ""
        var inQuotes = false
        var escaped = false
        var closed = false
        while at < characters.count {
            let character = characters[at]
            at += 1
            if escaped {
                inner.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                inner.append(character)
                escaped = true
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                inner.append(character)
                continue
            }
            if character == "]", !inQuotes {
                closed = true
                break
            }
            inner.append(character)
        }
        guard closed else { return nil }

        if inner.isEmpty {
            if at < characters.count, characters[at] == "?" { return (.iterate(optional: true), at + 1) }
            return (.iterate(optional: false), at)
        }
        if inner.hasPrefix("\""), inner.hasSuffix("\""), inner.count >= 2 {
            return (.key(unquoted(inner)), at)
        }
        if let colon = inner.firstIndex(of: ":") {
            let low = String(inner[inner.startIndex ..< colon])
            let high = String(inner[inner.index(after: colon)...])
            guard let from = bound(low), let to = bound(high) else { return nil }
            return (.slice(from, to), at)
        }
        guard let value = Int(inner) else { return nil }
        return (.index(value), at)
    }

    /// One end of a slice: a number, or nothing at all for "from the start" / "to the end".
    private static func bound(_ text: String) -> Int?? {
        if text.isEmpty { return Int?.none }
        guard let value = Int(text) else { return nil }
        return value
    }

    private static func unquoted(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text.dropFirst().dropLast() {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for (offset, character) in text.enumerated()
        where !isIdentifierCharacter(character, first: offset == 0) {
            return false
        }
        return true
    }

    private static func isIdentifierCharacter(_ character: Character, first: Bool) -> Bool {
        if character == "_" { return true }
        if character.isLetter { return true }
        return !first && character.isNumber
    }

    // MARK: - Evaluating

    /// Applies `expr` to `value`. Several results is normal -- that is what `[]` is for -- and no
    /// results is the honest answer to a path that matched nothing.
    public static func evaluate(_ expr: Expr, on value: JSONValue) -> [JSONValue] {
        switch expr {
        case .identity:
            return [value]
        case .key(let name):
            return [member(name, of: value)]
        case .index(let position):
            return [element(position, of: value)]
        case .slice(let from, let to):
            return [sliced(from, to, of: value)]
        case .iterate:
            // jq errors on `.[]` over a scalar and says nothing on `.[]?`. There is no error
            // channel here -- the box shows results or "no match" -- so both are nothing, and `?`
            // is accepted so a path pasted from a shell still parses.
            switch value {
            case .array(let items): return items
            case .object(let members): return members.map(\.value)
            default: return []
            }
        case .keys:
            switch value {
            // In the order the document has them. jq sorts; this does not, because the reader is
            // asking about *this* response, where the order the server chose is information --
            // and a sorted list would not line up with the body beside it.
            case .object(let members): return [.array(members.map { .string($0.key) })]
            case .array(let items):
                return [.array((0 ..< items.count).map { .number(String($0)) })]
            default: return []
            }
        case .length:
            switch value {
            // Codepoints, which is what jq counts -- and what the API's own documentation counts
            // when it says a field is at most 255 long. Swift's `count` is graphemes and would
            // answer 1 for `e` plus a combining acute, which is a different question.
            case .string(let text): return [.number(String(text.unicodeScalars.count))]
            case .array(let items): return [.number(String(items.count))]
            case .object(let members): return [.number(String(members.count))]
            case .null: return [.number("0")]
            // jq's `length` on a number is its magnitude, which is not a question anybody asks of
            // a response body; on a boolean it is an error. Neither earns an answer here.
            case .number, .bool: return []
            }
        case .recurse(let name):
            var out: [JSONValue] = []
            collect(name, in: value, depth: 0, into: &out)
            return out
        case .pipe(let first, let second):
            return evaluate(first, on: value).flatMap { evaluate(second, on: $0) }
        case .chain(let steps):
            return steps.reduce([value]) { values, step in
                values.flatMap { evaluate(step, on: $0) }
            }
        }
    }

    /// jq's rule: a key that is not there is `null`, not an error and not nothing -- so `.a.b` on a
    /// response missing `a` shows `null` rather than an empty box the reader cannot interpret.
    ///
    /// The **last** member of that name, when a body repeats a key. The tree keeps every one of
    /// them because printing a body is showing what arrived, but a path through it has to answer
    /// the way jq and every dictionary-building reader answers, which is the last.
    private static func member(_ name: String, of value: JSONValue) -> JSONValue {
        guard case .object(let members) = value else { return .null }
        return members.last { $0.key == name }?.value ?? .null
    }

    private static func element(_ position: Int, of value: JSONValue) -> JSONValue {
        guard case .array(let items) = value else { return .null }
        let offset = position < 0 ? items.count + position : position
        guard offset >= 0, offset < items.count else { return .null }
        return items[offset]
    }

    /// Both ends clamp, because `[0:100]` is how a person asks for "the first hundred, however many
    /// there are", and an end below its start is an empty array rather than a crash.
    private static func sliced(_ from: Int?, _ to: Int?, of value: JSONValue) -> JSONValue {
        guard case .array(let items) = value else { return .null }
        func resolve(_ bound: Int?, default fallback: Int) -> Int {
            guard let bound else { return fallback }
            let offset = bound < 0 ? items.count + bound : bound
            return min(max(offset, 0), items.count)
        }
        let start = resolve(from, default: 0)
        let end = resolve(to, default: items.count)
        guard start < end else { return .array([]) }
        return .array(Array(items[start ..< end]))
    }

    /// Document order: each member is offered, then descended into. A match is descended into as
    /// well, so `..name` under a `name` that is itself an object still finds what is inside it.
    ///
    /// Stops where the printer stops. This one *is* recursive -- a tree walk with nothing to say
    /// per level reads far better that way -- so it needs the same guard the reader has, or a
    /// hand-built tree deeper than 512 would take the stack out from under whatever queue a lens
    /// is being rendered on.
    private static func collect(_ name: String, in value: JSONValue, depth: Int,
                                into out: inout [JSONValue]) {
        guard depth <= JSONDocument.maximumDepth else { return }
        switch value {
        case .object(let members):
            for member in members {
                if member.key == name { out.append(member.value) }
                collect(name, in: member.value, depth: depth + 1, into: &out)
            }
        case .array(let items):
            for item in items { collect(name, in: item, depth: depth + 1, into: &out) }
        default:
            break
        }
    }
}
