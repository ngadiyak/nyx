import Foundation

/// A `curl` command line taken apart into the pieces an HTTP request is made of, without losing
/// anything: every option curl understands is either a named field here or an entry in `other`,
/// and `trailingPipeline` keeps whatever the user piped the response into. Nothing is resolved --
/// `$TOKEN` stays a `ShellWord` variable -- because this type is also the thing a later stage
/// writes back out as a command line, and a substituted secret must not survive that round trip.
public struct CurlCommand: Equatable {
    /// One `-H` argument. `Name:` with nothing after it is curl's "do not send this header at all"
    /// spelling and `Name;` is its "send it empty" spelling; the two collapse to the same text, so
    /// `removes` is the only thing that tells them apart.
    public struct Header: Equatable {
        public var name: String
        public var value: ShellWord
        public var removes: Bool

        public init(name: String, value: ShellWord, removes: Bool) {
            self.name = name
            self.value = value
            self.removes = removes
        }
    }

    public struct QueryItem: Equatable {
        public var name: String
        /// `nil` for a bare `?flag` with no `=`, which is not the same as `?flag=`.
        public var value: String?

        public init(name: String, value: String?) {
            self.name = name
            self.value = value
        }
    }

    /// One `-F` field. A struct rather than a tuple because a tuple cannot be `Equatable`, which
    /// `Body` needs.
    public struct FormItem: Equatable {
        public var name: String
        /// Everything after the first `=`, including curl's `;type=...` / `;filename=...` suffixes:
        /// splitting those out would need curl's own escaping rules and nothing here reads them yet.
        public var value: ShellWord

        public init(name: String, value: ShellWord) {
            self.name = name
            self.value = value
        }
    }

    /// The request body, in the spelling that produced it -- `-d` and `--data-raw` differ in
    /// whether curl expands `@file` and strips newlines, so collapsing them would change meaning.
    public enum Body: Equatable {
        case data([ShellWord])       // -d/--data/--data-ascii, joined with `&` by curl
        case raw(ShellWord)          // --data-raw
        case binary(ShellWord)       // --data-binary
        case urlencoded([ShellWord]) // --data-urlencode
        case json(ShellWord)         // --json
        case form([FormItem])        // -F/--form
        case upload(ShellWord)       // -T/--upload-file
    }

    /// `.header` is any `Authorization:` value that is not a bearer token (Basic, Digest, an
    /// AWS signature). Either way the header leaves `headers` so it has exactly one home.
    public enum Auth: Equatable {
        case none
        case basic(user: String, password: ShellWord?)
        case bearer(ShellWord)
        case header(ShellWord)
    }

