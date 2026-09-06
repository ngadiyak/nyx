import Foundation

/// A target a captured curl command can be rewritten into. Each one is a *different* HTTP
/// client's idiom, not a dialect of curl -- an HTTPie flag, a fetch option and a Python keyword
/// argument for the same behaviour rarely share a spelling, which is why every case gets its own
/// renderer in `RequestExport` rather than one templated writer.
public enum ExportFormat: String, CaseIterable, Equatable {
    case httpie
    case fetch
    case pythonRequests
    case go

    /// The name shown in the export menu.
    public var title: String {
        switch self {
        case .httpie: return "HTTPie"
        case .fetch: return "JavaScript fetch"
        case .pythonRequests: return "Python requests"
        case .go: return "Go"
        }
    }
}

/// Rewrites a parsed curl command as the request another tool would make. v1: secrets are written
/// out in full -- masking a value that is about to be pasted into a script the user is about to
/// run would hide the credential from the one place it still needs to be readable. `Masking` in
/// `CurlSerialiser` stays the only masked path.
public enum RequestExport {
    public static func render(_ command: CurlCommand, as format: ExportFormat) -> String {
        switch format {
        case .httpie: return renderHTTPie(command)
        case .fetch: return renderFetch(command)
        case .pythonRequests: return renderPython(command)
        case .go: return renderGo(command)
        }
    }
}

// MARK: - Shared reading of a `CurlCommand`

