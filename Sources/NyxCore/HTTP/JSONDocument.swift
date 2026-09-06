import Foundation

/// A JSON document as a tree, kept in the shape the server actually sent it.
///
/// Two things `JSONSerialization` cannot preserve, and both of them are visible to anyone reading a
/// response: the **order** its object keys were written in (a bridged dictionary promises nothing,
/// so `id` would drift to the middle of the object between one run and the next) and the **spelling**
/// of its numbers -- `1.50` re-rendered as `1.5`, an id past 2^53 quietly rounded. Numbers are
/// therefore carried as the text they arrived as and never converted; nothing in the workbench does
/// arithmetic on them.
public indirect enum JSONValue: Equatable {
    /// One key and its value. A struct rather than the `(key:value:)` tuple this began as: an array
    /// of tuples is not `Equatable`, and the whole response side compares values -- a diff between
    /// two polls, a test asserting a parse.
    public struct Member: Equatable {
        public let key: String
        public let value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    /// Exactly as written: `1.50`, `1e9`, `-0`. See the note on the type.
    case number(String)
    case bool(Bool)
    case null
}

/// Where a value sits in a document: the steps from the root to it.
///
/// This is what a fold is remembered by. Not a line number, because the line a node is on moves as
/// soon as anything above it folds; not an identity, because the tree is rebuilt from scratch on
/// every poll of a watched request and the folds have to survive that.
public struct NodePath: Hashable {
    public enum Step: Hashable {
        case key(String)
        case index(Int)
    }

    public let steps: [Step]

    public init(_ steps: [Step] = []) {
        self.steps = steps
    }

    public func appending(_ step: Step) -> NodePath {
        NodePath(steps + [step])
    }
}

/// How one span of a rendered line is coloured. The view maps these to theme colours; nothing here
/// knows what a colour is.
///
/// `header`, `added`, `removed` and `match` belong to the lenses that read these lines -- the
/// header lens, the watch diff and the find field. They are here rather than in three private enums
/// because a line is rendered by one function whatever produced it.
public enum LensStyle: Equatable {
    case key
    case string
    case number
    case literal
    case header
    case added
    case removed
    case dim
    case match
}

/// Reading a JSON body and printing it back as lines a person can fold.
public enum JSONDocument {
    /// Deeper than this and the answer is "not something to show", not a stack overflow.
    ///
    /// Both the reader and the printer recurse, and both run on the main thread with a response in
    /// hand that arrived from somewhere else entirely. 512 is far past any API's real nesting and
    /// far short of the stack a background thread gets.
    public static let maximumDepth = 512

    /// Reads `text` as JSON, or nil when it is not JSON.
    ///
    /// Its own reader rather than `JSONSerialization` because of what the tree has to keep -- see
    /// `JSONValue`. Strict apart from two things a real response arrives with: a UTF-8 byte-order
    /// mark (Windows services write one) and whitespace at either end (every shell adds a newline).
    /// Trailing anything else is a refusal: a body that is JSON *and then a log line* is not JSON,
    /// and pretty-printing the first half of it would hide the second half entirely.
    public static func parse(_ text: String) -> JSONValue? {
        var reader = Reader(Array(text.utf8))
        reader.skipByteOrderMark()
        reader.skipWhitespace()
        guard let value = reader.value(depth: 1) else { return nil }
        reader.skipWhitespace()
        guard reader.atEnd else { return nil }
        return value
    }

    // MARK: - Printing

    /// One rendered line of the document.
    ///
    /// `spans` are Character offsets into `text`, not byte offsets: the view lays a line out in
    /// characters, so a key with an emoji in it would otherwise send every highlight after it
    /// sideways.
    public struct PrettyLine: Equatable {
        /// One coloured run of the line. A struct for the reason `Member` is one: an array of
        /// tuples is not `Equatable`, and these lines are compared.
        public struct Span: Equatable {
            public let range: Range<Int>
            public let style: LensStyle

            public init(range: Range<Int>, style: LensStyle) {
                self.range = range
                self.style = style
            }
        }

        /// The line with its indent already in it, so the view draws strings and nothing else.
        public let text: String
        public let depth: Int
        public let spans: [Span]
        /// Set on the opening line of a **non-empty** object or array: the line that can be folded,
        /// and the key the fold is remembered by. Nil everywhere else, including on `{}` -- there
        /// is nothing behind an empty container to hide.
        public let node: NodePath?
        /// Keys or items, for the placeholder a fold leaves behind. Carried on the opening line so
        /// folding does not have to walk the tree a second time to count.
        public let childCount: Int

        public init(text: String, depth: Int, spans: [Span], node: NodePath?, childCount: Int) {
            self.text = text
            self.depth = depth
            self.spans = spans
            self.node = node
            self.childCount = childCount
        }
    }

    public static func pretty(_ value: JSONValue) -> [PrettyLine] {
        pretty(value, folded: [])
    }

    /// The document as lines, with every node in `folded` collapsed to one line that says what is
    /// behind it (`"results": ▸ […] 40 items`).
    ///
    /// A path in `folded` that names a scalar, an empty container or nothing at all is ignored
    /// rather than refused: folds outlive the document they were made on -- a watched request
    /// re-renders on every poll -- and a key that has gone away must not blank the view.
    public static func pretty(_ value: JSONValue, folded: Set<NodePath>) -> [PrettyLine] {
        var lines: [PrettyLine] = []
        emit(value, key: nil, parent: NodePath([]), step: nil, depth: 0, comma: false,
             folded: folded, into: &lines)
        return lines
    }

    /// One value, as one line or as a block of them.
    ///
    /// Written flat -- no nested closures over mutable state, no `String(repeating:)` per line, and
    /// the value's own `NodePath` built only when it turns out to be a foldable container -- because
    /// this runs over every value of a body that can be megabytes. The version that read more
    /// prettily took two and a half times as long on the 2 MB body in `JSONDocumentTests`, which is
    /// a visible stall on the frame that shows the response.
    private static func emit(_ value: JSONValue, key: String?, parent: NodePath,
                             step: NodePath.Step?, depth: Int, comma: Bool,
                             folded: Set<NodePath>, into lines: inout [PrettyLine]) {
        guard depth <= maximumDepth else { return }
        let indent = Indents.of(depth)
        var head = ""
        head.reserveCapacity(64)
        head += indent
        var keySpan: PrettyLine.Span?
        if let key {
            let text = escaped(key)
            keySpan = PrettyLine.Span(range: depth * 2 ..< depth * 2 + text.count, style: .key)
            head += text
            head += ": "
        }
        let headCount = depth * 2 + (keySpan.map { $0.range.count + 2 } ?? 0)
        let tail = comma ? "," : ""

        var count = 0
        var isObject = true
        var open = "{"
        var close = "}"
        var token: String?
        var style = LensStyle.literal
        switch value {
        case .object(let members): count = members.count
        case .array(let items):
            count = items.count
            isObject = false
            open = "["
            close = "]"
        case .string(let text):
            token = escaped(text)
            style = .string
        case .number(let text):
            token = text
            style = .number
        case .bool(let flag): token = flag ? "true" : "false"
        case .null: token = "null"
        }

        if let token {
            var spans: [PrettyLine.Span] = []
            spans.reserveCapacity(2)
            if let keySpan { spans.append(keySpan) }
            spans.append(PrettyLine.Span(range: headCount ..< headCount + token.count,
                                         style: style))
            head += token
            head += tail
            lines.append(PrettyLine(text: head, depth: depth, spans: spans, node: nil,
                                    childCount: 0))
            return
        }

        // `"x": {}` on one line, with no span of its own: an empty container is punctuation, and it
        // is not a fold point either -- there is nothing behind it to hide.
        guard count > 0 else {
            head += open
            head += close
            head += tail
            lines.append(PrettyLine(text: head, depth: depth, spans: keySpan.map { [$0] } ?? [],
                                    node: nil, childCount: 0))
            return
        }

        let path = step.map { parent.appending($0) } ?? parent
        if !folded.isEmpty, folded.contains(path) {
            let placeholder = placeholder(isObject: isObject, count: count)
            var spans = keySpan.map { [$0] } ?? []
            spans.append(PrettyLine.Span(range: headCount ..< headCount + placeholder.count,
                                         style: .dim))
            lines.append(PrettyLine(text: head + placeholder + tail, depth: depth, spans: spans,
                                    node: path, childCount: count))
            return
        }

        head += open
        lines.append(PrettyLine(text: head, depth: depth, spans: keySpan.map { [$0] } ?? [],
                                node: path, childCount: count))
        switch value {
        case .object(let members):
            for (offset, member) in members.enumerated() {
                emit(member.value, key: member.key, parent: path, step: .key(member.key),
                     depth: depth + 1, comma: offset < count - 1, folded: folded, into: &lines)
            }
        case .array(let items):
            for (offset, item) in items.enumerated() {
                emit(item, key: nil, parent: path, step: .index(offset), depth: depth + 1,
                     comma: offset < count - 1, folded: folded, into: &lines)
            }
        default:
            break
        }
        lines.append(PrettyLine(text: indent + close + tail, depth: depth, spans: [], node: nil,
                                childCount: 0))
    }

    /// The indents, made once. A `String(repeating:)` per line is an allocation per line, and this
    /// prints a line per value of a response body.
    private enum Indents {
        static let cached: [String] = (0...64).map { String(repeating: " ", count: $0 * 2) }

        static func of(_ depth: Int) -> String {
            depth < cached.count ? cached[depth] : String(repeating: " ", count: depth * 2)
        }
    }

    /// What a folded container leaves on the line. The count is the point of it: a reader who
    /// folded `results` has to be able to tell it from `errors` without unfolding either.
    private static func placeholder(isObject: Bool, count: Int) -> String {
        let noun = isObject ? (count == 1 ? "key" : "keys") : (count == 1 ? "item" : "items")
        return "\u{25B8} \(isObject ? "{…}" : "[…]") \(count) \(noun)"
    }

    /// A string as JSON writes it, quotes included.
    ///
    /// Everything below U+0020 goes back out escaped, and so do `"` and `\`. A value with a real
    /// newline in it would otherwise become two lines of a document whose *lines are its fold
    /// points* -- the view would then be folding half a string.
    static func escaped(_ text: String) -> String {
        // Over the UTF-8 bytes: a continuation byte is never below 0x20 and never a quote, so this
        // asks the same question as a scan over scalars and is a great deal cheaper -- and it is
        // asked once per key and per string value of the whole body.
        let needsWork = text.utf8.contains { $0 == 0x22 || $0 == 0x5C || $0 < 0x20 }
        guard needsWork else { return "\"" + text + "\"" }
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: - The reader

    /// A recursive-descent reader over the UTF-8 bytes.
    ///
    /// Bytes rather than `Character`s because this runs on bodies of a few megabytes: grapheme
    /// breaking every byte of a 2 MB response to find a comma costs more than the whole render.
    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipByteOrderMark() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
        }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth <= JSONDocument.maximumDepth, let byte = current else { return nil }
            switch byte {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            default: return number()
            }
        }

        mutating func literal(_ word: String) -> Bool {
            let wanted = Array(word.utf8)
            guard index + wanted.count <= bytes.count else { return false }
            for (offset, byte) in wanted.enumerated() where bytes[index + offset] != byte {
                return false
            }
            index += wanted.count
            return true
        }

        mutating func object(depth: Int) -> JSONValue? {
            index += 1
            var members: [JSONValue.Member] = []
            skipWhitespace()
            if current == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { return nil }
                index += 1
                skipWhitespace()
                guard let value = value(depth: depth + 1) else { return nil }
                members.append(JSONValue.Member(key: key, value: value))
                skipWhitespace()
                if current == UInt8(ascii: ",") { index += 1; continue }
                if current == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        mutating func array(depth: Int) -> JSONValue? {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                guard let value = value(depth: depth + 1) else { return nil }
                items.append(value)
                skipWhitespace()
                if current == UInt8(ascii: ",") { index += 1; continue }
                if current == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        /// The common case -- a string with no escape in it -- is one `String(decoding:)` over the
        /// bytes between the quotes. Only a string that actually carries a `\` is rebuilt scalar by
        /// scalar.
        mutating func string() -> String? {
            index += 1
            let start = index
            while let byte = current {
                if byte == UInt8(ascii: "\"") {
                    let text = String(decoding: bytes[start ..< index], as: UTF8.self)
                    index += 1
                    return text
                }
                if byte == UInt8(ascii: "\\") { return escapedString(from: start) }
                if byte < 0x20 { return nil }
                index += 1
            }
            return nil
        }

        mutating func escapedString(from start: Int) -> String? {
            var out = String(decoding: bytes[start ..< index], as: UTF8.self).unicodeScalars
            var literalStart = index
            func flush() {
                if literalStart < index {
                    out.append(contentsOf: String(decoding: bytes[literalStart ..< index],
                                                  as: UTF8.self).unicodeScalars)
                }
            }
            while let byte = current {
                if byte == UInt8(ascii: "\"") {
                    flush()
                    index += 1
                    return String(out)
                }
                if byte < 0x20 { return nil }
                guard byte == UInt8(ascii: "\\") else { index += 1; continue }
                flush()
                index += 1
                guard let escape = current else { return nil }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append("\"")
                case UInt8(ascii: "\\"): out.append("\\")
                case UInt8(ascii: "/"): out.append("/")
                case UInt8(ascii: "b"): out.append(Unicode.Scalar(0x08))
                case UInt8(ascii: "f"): out.append(Unicode.Scalar(0x0C))
                case UInt8(ascii: "n"): out.append("\n")
                case UInt8(ascii: "r"): out.append("\r")
                case UInt8(ascii: "t"): out.append("\t")
                case UInt8(ascii: "u"):
                    guard let scalar = unicodeEscape() else { return nil }
                    out.append(scalar)
                default: return nil
                }
                literalStart = index
            }
            return nil
        }

        /// `\uXXXX`, and the surrogate pair a character above the BMP is written as -- an emoji in
        /// a key or a value is not exotic, it is what half the APIs in the world put in a `name`.
        mutating func unicodeEscape() -> Unicode.Scalar? {
            guard let first = hex4() else { return nil }
            if first >= 0xD800, first <= 0xDBFF {
                guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                      bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                index += 2
                guard let second = hex4(), second >= 0xDC00, second <= 0xDFFF else { return nil }
                let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                return Unicode.Scalar(value)
            }
            return Unicode.Scalar(first)
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for byte in bytes[index ..< index + 4] {
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - 0x30)
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - 0x61) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - 0x41) + 10
                default: return nil
                }
                value = value << 4 | digit
            }
            index += 4
            return value
        }

        /// JSON's number grammar, kept as text. `01` and `.5` are refused here rather than
        /// silently read as `0` and then tripping the caller: a body Nyx half-reads is a body it
        /// should have shown raw.
        mutating func number() -> JSONValue? {
            let start = index
            if current == UInt8(ascii: "-") { index += 1 }
            guard let first = current, isDigit(first) else { return nil }
            if first == UInt8(ascii: "0") {
                index += 1
            } else {
                while let byte = current, isDigit(byte) { index += 1 }
            }
            if current == UInt8(ascii: ".") {
                index += 1
                guard let byte = current, isDigit(byte) else { return nil }
                while let byte = current, isDigit(byte) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard let byte = current, isDigit(byte) else { return nil }
                while let byte = current, isDigit(byte) { index += 1 }
            }
            return .number(String(decoding: bytes[start ..< index], as: UTF8.self))
        }

        func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    }
}