    public struct Flags: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let include    = Flags(rawValue: 1 << 0) // -i
        public static let silent     = Flags(rawValue: 1 << 1) // -s
        public static let showError  = Flags(rawValue: 1 << 2) // -S
        public static let location   = Flags(rawValue: 1 << 3) // -L
        public static let insecure   = Flags(rawValue: 1 << 4) // -k
        public static let compressed = Flags(rawValue: 1 << 5) // --compressed
        public static let verbose    = Flags(rawValue: 1 << 6) // -v
        public static let fail       = Flags(rawValue: 1 << 7) // -f
        public static let noBuffer   = Flags(rawValue: 1 << 8) // -N
    }

    public struct Output: Equatable {
        public var file: ShellWord?
        public var remoteName: Bool
        public var dumpHeaders: ShellWord?
        public var writeOut: ShellWord?

        public init(file: ShellWord? = nil, remoteName: Bool = false, dumpHeaders: ShellWord? = nil, writeOut: ShellWord? = nil) {
            self.file = file
            self.remoteName = remoteName
            self.dumpHeaders = dumpHeaders
            self.writeOut = writeOut
        }
    }

    public struct Timing: Equatable {
        public var maxTime: Double?
        public var connectTimeout: Double?
        public var retry: Int?
        public var retryDelay: Double?

        public init(maxTime: Double? = nil, connectTimeout: Double? = nil, retry: Int? = nil, retryDelay: Double? = nil) {
            self.maxTime = maxTime
            self.connectTimeout = connectTimeout
            self.retry = retry
            self.retryDelay = retryDelay
        }
    }

    public struct Cookies: Equatable {
        public var send: ShellWord?  // -b
        public var jar: ShellWord?   // -c

        public init(send: ShellWord? = nil, jar: ShellWord? = nil) {
            self.send = send
            self.jar = jar
        }
    }

    /// An option this model has no field for, kept in source order so the command line can be
    /// rebuilt without dropping it. `option` is the spelling as written (`-x`, `--proxy`); an
    /// empty `option` is a bare word that was not the first URL.
    public struct Other: Equatable {
        public var option: String
        public var value: ShellWord?

        public init(option: String, value: ShellWord?) {
            self.option = option
            self.value = value
        }
    }

    /// A URL taken apart by hand. `Foundation.URL` is not used anywhere here: it rejects the
    /// `[1-3]` globs curl expands itself and the `$API` variables a pasted command is full of,
    /// and returning nil for those would make the workbench refuse the commands people actually
    /// have.
    public struct URLParts: Equatable {
        public var scheme: String?
        public var host: String
        public var port: Int?
        public var path: String
        public var query: [QueryItem]
        public var fragment: String?
        /// The word exactly as written, so a variable or a glob survives editing untouched.
        public var raw: ShellWord
        /// Rebuilt from the parts, except when `raw` contains a variable -- there the split into
        /// host and path is a guess (the scheme may be inside `$API`), so the source text stands.
        public var string: String

        public init(scheme: String?, host: String, port: Int?, path: String, query: [QueryItem], fragment: String?, raw: ShellWord, string: String) {
            self.scheme = scheme
            self.host = host
            self.port = port
            self.path = path
            self.query = query
            self.fragment = fragment
            self.raw = raw
            self.string = string
        }

        /// Splits `word` into scheme / host / port / path / query / fragment. Total: every input
        /// produces parts, because there is no reading of a curl URL that should stop the parse.
        public static func parse(_ word: ShellWord) -> URLParts {
            let text = word.text
            var rest = Substring(text)

            var scheme: String?
            if let separator = rest.range(of: "://") {
                // Only a scheme if the `://` comes before anything that would end the authority --
                // otherwise it is a `://` sitting inside a path or a query value.
                let head = rest[rest.startIndex ..< separator.lowerBound]
                if !head.contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                    scheme = String(head)
                    rest = rest[separator.upperBound...]
                }
            }

            var fragment: String?
            if let hash = rest.firstIndex(of: "#") {
                fragment = String(rest[rest.index(after: hash)...])
                rest = rest[rest.startIndex ..< hash]
            }

            var query: [QueryItem] = []
            if let mark = rest.firstIndex(of: "?") {
                let queryText = rest[rest.index(after: mark)...]
                rest = rest[rest.startIndex ..< mark]
                for pair in queryText.split(separator: "&", omittingEmptySubsequences: true) {
                    if let equals = pair.firstIndex(of: "=") {
                        query.append(QueryItem(name: String(pair[pair.startIndex ..< equals]),
                                               value: String(pair[pair.index(after: equals)...])))
                    } else {
                        query.append(QueryItem(name: String(pair), value: nil))
                    }
                }
            }

            var authority = rest
            var path = ""
            if let slash = rest.firstIndex(of: "/") {
                authority = rest[rest.startIndex ..< slash]
                path = String(rest[slash...])
            }

            var host = String(authority)
            var port: Int?
            if let colon = authority.lastIndex(of: ":") {
                let tail = authority[authority.index(after: colon)...]
                // `user:pass@host` also has a colon; only a run of digits at the very end is a port.
                if !tail.isEmpty, tail.allSatisfy(\.isNumber), let value = Int(tail) {
                    port = value
                    host = String(authority[authority.startIndex ..< colon])
                }
            }

            var rebuilt = ""
            if let scheme { rebuilt += scheme + "://" }
            rebuilt += host
            if let port { rebuilt += ":\(port)" }
            rebuilt += path
            if !query.isEmpty {
                rebuilt += "?" + query.map { item in
                    item.value.map { "\(item.name)=\($0)" } ?? item.name
                }.joined(separator: "&")
            }
            if let fragment { rebuilt += "#" + fragment }

            return URLParts(scheme: scheme, host: host, port: port, path: path, query: query,
                            fragment: fragment, raw: word,
                            string: word.containsVariable ? text : rebuilt)
        }
    }

    public var prefix: [ShellWord]
    /// `nil` means curl's own default, which depends on the body -- see `effectiveMethod`. Kept
    /// verbatim rather than upper-cased, because curl sends `-X post` as `post`.
    public var method: String?
    public var head: Bool
    public var get: Bool
    public var url: URLParts
    public var headers: [Header]
    public var body: Body?
    public var auth: Auth
    public var flags: Flags
    public var output: Output
    public var timing: Timing
    public var cookies: Cookies
    public var other: [Other]
    /// Everything from the first top-level `|`, `||`, `&&` or `;` onward, re-quoted so it can be
    /// appended to a rebuilt command line unchanged. `""` when the command stands alone.
    public var trailingPipeline: String

    public init(
        prefix: [ShellWord] = [],
        method: String? = nil,
        head: Bool = false,
        get: Bool = false,
        url: URLParts,
        headers: [Header] = [],
        body: Body? = nil,
        auth: Auth = .none,
        flags: Flags = [],
        output: Output = Output(),
        timing: Timing = Timing(),
        cookies: Cookies = Cookies(),
        other: [Other] = [],
        trailingPipeline: String = ""
    ) {
        self.prefix = prefix
        self.method = method
        self.head = head
        self.get = get
        self.url = url
        self.headers = headers
        self.body = body
        self.auth = auth
        self.flags = flags
        self.output = output
        self.timing = timing
        self.cookies = cookies
        self.other = other
        self.trailingPipeline = trailingPipeline
    }

    /// The method curl would actually send: an explicit `-X` wins, then `-I`, then a body makes it
    /// a POST -- unless `-G`, which turns the data into a query string and keeps the GET.
    public var effectiveMethod: String {
        if let method { return method }
        if head { return "HEAD" }
        if body == nil || get { return "GET" }
        return "POST"
    }

    /// Parses one shell line. Returns `nil` when the line has an unterminated quote, when the first
    /// command on it is not `curl` (a `curl` further down a pipeline is reading somebody else's
    /// output, not making the request this line is about), or when no URL is given.
    public static func parse(_ line: String) -> CurlCommand? {
        guard let words = ShellWords.split(line) else { return nil }

        var index = 0
        var prefix: [ShellWord] = []
        while index < words.count, isPrefixWord(words[index]) {
            prefix.append(words[index])
            index += 1
        }
        guard index < words.count, isCurl(words[index]) else { return nil }
        index += 1

        var state = ParseState()
        var urls: [ShellWord] = []
        var optionsEnded = false
        // Where the shell tail begins. Found inside this loop rather than by scanning the words up
        // front, because a value a preceding option has already claimed is not an operator:
        // `curl -d '>' https://x` sends a `>` as its body, and quoting is gone by this point.
        var tailStart = words.count

        while index < words.count {
            let word = words[index]
            if isTailOperator(word) {
                tailStart = index
                break
            }
            index += 1

            guard !optionsEnded, let lead = leadingText(word), lead.hasPrefix("-"), lead != "-" else {
                urls.append(word)
                continue
            }
            if lead == "--" && word.pieces.count == 1 {
                optionsEnded = true
                continue
            }

            // Hands the option the word after it, when there is one. `requireBare` is the guard
            // the passthrough options need: an unmodelled option must not swallow the next `-x`,
            // because unlike a modelled one there is no evidence here that it takes a value.
            func nextWord(requireBare: Bool) -> ShellWord? {
                guard index < words.count else { return nil }
                if requireBare, let next = leadingText(words[index]), next.hasPrefix("-") { return nil }
                let taken = words[index]
                index += 1
                return taken
            }

            if lead.hasPrefix("--") {
                let split = splitWord(word, atFirstOf: ["="])
                let name = split?.left ?? word.text
                let inline = split?.right
                if inline != nil, !takesValue(name) {
                    // `--silent=1`: there is nowhere to put the `1`, and dropping it would rebuild
                    // a line the user did not write. The whole spelling goes to `other` instead --
                    // including the flag itself, so it is represented once rather than twice.
                    state.command.other.append(.init(option: word.text, value: nil))
                    continue
                }
                apply(option: name, inline: inline, next: nextWord, to: &state, urls: &urls)
                continue
            }

            // A short group: every leading boolean letter is consumed, and the first letter that
            // wants a value takes the rest of the word if there is one and the next word otherwise
            // -- which is what makes both `-sSL` and `-sH 'A: b'` mean what curl means by them.
            let scalars = Array(lead.unicodeScalars)
            var at = 1
            while at < scalars.count {
                let name = "-\(scalars[at])"
                if !takesValue(name) {
                    apply(option: name, inline: nil, next: { _ in nil }, to: &state, urls: &urls)
                    at += 1
                    continue
                }
                let attached = word.droppingLeadingScalars(at + 1)
                apply(option: name, inline: attached, next: nextWord, to: &state, urls: &urls)
                break
            }
        }

        guard !urls.isEmpty else { return nil }
        var command = state.command
        command.prefix = prefix
        command.url = URLParts.parse(urls[0])
        command.other.append(contentsOf: urls.dropFirst().map { Other(option: "", value: $0) })
        command.trailingPipeline = joinPipeline(Array(words[tailStart...]))
        return command
    }
}