/// A `curl -H`/`-A .../-b ...` value taken apart into JSON, when it is one. Detection follows the
/// brief's three routes: an explicit `Content-Type`, curl's own `--json`, or -- for a body with
/// neither -- a body that happens to parse. The third route uses `JSONSerialization` for exactly
/// the yes/no answer; the text is then re-parsed by `MiniJSON` so the *rendering* keeps the keys
/// in the order the user wrote them, which `JSONSerialization`'s bridged dictionary does not
/// promise to do twice in a row.
private func jsonBody(_ command: CurlCommand) -> MiniJSON.Value? {
    guard let body = command.body, let text = bodyPlainText(body) else { return nil }
    if bodyDeclaresJSON(command) {
        return MiniJSON.parse(text)
    }
    guard let data = text.data(using: .utf8),
          (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    else { return nil }
    return MiniJSON.parse(text)
}

private func bodyDeclaresJSON(_ command: CurlCommand) -> Bool {
    if case .json = command.body { return true }
    for header in command.headers where header.name.lowercased() == "content-type" {
        return header.value.text.lowercased().contains("application/json")
    }
    return false
}

/// The body's text, whatever curl option produced it. `&`-joins are curl's own rule for repeated
/// `-d`/`--data-urlencode`, not a guess -- see `Body`'s doc comment. `.form` and `.upload` have no
/// single string to show (a multipart body and a file path are not text), so they render as
/// nothing here; the caller falls back to leaving the body out and naming the option in the
/// trailing "not translated" comment instead of guessing at a shape nobody asked for.
private func bodyPlainText(_ body: CurlCommand.Body) -> String? {
    switch body {
    case .data(let words): return words.map(\.text).joined(separator: "&")
    case .raw(let word): return word.text
    case .binary(let word): return word.text
    case .urlencoded(let words): return words.map(\.text).joined(separator: "&")
    case .json(let word): return word.text
    case .form, .upload: return nil
    }
}

/// A query parameter, from wherever it came from: the URL's own `?...` or one of curl's `-G`
/// pairs. A plain tuple rather than `CurlCommand.QueryItem` because the second source has no
/// `ShellWord` to keep -- see `getQueryPairs`.
private typealias QueryPair = (name: String, value: String?)

/// Whether `-G` retargets this command's body into the query string instead of sending it --
/// true only for the two body kinds curl's own `-G` documentation names (`-d`/`--data` and
/// `--data-urlencode`); `--json`, `-F` and `-T` are not in that list; curl's own doc.
private func queryConsumingBody(_ command: CurlCommand) -> Bool {
    guard command.get else { return false }
    switch command.body {
    case .data?, .urlencoded?: return true
    default: return false
    }
}

/// The pairs `-G` moves from the body into the query string, in the order curl would send them.
/// `.data` items are split on `&` -- a single `-d 'a=1&b=2'` is already two pairs, and curl joins
/// separate `-d` occurrences with `&` before doing anything else with them, so splitting each
/// word and flattening in order reproduces that join without materialising it. `.urlencoded`
/// items are not split: each `--data-urlencode` occurrence is already exactly one pair by
/// construction, and a `&` inside its value is data, not a separator.
///
/// Values are never percent-decoded *or* pre-encoded here: curl itself percent-encodes a
/// `--data-urlencode` value (and sends a plain `-d` value as written) at the point it builds the
/// request, so the text kept in `CurlCommand` is what a person typed. Every renderer below hands
/// these to the target's own query-building call (`params=`, `URLSearchParams`,
/// `url.QueryEscape`, HTTPie's `==`) so the *target* does the encoding curl would have done,
/// instead of this code guessing at it twice.
private func getQueryPairs(_ command: CurlCommand) -> [QueryPair] {
    func pair(_ text: String) -> QueryPair {
        guard let equals = text.firstIndex(of: "=") else { return (text, nil) }
        return (String(text[text.startIndex ..< equals]), String(text[text.index(after: equals)...]))
    }
    switch command.body {
    case .data(let words) where command.get:
        return words.flatMap { $0.text.split(separator: "&", omittingEmptySubsequences: false).map { pair(String($0)) } }
    case .urlencoded(let words) where command.get:
        return words.map { pair($0.text) }
    default:
        return []
    }
}

/// The URL split into a query-free base and its items, for the formats that have a native way to
/// carry query parameters separately from the path (HTTPie's `name==value`, Python's `params=`,
/// and fetch/Go when `-G` has put pairs there that need real encoding -- see `renderFetch` and
/// `renderGo`). A URL built from a variable (`$API/...`) keeps its full string with no items split
/// out of *it*: `URLParts` says itself that splitting a variable-bearing URL into host/path is a
/// guess, and turning that guess into query items a person did not write would be worse than
/// leaving the string alone. `-G` pairs are still appended in that case -- they come from
/// separate `-d`/`--data-urlencode` words, never from the URL word, so there is nothing to guess
/// at there even when the URL itself is opaque.
private func splitQuery(_ command: CurlCommand) -> (base: String, items: [QueryPair]) {
    let getPairs = getQueryPairs(command)
    guard !command.url.raw.containsVariable else { return (command.url.string, getPairs) }
    var base = ""
    if let scheme = command.url.scheme { base += scheme + "://" }
    base += command.url.host
    if let port = command.url.port { base += ":\(port)" }
    base += command.url.path
    let items: [QueryPair] = command.url.query.map { ($0.name, $0.value) } + getPairs
    return (base, items)
}

/// Whether any header or auth value this render would touch carries a shell variable -- the
/// signal for whether Python's `os` needs importing at all. Body variables are not scanned:
/// none of curl's body options preserve enough structure to interpolate one field of a body
/// safely, so a variable inside a body is left as literal text rather than guessed at.
private func commandUsesVariables(_ command: CurlCommand) -> Bool {
    if command.headers.contains(where: { $0.value.containsVariable }) { return true }
    switch command.auth {
    case .bearer(let token): return token.containsVariable
    case .header(let value): return value.containsVariable
    case .basic(_, let password): return password?.containsVariable ?? false
    case .none: return false
    }
}

/// A `$TOKEN` / `${TOKEN}` spelling's bare name, or `nil` for `$(cmd)` -- a command substitution
/// is not an environment variable, and guessing a name for it would silently run the wrong code
/// in every target language. Callers fall back to writing the spelling as a literal instead.
private func envVarName(from spelling: String) -> String? {
    if spelling.hasPrefix("${"), spelling.hasSuffix("}") {
        return String(spelling.dropFirst(2).dropLast())
    }
    if spelling.hasPrefix("$"), !spelling.hasPrefix("$(") {
        return String(spelling.dropFirst())
    }
    return nil
}

/// Curl's own compact number spelling (`10`, not `10.0`) -- shared by `--max-time` and the
/// `--retry-delay` / `--connect-timeout` entries in the "not translated" comment, so a whole
/// second reads as `10` in every target rather than a language-specific float literal.
private func numberText(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    for precision in 1 ... 17 {
        var text = String(format: "%.\(precision)f", value)
        guard Double(text) == value else { continue }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
    return String(value)
}

/// Every header a request sends, in the order it would go on the wire: a bearer token or a raw
/// `Authorization:` value first (curl read it out of `-H` in the first place), then the headers
/// `CurlCommand` kept as headers. Basic auth is not here -- every target below has its own idiom
/// for it (`-a`, `auth=`, `SetBasicAuth`) rather than a header line, fetch included, so it is
/// built separately in `fetchHeaderEntries`. A header curl would remove (`Name:` with nothing
/// after it) sends nothing and is skipped rather than exported as an empty string.
private func effectiveHeaders(_ command: CurlCommand) -> [(name: String, value: ShellWord)] {
    var entries: [(String, ShellWord)] = []
    switch command.auth {
    case .bearer(let token):
        entries.append(("Authorization", ShellWord(pieces: [.text("Bearer ")] + token.pieces)))
    case .header(let value):
        entries.append(("Authorization", value))
    case .basic, .none:
        break
    }
    for header in command.headers where !header.removes {
        entries.append((header.name, header.value))
    }
    return entries
}

/// The one line naming every option this render has no place for: `other` (proxies, TLS pinning,
/// HTTP-version pins -- whatever curl knows that this model does not), cookies, the retry/output
/// options, and the flags with no equivalent in any target (`-i`, `-s`, `-S`, `--compressed`,
/// `-v`, `-f`, `-N`). `-L`, `-k` and `--max-time` are never in this list: they are translated
/// (§ rules), so naming them here as well would tell the reader the opposite of what happened.
/// `nil` when the command has nothing left unaccounted for -- the brief's "no comment when
/// nothing is untranslated".
private func untranslatedComment(_ command: CurlCommand, style: CommentStyle) -> String? {
    var items: [String] = []

    let flagOrder: [(CurlCommand.Flags, String)] = [
        (.include, "-i"), (.silent, "-s"), (.showError, "-S"),
        (.compressed, "--compressed"), (.verbose, "-v"), (.fail, "-f"), (.noBuffer, "-N"),
    ]
    for (flag, name) in flagOrder where command.flags.contains(flag) { items.append(name) }

    if let send = command.cookies.send { items.append("-b \(send.text)") }
    if let jar = command.cookies.jar { items.append("-c \(jar.text)") }

    if let retry = command.timing.retry { items.append("--retry \(retry)") }
    if let delay = command.timing.retryDelay { items.append("--retry-delay \(numberText(delay))") }
    if let connect = command.timing.connectTimeout { items.append("--connect-timeout \(numberText(connect))") }

    if let file = command.output.file { items.append("-o \(file.text)") }
    if command.output.remoteName { items.append("-O") }
    if let dump = command.output.dumpHeaders { items.append("-D \(dump.text)") }
    if let write = command.output.writeOut { items.append("-w \(write.text)") }

    if case .form(let fields)? = command.body {
        for field in fields { items.append("-F \(field.name)=\(field.value.text)") }
    }
    if case .upload(let file)? = command.body {
        items.append("-T \(file.text)")
    }

    for entry in command.other {
        if entry.option.isEmpty {
            if let value = entry.value { items.append(value.text) }
            continue
        }
        if let value = entry.value {
            items.append("\(entry.option) \(value.text)")
        } else {
            items.append(entry.option)
        }
    }

    guard !items.isEmpty else { return nil }
    return style.prefix + items.joined(separator: ", ")
}

private enum CommentStyle {
    case hash
    case slash

    var prefix: String {
        switch self {
        case .hash: return "# not translated: "
        case .slash: return "// not translated: "
        }
    }
}

// MARK: - A tiny order-preserving JSON reader

/// A minimal recursive-descent JSON reader. Deliberately not strict where strictness would only
/// reject text `CurlCommand` already accepted as a body: a literal control character inside a
/// string (curl's `$'...\n...'` bodies contain a real newline byte, not the two-character `\n`
/// escape) is read as itself rather than rejected, because the alternative is refusing to render
/// a body this same process just finished treating as valid JSON.
private enum MiniJSON {
    /// A JSON value that remembers the order its object keys were written in. `JSONSerialization`'s
    /// bridged dictionary does not promise that, and every renderer below needs the *same* order
    /// `JSONSerialization` was only consulted to validate -- so parsing happens twice: once (in
    /// `jsonBody`) to answer "is this JSON", and once here to answer "in what order".
    ///
    /// Not `JSONDocument`/`JSONValue`, which is the response side's reader and is strict where
    /// this one must not be -- see the note on `MiniJSON` about control characters in a `$'...'`
    /// body.
    indirect enum Value {
        case string(String)
        case number(String)
        case bool(Bool)
        case null
        case array([Value])
        case object([(String, Value)])
    }

    static func parse(_ text: String) -> MiniJSON.Value? {
        var reader = Reader(Array(text.unicodeScalars))
        reader.skipWhitespace()
        guard let value = reader.parseValue() else { return nil }
        reader.skipWhitespace()
        guard reader.atEnd else { return nil }
        return value
    }

    private struct Reader {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }
        var current: Unicode.Scalar? { atEnd ? nil : scalars[index] }

        mutating func skipWhitespace() {
            while let c = current, c == " " || c == "\t" || c == "\n" || c == "\r" { index += 1 }
        }

        mutating func parseValue() -> MiniJSON.Value? {
            guard let c = current else { return nil }
            switch c {
            case "{": return parseObject()
            case "[": return parseArray()
            case "\"": return parseString().map(MiniJSON.Value.string)
            case "t": return consume(literal: "true") ? .bool(true) : nil
            case "f": return consume(literal: "false") ? .bool(false) : nil
            case "n": return consume(literal: "null") ? .null : nil
            default: return parseNumber()
            }
        }

        mutating func consume(literal: String) -> Bool {
            let wanted = Array(literal.unicodeScalars)
            guard index + wanted.count <= scalars.count else { return false }
            guard Array(scalars[index ..< index + wanted.count]) == wanted else { return false }
            index += wanted.count
            return true
        }

        mutating func parseObject() -> MiniJSON.Value? {
            index += 1 // "{"
            var pairs: [(String, MiniJSON.Value)] = []
            skipWhitespace()
            if current == "}" { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard current == "\"", let key = parseString() else { return nil }
                skipWhitespace()
                guard current == ":" else { return nil }
                index += 1
                skipWhitespace()
                guard let value = parseValue() else { return nil }
                pairs.append((key, value))
                skipWhitespace()
                if current == "," { index += 1; continue }
                if current == "}" { index += 1; return .object(pairs) }
                return nil
            }
        }

        mutating func parseArray() -> MiniJSON.Value? {
            index += 1 // "["
            var items: [MiniJSON.Value] = []
            skipWhitespace()
            if current == "]" { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                guard let value = parseValue() else { return nil }
                items.append(value)
                skipWhitespace()
                if current == "," { index += 1; continue }
                if current == "]" { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func parseString() -> String? {
            index += 1 // opening quote
            var out = String.UnicodeScalarView()
            while let c = current {
                if c == "\"" { index += 1; return String(out) }
                if c == "\\" {
                    index += 1
                    guard let escape = current else { return nil }
                    switch escape {
                    case "\"": out.append("\""); index += 1
                    case "\\": out.append("\\"); index += 1
                    case "/": out.append("/"); index += 1
                    case "b": out.append(Unicode.Scalar(0x08)); index += 1
                    case "f": out.append(Unicode.Scalar(0x0C)); index += 1
                    case "n": out.append("\n"); index += 1
                    case "r": out.append("\r"); index += 1
                    case "t": out.append("\t"); index += 1
                    case "u":
                        index += 1
                        guard let scalar = parseHex4() else { return nil }
                        out.append(scalar)
                        continue
                    default: return nil
                    }
                    continue
                }
                out.append(c)
                index += 1
            }
            return nil // unterminated string
        }

        mutating func parseHex4() -> Unicode.Scalar? {
            guard index + 4 <= scalars.count else { return nil }
            let hex = String(String.UnicodeScalarView(scalars[index ..< index + 4]))
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
            index += 4
            return scalar
        }

        mutating func parseNumber() -> MiniJSON.Value? {
            let start = index
            if current == "-" { index += 1 }
            while let c = current, ("0" ... "9").contains(c) { index += 1 }
            if current == "." {
                index += 1
                while let c = current, ("0" ... "9").contains(c) { index += 1 }
            }
            if current == "e" || current == "E" {
                index += 1
                if current == "+" || current == "-" { index += 1 }
                while let c = current, ("0" ... "9").contains(c) { index += 1 }
            }
            guard index > start else { return nil }
            return .number(String(String.UnicodeScalarView(scalars[start ..< index])))
        }
    }
}

// MARK: - HTTPie

private func renderHTTPie(_ command: CurlCommand) -> String {
    var head = ["http"]
    if command.flags.contains(.location) { head.append("--follow") }
    if command.flags.contains(.insecure) { head.append("--verify=no") }
    if let maxTime = command.timing.maxTime { head.append("--timeout=\(numberText(maxTime))") }
    if case .basic(let user, let password) = command.auth {
        head.append("-a")
        let word = password.map { ShellWord(pieces: [.text(user + ":")] + $0.pieces) } ?? ShellWord(user)
        head.append(ShellWords.quote(word))
    }

    var groups: [[String]] = [head]

    let (base, query) = splitQuery(command)
    groups.append([command.effectiveMethod, base])

    for item in query {
        let text = "\(item.name)==\(item.value ?? "")"
        groups.append([ShellWords.quote(ShellWord(text))])
    }

    for header in effectiveHeaders(command) {
        let word = ShellWord(pieces: [.text(header.name + ":")] + header.value.pieces)
        groups.append([ShellWords.quote(word)])
    }

    if let body = command.body, !queryConsumingBody(command) {
        groups.append(contentsOf: httpieBodyGroups(command, body))
    }

    let lines = groups.filter { !$0.isEmpty }.map { $0.joined(separator: " ") }
    var text = lines.enumerated().map { index, line -> String in
        let padded = index == 0 ? line : "  " + line
        return index == lines.count - 1 ? padded : padded + " \\"
    }.joined(separator: "\n")

    if let comment = untranslatedComment(command, style: .hash) {
        text += "\n" + comment
    }
    return text + "\n"
}

/// `field=value` items when the body is a flat JSON object of strings -- HTTPie builds the same
/// JSON body back out of those without a `--raw` and a person can still read the field names on
/// the command line. Anything else (nesting, a non-string value, or not JSON at all) goes through
/// as `--raw`, quoted like any other curl value so a literal newline in the source still reads as
/// one line via `$'...'`.
private func httpieBodyGroups(_ command: CurlCommand, _ body: CurlCommand.Body) -> [[String]] {
    if let json = jsonBody(command), case .object(let pairs) = json,
       !pairs.isEmpty, pairs.allSatisfy({ if case .string = $0.1 { return true } else { return false } }) {
        return pairs.map { key, value in
            guard case .string(let s) = value else { return [] }
            return [ShellWords.quote(ShellWord("\(key)=\(s)"))]
        }
    }
    guard let text = bodyPlainText(body) else { return [] }
    return [["--raw", ShellWords.quote(ShellWord(text))]]
}

// MARK: - JavaScript fetch

private func renderFetch(_ command: CurlCommand) -> String {
    var lines: [String] = []

    let urlExpr: String
    if queryConsumingBody(command) {
        let (base, items) = splitQuery(command)
        lines.append("const params = new URLSearchParams();")
        for item in items {
            lines.append("params.append(\(jsString(item.name)), \(jsString(item.value ?? "")));")
        }
        lines.append("")
        // `URLSearchParams` does its own percent-encoding at call time -- and, unlike
        // `url.Values.Encode()` in Go, keeps insertion order -- so building the final URL from it
        // rather than concatenating the raw pair text is what makes a space in a `-d` value come
        // out `%20` here the way curl would have sent it, not a broken URL.
        urlExpr = "\(jsString(base)) + \"?\" + params.toString()"
    } else {
        urlExpr = jsString(command.url.string)
    }
    lines.append("fetch(\(urlExpr), {")
    lines.append("  method: \(jsString(command.effectiveMethod)),")

    let headers = fetchHeaderEntries(command)
    if !headers.isEmpty {
        lines.append("  headers: {")
        for (name, expr) in headers { lines.append("    \(jsString(name)): \(expr),") }
        lines.append("  },")
    }

    if let body = command.body, !queryConsumingBody(command) {
        if let json = jsonBody(command) {
            lines.append("  body: JSON.stringify(\(jsLiteral(json, indent: 2))),")
        } else if let text = bodyPlainText(body) {
            lines.append("  body: \(jsString(text)),")
        }
    }

    if command.flags.contains(.location) { lines.append("  redirect: \"follow\",") }
    if command.flags.contains(.insecure) {
        lines.append("  // -k: fetch cannot disable TLS certificate verification")
    }
    if let maxTime = command.timing.maxTime {
        lines.append("  signal: AbortSignal.timeout(\(numberText(maxTime * 1000))),")
    }

    lines.append("})")
    lines.append("  .then((response) => response.json())")
    lines.append("  .then((data) => console.log(data))")
    lines.append("  .catch((error) => console.error(error));")

    var text = lines.joined(separator: "\n")
    if let comment = untranslatedComment(command, style: .slash) {
        text += "\n" + comment
    }
    return text + "\n"
}

/// Headers plus, unlike every other target, basic auth: fetch has no request-building kwarg for
/// it, so the brief's `Authorization: Basic ` + `btoa(...)` *is* the translation, not a fallback.
private func fetchHeaderEntries(_ command: CurlCommand) -> [(String, String)] {
    var entries: [(String, String)] = []
    switch command.auth {
    case .bearer(let token):
        entries.append(("Authorization", jsExpr(ShellWord(pieces: [.text("Bearer ")] + token.pieces))))
    case .header(let value):
        entries.append(("Authorization", jsExpr(value)))
    case .basic(let user, let password):
        let combined = ShellWord(pieces: [.text(user + ":")] + (password?.pieces ?? [.text("")]))
        entries.append(("Authorization", "`Basic ${btoa(\(jsExpr(combined)))}`"))
    case .none:
        break
    }
    for header in command.headers where !header.removes {
        entries.append((header.name, jsExpr(header.value)))
    }
    return entries
}

/// A `ShellWord` as a JS expression: a plain string literal when it carries no variable, or a
/// template literal with `${process.env.NAME}` where the shell had `$NAME` -- the interpolation
/// only fires for a name `envVarName` can read; a `$(cmd)` substitution has none, so its spelling
/// is written back as literal text rather than invented as a call this render cannot verify.
private func jsExpr(_ word: ShellWord) -> String {
    guard word.containsVariable else { return jsString(word.text) }
    var out = "`"
    for piece in word.pieces {
        switch piece {
        case .text(let text): out += jsTemplateEscape(text)
        case .variable(let spelling):
            if let name = envVarName(from: spelling) {
                out += "${process.env.\(name)}"
            } else {
                out += jsTemplateEscape(spelling)
            }
        }
    }
    out += "`"
    return out
}

private func jsString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

private func jsTemplateEscape(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "`": out += "\\`"
        case "$": out += "\\$"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// A parsed JSON value written back out as a JS object literal, one field per line so a diff
/// against the source body is readable. Keys are always quoted -- a header name is never a valid
/// identifier, and this printer is shared with the body literal, where quoting every key rather
/// than checking each one against JS identifier syntax is one rule instead of two.
private func jsLiteral(_ value: MiniJSON.Value, indent: Int) -> String {
    switch value {
    case .string(let s): return jsString(s)
    case .number(let n): return n
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .array(let items):
        guard !items.isEmpty else { return "[]" }
        let inner = indent + 2
        let pad = String(repeating: " ", count: inner)
        let body = items.map { pad + jsLiteral($0, indent: inner) + "," }.joined(separator: "\n")
        return "[\n\(body)\n\(String(repeating: " ", count: indent))]"
    case .object(let pairs):
        guard !pairs.isEmpty else { return "{}" }
        let inner = indent + 2
        let pad = String(repeating: " ", count: inner)
        let body = pairs.map { pad + jsString($0.0) + ": " + jsLiteral($0.1, indent: inner) + "," }.joined(separator: "\n")
        return "{\n\(body)\n\(String(repeating: " ", count: indent))}"
    }
}

// MARK: - Python requests

private func renderPython(_ command: CurlCommand) -> String {
    let (base, query) = splitQuery(command)
    var lines: [String] = []
    lines.append("response = requests.request(")
    lines.append("    \(pyString(command.effectiveMethod)),")
    lines.append("    \(pyString(base)),")

    if !query.isEmpty {
        lines.append("    params={")
        for item in query { lines.append("        \(pyString(item.name)): \(pyString(item.value ?? "")),") }
        lines.append("    },")
    }

    let headers = pythonHeaderEntries(command)
    if !headers.isEmpty {
        lines.append("    headers={")
        for (name, expr) in headers { lines.append("        \(pyString(name)): \(expr),") }
        lines.append("    },")
    }

    if let body = command.body, !queryConsumingBody(command) {
        if let json = jsonBody(command) {
            lines.append("    json=\(pyLiteral(json, indent: 4)),")
        } else if let text = bodyPlainText(body) {
            lines.append("    data=\(pyString(text)),")
        }
    }

    if case .basic(let user, let password) = command.auth {
        let passwordExpr = password.map { pyExpr($0) } ?? "None"
        lines.append("    auth=(\(pyString(user)), \(passwordExpr)),")
    }

    if command.flags.contains(.location) { lines.append("    allow_redirects=True,") }
    if command.flags.contains(.insecure) { lines.append("    verify=False,") }
    if let maxTime = command.timing.maxTime { lines.append("    timeout=\(numberText(maxTime)),") }

    lines.append(")")

    let importLine = commandUsesVariables(command) ? "import os\nimport requests" : "import requests"
    var text = importLine + "\n\n" + lines.joined(separator: "\n") + "\n\nprint(response.status_code, response.text)"
    if let comment = untranslatedComment(command, style: .hash) {
        text += "\n" + comment
    }
    return text + "\n"
}

private func pythonHeaderEntries(_ command: CurlCommand) -> [(String, String)] {
    var entries: [(String, String)] = []
    switch command.auth {
    case .bearer(let token):
        entries.append(("Authorization", pyExpr(ShellWord(pieces: [.text("Bearer ")] + token.pieces))))
    case .header(let value):
        entries.append(("Authorization", pyExpr(value)))
    case .basic, .none:
        break
    }
    for header in command.headers where !header.removes {
        entries.append((header.name, pyExpr(header.value)))
    }
    return entries
}

/// A `ShellWord` as a Python expression. A word that *is* a bare variable and nothing else
/// becomes the brief's standalone form, `os.environ["NAME"]` -- a dict lookup, not a string, so
/// it can stand alone as `auth=("user", os.environ["PASS"])`. A variable inside a larger string
/// becomes an f-string with the single-quoted key the brief gives for that case, so the two
/// spellings never collide inside one literal.
private func pyExpr(_ word: ShellWord) -> String {
    if word.isVariable, case .variable(let spelling)? = word.pieces.first, let name = envVarName(from: spelling) {
        return "os.environ[\"\(name)\"]"
    }
    guard word.containsVariable else { return pyString(word.text) }
    var out = "f\""
    for piece in word.pieces {
        switch piece {
        case .text(let text): out += pyFStringEscape(text)
        case .variable(let spelling):
            if let name = envVarName(from: spelling) {
                out += "{os.environ['\(name)']}"
            } else {
                out += pyFStringEscape(spelling)
            }
        }
    }
    out += "\""
    return out
}

private func pyString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// Like `pyString`'s escaping, plus doubling a brace: inside an f-string a bare `{`/`}` opens or
/// closes an interpolation, and a header value that happens to contain one (rare, but curl does
/// not forbid it) would otherwise be read as Python rather than shown as text.
private func pyFStringEscape(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "{": out += "{{"
        case "}": out += "}}"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

private func pyLiteral(_ value: MiniJSON.Value, indent: Int) -> String {
    switch value {
    case .string(let s): return pyString(s)
    case .number(let n): return n
    case .bool(let b): return b ? "True" : "False"
    case .null: return "None"
    case .array(let items):
        guard !items.isEmpty else { return "[]" }
        let inner = indent + 4
        let pad = String(repeating: " ", count: inner)
        let body = items.map { pad + pyLiteral($0, indent: inner) + "," }.joined(separator: "\n")
        return "[\n\(body)\n\(String(repeating: " ", count: indent))]"
    case .object(let pairs):
        guard !pairs.isEmpty else { return "{}" }
        let inner = indent + 4
        let pad = String(repeating: " ", count: inner)
        let body = pairs.map { pad + pyString($0.0) + ": " + pyLiteral($0.1, indent: inner) + "," }.joined(separator: "\n")
        return "{\n\(body)\n\(String(repeating: " ", count: indent))}"
    }
}

// MARK: - Go

private func renderGo(_ command: CurlCommand) -> String {
    let consumesBody = queryConsumingBody(command)
    let bodyText = consumesBody ? nil : command.body.flatMap(bodyPlainText)
    let usesOS = commandUsesVariables(command)
    let usesTLS = command.flags.contains(.insecure)
    let usesTimeout = command.timing.maxTime != nil

    var imports = ["fmt", "io", "net/http"]
    if usesTLS { imports.append("crypto/tls") }
    if usesOS { imports.append("os") }
    if bodyText != nil { imports.append("strings") }
    if consumesBody { imports.append("net/url") }
    if usesTimeout { imports.append("time") }
    imports.sort()

    var lines: [String] = ["package main", "", "import ("]
    for name in imports { lines.append("\t\(goString(name))") }
    lines.append(")")
    lines.append("")
    lines.append("func main() {")

    let requestURLExpr: String
    let bodyArg: String
    if consumesBody {
        let (base, items) = splitQuery(command)
        // `url.Values{}.Encode()` sorts its keys, which would reorder `-a=1&b=2` into `a=1&b=2`
        // even when curl -- and the source command -- wrote them the other way round; escaping
        // each pair by hand and joining in the order `-G` would send them is what keeps that
        // order, at the cost of not being the one-liner `url.Values` usually is.
        lines.append("\tquery := \(goQueryEscapeExpr(items))")
        requestURLExpr = "\(goString(base))+\"?\"+query"
        bodyArg = "nil"
    } else {
        requestURLExpr = goString(command.url.string)
        bodyArg = bodyText.map { "strings.NewReader(\(goRawOrString($0)))" } ?? "nil"
    }
    lines.append("\treq, err := http.NewRequest(\(goString(command.effectiveMethod)), \(requestURLExpr), \(bodyArg))")
    lines.append("\tif err != nil {")
    lines.append("\t\tpanic(err)")
    lines.append("\t}")

    for (name, expr) in goHeaderEntries(command) {
        lines.append("\treq.Header.Set(\(goString(name)), \(expr))")
    }
    if case .basic(let user, let password) = command.auth {
        let passwordExpr = password.map { goExpr($0) } ?? goString("")
        lines.append("\treq.SetBasicAuth(\(goString(user)), \(passwordExpr))")
    }

    lines.append("")
    if usesTLS || usesTimeout {
        lines.append("\tclient := &http.Client{")
        if usesTLS {
            lines.append("\t\tTransport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},")
        }
        if usesTimeout, let maxTime = command.timing.maxTime {
            lines.append("\t\tTimeout: \(numberText(maxTime)) * time.Second,")
        }
        lines.append("\t}")
    } else {
        lines.append("\tclient := &http.Client{}")
    }
    lines.append("\tresp, err := client.Do(req)")
    lines.append("\tif err != nil {")
    lines.append("\t\tpanic(err)")
    lines.append("\t}")
    lines.append("\tdefer resp.Body.Close()")
    lines.append("")
    lines.append("\tbody, _ := io.ReadAll(resp.Body)")
    lines.append("\tfmt.Println(resp.StatusCode, string(body))")
    lines.append("}")

    var text = lines.joined(separator: "\n")
    if let comment = untranslatedComment(command, style: .slash) {
        // gofmt inserts the blank line itself before a comment that trails a top-level
        // declaration with nothing attaching it -- matching that here means the fixture this
        // renders already satisfies `gofmt -l` instead of gofmt rewriting it on first save.
        text += "\n\n" + comment
    }
    return text + "\n"
}

private func goHeaderEntries(_ command: CurlCommand) -> [(String, String)] {
    var entries: [(String, String)] = []
    switch command.auth {
    case .bearer(let token):
        entries.append(("Authorization", goExpr(ShellWord(pieces: [.text("Bearer ")] + token.pieces))))
    case .header(let value):
        entries.append(("Authorization", goExpr(value)))
    case .basic, .none:
        break
    }
    for header in command.headers where !header.removes {
        entries.append((header.name, goExpr(header.value)))
    }
    return entries
}

/// A `ShellWord` as a Go expression: a bare variable becomes `os.Getenv("NAME")` -- a call, so it
/// can stand alone as `SetBasicAuth("user", os.Getenv("PASS"))` -- and a variable inside a larger
/// string becomes `+`-concatenation, Go having no template-literal syntax of its own.
private func goExpr(_ word: ShellWord) -> String {
    if word.isVariable, case .variable(let spelling)? = word.pieces.first, let name = envVarName(from: spelling) {
        return "os.Getenv(\"\(name)\")"
    }
    guard word.containsVariable else { return goString(word.text) }
    var parts: [String] = []
    for piece in word.pieces {
        switch piece {
        case .text(let text):
            if !text.isEmpty { parts.append(goString(text)) }
        case .variable(let spelling):
            if let name = envVarName(from: spelling) {
                parts.append("os.Getenv(\"\(name)\")")
            } else {
                parts.append(goString(spelling))
            }
        }
    }
    return parts.isEmpty ? "\"\"" : parts.joined(separator: "+")
}

private func goString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// The brief's raw-string-literal rule (`` strings.NewReader(`…`) ``), with one guard: a body
/// that itself contains a backtick cannot be written between backticks, so that (untested, and
/// not hit by either fixture) case falls back to an ordinary escaped Go string instead of
/// producing source Go will not compile.
private func goRawOrString(_ text: String) -> String {
    text.contains("`") ? goString(text) : "`\(text)`"
}

/// `-G` pairs written as `url.QueryEscape(name)+"="+url.QueryEscape(value)`, joined by a literal
/// `"&"` in the order given -- see `renderGo`'s comment on why this is not `url.Values{}.Encode()`.
private func goQueryEscapeExpr(_ items: [QueryPair]) -> String {
    // gofmt spaces a `+` between two call expressions but not between two literals (compare this
    // line's own `foo() + "=" + bar()` against `renderGo`'s `goString(base)+"?"+query`) -- written
    // pre-spaced here so the fixture this produces is already what `gofmt -l` wants, not what it
    // would rewrite on first save.
    items.map { item in
        "url.QueryEscape(\(goString(item.name))) + \"=\" + url.QueryEscape(\(goString(item.value ?? "")))"
    }.joined(separator: " + \"&\" + ")
}