// MARK: - The option table

/// What the parser does with one option spelling. `passthroughFlag` / `passthroughValue` are the
/// options curl knows and this model does not model: they are copied into `other` verbatim, and
/// listing them here rather than in a side set is what stops `--resolve x:443:1.2.3.4` from being
/// read as an option followed by a URL.
private enum OptionKind {
    case flag(CurlCommand.Flags)
    case boolean(WritableKeyPath<ParseState, Bool>)
    case value((inout ParseState, ShellWord) -> Void)
    case passthroughFlag
    case passthroughValue
}

/// The command under construction plus the URL word, which is not a field of `CurlCommand` while
/// parsing because `--url` and a bare word feed the same list and only the first one wins.
private struct ParseState {
    var command = CurlCommand(url: CurlCommand.URLParts.parse(ShellWord("")))
    var urlWords: [ShellWord] = []
}

private let table: [String: OptionKind] = {
    var t: [String: OptionKind] = [:]

    func put(_ names: [String], _ kind: OptionKind) {
        for name in names { t[name] = kind }
    }

    put(["-X", "--request"], .value { $0.command.method = $1.text })
    put(["-G", "--get"], .boolean(\ParseState.command.get))
    put(["-I", "--head"], .boolean(\ParseState.command.head))
    put(["--url"], .value { $0.urlWords.append($1) })
    put(["-H", "--header"], .value { $0.addHeader($1) })

    put(["-d", "--data", "--data-ascii"], .value { $0.appendData($1) })
    put(["--data-raw"], .value { $0.command.body = .raw($1) })
    put(["--data-binary"], .value { $0.command.body = .binary($1) })
    put(["--data-urlencode"], .value { $0.appendURLEncoded($1) })
    put(["--json"], .value { $0.command.body = .json($1) })
    put(["-F", "--form"], .value { $0.appendForm($1) })
    put(["-T", "--upload-file"], .value { $0.command.body = .upload($1) })

    put(["-u", "--user"], .value { $0.setBasicAuth($1) })
    put(["--oauth2-bearer"], .value { $0.command.auth = .bearer($1) })

    put(["-i", "--include"], .flag(.include))
    put(["-s", "--silent"], .flag(.silent))
    put(["-S", "--show-error"], .flag(.showError))
    put(["-L", "--location"], .flag(.location))
    put(["-k", "--insecure"], .flag(.insecure))
    put(["--compressed"], .flag(.compressed))
    put(["-v", "--verbose"], .flag(.verbose))
    put(["-f", "--fail"], .flag(.fail))
    put(["-N", "--no-buffer"], .flag(.noBuffer))

    put(["-o", "--output"], .value { $0.command.output.file = $1 })
    put(["-O", "--remote-name"], .boolean(\ParseState.command.output.remoteName))
    put(["-D", "--dump-header"], .value { $0.command.output.dumpHeaders = $1 })
    put(["-w", "--write-out"], .value { $0.command.output.writeOut = $1 })

    put(["-m", "--max-time"], .value { $0.setDouble($1, "--max-time", \ParseState.command.timing.maxTime) })
    put(["--connect-timeout"], .value { $0.setDouble($1, "--connect-timeout", \ParseState.command.timing.connectTimeout) })
    put(["--retry-delay"], .value { $0.setDouble($1, "--retry-delay", \ParseState.command.timing.retryDelay) })
    put(["--retry"], .value { state, word in
        if let n = Int(word.text) {
            state.command.timing.retry = n
        } else {
            state.command.other.append(.init(option: "--retry", value: word))
        }
    })

    put(["-b", "--cookie"], .value { $0.command.cookies.send = $1 })
    put(["-c", "--cookie-jar"], .value { $0.command.cookies.jar = $1 })

    // Known to curl, not modelled here: kept in `other` so the command still round-trips.
    put([
        "-x", "--proxy", "-A", "--user-agent", "-e", "--referer", "--resolve", "--cacert",
        "--cert", "--key", "-E", "--interface", "--proto", "--ciphers", "--unix-socket",
        "--abstract-unix-socket", "-r", "--range", "-C", "--continue-at", "-z", "--time-cond",
        "--limit-rate", "--max-redirs", "--retry-max-time", "--keepalive-time", "--local-port",
        "--dns-servers", "--request-target", "--aws-sigv4", "--netrc-file", "--socks5",
        "--socks5-hostname", "--proxy-user", "-U", "--noproxy", "--alt-svc", "--etag-save",
        "--etag-compare",
    ], .passthroughValue)

    put([
        "--http1.1", "--http2", "--http3", "-4", "-6", "--path-as-is", "--tlsv1.2", "--tlsv1.3",
        "--tcp-nodelay", "--tr-encoding", "--ipv4", "--ipv6", "-n", "--netrc", "--ssl",
        "--ssl-reqd", "--anyauth", "--ntlm", "--negotiate", "--no-keepalive", "--disable", "-q",
        "--globoff", "-g", "--raw", "--junk-session-cookies", "-j", "--create-dirs", "--parallel",
        "-Z", "--basic", "--digest",
    ], .passthroughFlag)

    return t
}()

/// Whether this spelling takes an argument. An option not in the table counts as taking one only
/// when it is written `--opt=value`, which is handled by the caller: guessing that an unknown
/// `--opt` takes the next word is what would turn a URL into an option's value.
private func takesValue(_ option: String) -> Bool {
    switch table[option] {
    case .value, .passthroughValue: return true
    default: return false
    }
}

/// Applies one option. `next` is called only by the kinds that want a value, so a boolean never
/// swallows the word after it.
private func apply(
    option: String,
    inline: ShellWord?,
    next: (Bool) -> ShellWord?,
    to state: inout ParseState,
    urls: inout [ShellWord]
) {
    switch table[option] {
    case .flag(let flag):
        state.command.flags.insert(flag)

    case .boolean(let keyPath):
        state[keyPath: keyPath] = true

    case .value(let handler):
        guard let value = inline ?? next(false) else {
            state.command.other.append(.init(option: option, value: nil))
            return
        }
        handler(&state, value)
        // `--url` feeds the same list a bare URL word does, and the first entry wins.
        urls.append(contentsOf: state.urlWords)
        state.urlWords = []

    case .passthroughFlag:
        state.command.other.append(.init(option: option, value: inline))

    case .passthroughValue:
        state.command.other.append(.init(option: option, value: inline ?? next(true)))

    case nil:
        // Not an option curl has: keep the spelling and any attached value, take nothing else.
        state.command.other.append(.init(option: option, value: inline))
    }
}

// MARK: - Field handlers

extension ParseState {
    mutating func setDouble(_ word: ShellWord, _ spelling: String, _ keyPath: WritableKeyPath<ParseState, Double?>) {
        if let value = Double(word.text) {
            self[keyPath: keyPath] = value
        } else {
            // Dropping it would leave the workbench showing a request that is not the one on screen.
            command.other.append(.init(option: spelling, value: word))
        }
    }

    mutating func addHeader(_ word: ShellWord) {
        guard let split = splitWord(word, atFirstOf: [":", ";"]) else {
            // No separator, so there is no name to key it by -- `-H "$AUTH_HEADER"` is the real
            // case. `other` keeps the word intact, which is what a rebuild needs.
            command.other.append(.init(option: "-H", value: word))
            return
        }
        let value = split.right.trimmingLeadingSpaces()
        if split.separator == ";" {
            command.headers.append(.init(name: split.left, value: ShellWord(""), removes: false))
            return
        }
        if value.pieces.count == 1, value.text.isEmpty {
            command.headers.append(.init(name: split.left, value: ShellWord(""), removes: true))
            return
        }
        if split.left.lowercased() == "authorization" {
            if let token = value.droppingPrefix("Bearer ") {
                command.auth = .bearer(token)
            } else {
                command.auth = .header(value)
            }
            return
        }
        command.headers.append(.init(name: split.left, value: value, removes: false))
    }

    mutating func appendData(_ word: ShellWord) {
        if case .data(let existing) = command.body {
            command.body = .data(existing + [word])
        } else {
            command.body = .data([word])
        }
    }

    mutating func appendURLEncoded(_ word: ShellWord) {
        if case .urlencoded(let existing) = command.body {
            command.body = .urlencoded(existing + [word])
        } else {
            command.body = .urlencoded([word])
        }
    }

    mutating func appendForm(_ word: ShellWord) {
        let item: CurlCommand.FormItem
        if let split = splitWord(word, atFirstOf: ["="]) {
            item = .init(name: split.left, value: split.right)
        } else {
            item = .init(name: word.text, value: ShellWord(""))
        }
        if case .form(let existing) = command.body {
            command.body = .form(existing + [item])
        } else {
            command.body = .form([item])
        }
    }

    mutating func setBasicAuth(_ word: ShellWord) {
        if let split = splitWord(word, atFirstOf: [":"]) {
            command.auth = .basic(user: split.left, password: split.right)
        } else {
            command.auth = .basic(user: word.text, password: nil)
        }
    }
}

// MARK: - Word helpers

/// The literal text a word starts with, or `nil` when it starts with a variable -- which is how
/// `$FLAGS` avoids being read as an option even if it expands to one.
private func leadingText(_ word: ShellWord) -> String? {
    if case .text(let t)? = word.pieces.first { return t }
    return nil
}

/// Splits at the first separator that falls inside a literal piece. Variables before it are folded
/// into `left` by their spelling; a variable can never *be* the separator, which is why
/// `-H "Authorization: Bearer $TOKEN"` splits at the colon and keeps `$TOKEN` a variable.
private func splitWord(_ word: ShellWord, atFirstOf separators: Set<Unicode.Scalar>) -> (left: String, separator: Unicode.Scalar, right: ShellWord)? {
    var left = ""
    for (index, piece) in word.pieces.enumerated() {
        switch piece {
        case .variable(let spelling):
            left += spelling
        case .text(let text):
            let scalars = Array(text.unicodeScalars)
            guard let hit = scalars.firstIndex(where: { separators.contains($0) }) else {
                left += text
                continue
            }
            left += String(String.UnicodeScalarView(scalars[..<hit]))
            var rest: [ShellWord.Piece] = []
            let tail = String(String.UnicodeScalarView(scalars[(hit + 1)...]))
            if !tail.isEmpty { rest.append(.text(tail)) }
            rest.append(contentsOf: word.pieces[(index + 1)...])
            // A separator at the very end leaves nothing: `ShellWord.init(pieces:)` spells that
            // as the one empty word, so `-u user:` gives an empty password rather than no word.
            return (left, scalars[hit], ShellWord(pieces: rest))
        }
    }
    return nil
}

private extension ShellWord {
    /// The word with its first `count` scalars removed, or `nil` when nothing is left -- the test
    /// a short option applies to decide between `-Hvalue` and `-H value`. A word whose literal
    /// prefix is exhausted but which still carries a variable counts as non-empty, so
    /// `-H"Auth: $T"` keeps its value attached.
    func droppingLeadingScalars(_ count: Int) -> ShellWord? {
        var remaining = count
        var kept: [Piece] = []
        for piece in pieces {
            guard remaining > 0 else {
                kept.append(piece)
                continue
            }
            guard case .text(let text) = piece else {
                kept.append(piece)
                remaining = 0
                continue
            }
            let scalars = Array(text.unicodeScalars)
            if scalars.count <= remaining {
                remaining -= scalars.count
            } else {
                kept.append(.text(String(String.UnicodeScalarView(scalars[remaining...]))))
                remaining = 0
            }
        }
        return kept.isEmpty ? nil : ShellWord(pieces: kept)
    }

    /// Drops a case-insensitive literal prefix (`Bearer `), or `nil` when it is not there.
    func droppingPrefix(_ prefix: String) -> ShellWord? {
        guard case .text(let text)? = pieces.first else { return nil }
        let scalars = Array(text.unicodeScalars)
        let wanted = Array(prefix.unicodeScalars)
        guard scalars.count >= wanted.count else { return nil }
        for i in wanted.indices where !sameIgnoringCase(scalars[i], wanted[i]) { return nil }
        var kept: [Piece] = []
        let tail = String(String.UnicodeScalarView(scalars[wanted.count...]))
        if !tail.isEmpty { kept.append(.text(tail)) }
        kept.append(contentsOf: pieces.dropFirst())
        return ShellWord(pieces: kept)
    }

    /// Removes the space curl allows after a header's colon, without touching a later piece.
    func trimmingLeadingSpaces() -> ShellWord {
        guard case .text(let text)? = pieces.first else { return self }
        var scalars = Substring(text)
        while let first = scalars.first, first == " " || first == "\t" { scalars = scalars.dropFirst() }
        var kept: [Piece] = []
        if !scalars.isEmpty { kept.append(.text(String(scalars))) }
        kept.append(contentsOf: pieces.dropFirst())
        return ShellWord(pieces: kept)
    }
}

private func sameIgnoringCase(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
    a == b || String(a).lowercased() == String(b).lowercased()
}

// MARK: - Prefix and pipeline

/// `FOO=bar`, `sudo`, `env`, `time` and friends can stand in front of `curl` without changing which
/// request is being made, so they are kept verbatim rather than ending the parse.
private func isPrefixWord(_ word: ShellWord) -> Bool {
    guard let lead = leadingText(word), !word.containsVariable else { return false }
    if ["sudo", "doas", "env", "time", "command", "nice", "nohup"].contains(lead) { return true }
    let scalars = Array(lead.unicodeScalars)
    guard let equals = scalars.firstIndex(of: "="), equals > 0 else { return false }
    let name = scalars[..<equals]
    guard let first = name.first, isNameStart(first) else { return false }
    return name.allSatisfy { isNameStart($0) || isDigit($0) }
}

private func isNameStart(_ s: Unicode.Scalar) -> Bool {
    s == "_"
        || (("A" as Unicode.Scalar) ... ("Z" as Unicode.Scalar)).contains(s)
        || (("a" as Unicode.Scalar) ... ("z" as Unicode.Scalar)).contains(s)
}

private func isDigit(_ s: Unicode.Scalar) -> Bool {
    (("0" as Unicode.Scalar) ... ("9" as Unicode.Scalar)).contains(s)
}

/// Accepts `curl` and a path to it (`/usr/bin/curl`), and nothing else.
private func isCurl(_ word: ShellWord) -> Bool {
    guard !word.containsVariable else { return false }
    let text = word.text
    return text == "curl" || text.hasSuffix("/curl")
}

/// A shell operator word: the thing that ends the curl command and starts whatever its output --
/// or its exit status -- is handed to. Both jobs use this one predicate, so anything that can
/// begin the tail is also written back out unquoted, and the tail round-trips by construction.
///
/// Recognized: `|`, `||`, `&&`, `;`, a trailing `&`, and the redirections `>` `>>` `<` `<<` with an
/// optional leading file descriptor (`2>`) or `&` (`&>`, `&>>`) and an optional `&N` / `&-` target
/// (`2>&1`, `1>&-`). A redirection only counts when the whole word is one -- `>out.json` written
/// without a space is a single word to the tokenizer and stays an argument, which is a known gap.
private func isTailOperator(_ word: ShellWord) -> Bool {
    guard !word.containsVariable else { return false }
    let text = word.text
    if ["|", "||", "&&", ";", "&"].contains(text) { return true }

    let scalars = Array(text.unicodeScalars)
    var i = 0
    if i < scalars.count, scalars[i] == "&" {
        i += 1                                      // `&>` / `&>>`: stdout and stderr together
    } else {
        while i < scalars.count, isDigit(scalars[i]) { i += 1 }   // an explicit file descriptor
    }
    guard i < scalars.count, scalars[i] == ">" || scalars[i] == "<" else { return false }
    let arrow = scalars[i]
    i += 1
    if i < scalars.count, scalars[i] == arrow { i += 1 }          // `>>` append, `<<` heredoc
    if i < scalars.count, scalars[i] == "&" {                     // duplicate onto another fd
        i += 1
        if i < scalars.count, scalars[i] == "-" { return i + 1 == scalars.count }
        guard i < scalars.count else { return false }
        while i < scalars.count, isDigit(scalars[i]) { i += 1 }
    }
    return i == scalars.count
}

/// Re-joins the tail so it can be appended to a rebuilt command line. Operator words are written
/// through unquoted -- `ShellWords.quote` would turn `|` into `'|'`, an argument rather than a
/// pipe, and the line would stop meaning what it meant -- while everything else is quoted as the
/// argument it is.
private func joinPipeline(_ words: [ShellWord]) -> String {
    words.map { isTailOperator($0) ? $0.text : ShellWords.quote($0) }.joined(separator: " ")
}
