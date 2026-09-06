import Foundation

/// One HTTP request's answer, read back out of what curl printed into the terminal.
///
/// Nyx does not make the request itself and does not parse a network stream: the user's own shell
/// ran their own curl, and this is a reading of the rows that came back. That is the whole design
/// -- the command in the block is exactly what they typed (plus `RequestRun`'s visible flags), so
/// anything shown about it has to be recoverable from its transcript. Nothing here can fail in a
/// way that loses output: a transcript this cannot make sense of simply has no exchange, and the
/// block keeps its ordinary exit-status summary.
public struct HTTPExchange: Equatable {
    /// A header as it arrived. A struct rather than a tuple because a tuple is not `Equatable`, and
    /// the header this feeds compares whole values to decide whether to redraw.
    public struct Header: Equatable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name; self.value = value
        }
    }

    /// One status line and the headers under it.
    public struct Head: Equatable {
        /// What follows `HTTP/`: `1.1`, or `2` -- HTTP/2 has no minor version and no reason phrase.
        public var version: String
        public var status: Int
        /// Empty for HTTP/2, which abolished the reason phrase.
        public var reason: String
        public var headers: [Header]

        public init(version: String, status: Int, reason: String, headers: [Header]) {
            self.version = version; self.status = status; self.reason = reason; self.headers = headers
        }

        /// The first header of that name, case-insensitively -- HTTP/1.1 sends `Content-Type` and
        /// HTTP/2 sends `content-type`, and a lens that matched only one of them would work against
        /// half the internet.
        public func value(of name: String) -> String? {
            headers.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }?.value
        }
    }

    /// What the body is, which is what decides whether it is worth pretty-printing, worth showing
    /// at all, or something a terminal must not be asked to display.
    public enum BodyKind: Equatable { case json, text, binary, empty }

    /// The nine values `RequestRun.writeOutArgument` asks curl for. Every field is present or the
    /// whole sentinel is rejected: curl writes all nine or none, so an optional here would only
    /// ever mean "this parser gave up half way", which is not a state worth carrying into the UI.
    public struct Timing: Equatable {
        /// `%{http_code}`. `0` when curl never got a response at all -- see `HTTPExchange.status`.
        public var status: Int
        public var total: Double
        public var nameLookup: Double
        public var connect: Double
        public var appConnect: Double
        public var startTransfer: Double
        public var sizeDownload: Int
        public var numRedirects: Int
        /// May be empty (a 204 has no content type), and may contain spaces (`text/html;
        /// charset=utf-8`), which is why it is last in the sentinel.
        public var contentType: String

        public init(status: Int, total: Double, nameLookup: Double, connect: Double,
                    appConnect: Double, startTransfer: Double, sizeDownload: Int,
                    numRedirects: Int, contentType: String) {
            self.status = status; self.total = total; self.nameLookup = nameLookup
            self.connect = connect; self.appConnect = appConnect; self.startTransfer = startTransfer
            self.sizeDownload = sizeDownload; self.numRedirects = numRedirects
            self.contentType = contentType
        }
    }

    /// Every head before the last one: what `-L` followed. Kept rather than discarded because "why
    /// did this take 900 ms" is usually "it went through three hops".
    public var redirects: [Head]
    /// The response proper. nil when curl printed no headers at all -- `-o file`, or a command that
    /// already had its own `-w` and no `-i`.
    public var final: Head?
    /// The body, trailing blank rows dropped.
    public var bodyLines: [String]
    public var bodyKind: BodyKind
    public var timing: Timing?

    public init(redirects: [Head], final: Head?, bodyLines: [String], bodyKind: BodyKind,
                timing: Timing?) {
        self.redirects = redirects; self.final = final; self.bodyLines = bodyLines
        self.bodyKind = bodyKind; self.timing = timing
    }

    /// The status to show, from the headers when they are there and from the sentinel when they are
    /// not.
    ///
    /// A sentinel `http_code` of `000` is curl saying it never got a response -- DNS failed, the
    /// connection was refused, the handshake broke. Reporting that as status 0 puts a code in the
    /// header that no one can look up; the exit status is what says what happened, so this returns
    /// nil and lets `HTTPSummary` fall through to it.
    public var status: Int? {
        if let final { return final.status }
        guard let timing, timing.status != 0 else { return nil }
        return timing.status
    }

    /// The response's content type, from the headers first and the sentinel second. The sentinel's
    /// is curl's own `%{content_type}`, which is present even when `-i` was not.
    public var contentType: String? {
        if let fromHead = final?.value(of: "Content-Type") { return fromHead }
        guard let type = timing?.contentType, !type.isEmpty else { return nil }
        return type
    }

    /// The content type, but only when it describes the text *on screen*.
    ///
    /// With no head and nothing downloaded, curl sent the body somewhere else -- a file, `/dev/null`
    /// -- and whatever is in the block is curl's or the shell's own words. `curl -o /nowhere/x`
    /// prints `curl: (56) Failure writing output …` and a sentinel saying `application/json`, and
    /// labelling that error line as JSON put ` · json` in the header of a request that delivered
    /// nothing. A head means the response came to the terminal; a non-zero `size_download` means
    /// something was downloaded to it.
    private var contentTypeOfWhatIsOnScreen: String? {
        guard final != nil || (timing?.sizeDownload ?? 0) > 0 else { return nil }
        return contentType
    }

    /// What a non-zero curl exit code means, in the words a user can act on.
    ///
    /// Only the codes that name a *cause*. "exit 22" (an HTTP error under `-f`) is deliberately
    /// absent: the head is on screen and says 404 already, and a second sentence for it would be
    /// the same news twice. nil means the code is shown on its own.
    public static func curlFailureReason(exitStatus: Int32) -> String? {
        switch exitStatus {
        case 6: return "could not resolve host"
        case 7: return "connection refused"
        case 28: return "timed out"
        case 35: return "TLS handshake failed"
        case 52: return "empty reply"
        case 56: return "connection reset"
        case 60: return "certificate not trusted"
        default: return nil
        }
    }

    /// Reads a curl transcript. nil when there is neither a status line nor a sentinel in it, which
    /// is every non-HTTP thing a block can hold.
    ///
    /// `lines` are the block's output rows as the grid holds them: no carriage returns (the
    /// terminal consumed those) and no trailing spaces (`Terminal.outputText` trims them), which is
    /// exactly why the sentinel parser cannot require a trailing space before an empty content
    /// type.
    public static func parse(lines: [String]) -> HTTPExchange? {
        // Whether curl's own chatter is being stripped is decided once, from the whole transcript,
        // rather than per line. A `-v` run marks its response headers with `< `, so a `< HTTP/…`
        // row anywhere is proof; without that proof a row starting with `* ` is the user's Markdown
        // body, not curl talking, and eating it would lose the response.
        let verbose = lines.contains { isMarker($0, "<") && isHeadLine(strippingVerbosePrefix($0)) }

        var heads: [Head] = []
        var current: Head?
        /// A `1xx` head is an interim answer: its headers are consumed and thrown away, so they
        /// cannot be attributed to the response that follows.
        var skippingInterim = false
        var inHeaders = false
        var sawHead = false
        var body: [String] = []
        var timing: Timing?

        for raw in lines {
            var line = raw
            while line.hasSuffix("\r") { line.removeLast() }

            if let parsed = parseSentinel(line) {
                timing = parsed
                continue
            }

            // Whether the response's *body* has started yet. Everything before that is either the
            // prologue (curl or the shell talking before the first status line), a set of headers,
            // or the gap between a redirect and what it pointed at -- and both of the rules below
            // turn on being in one of those rather than in the body.
            let beforeTheBody = !sawHead || inHeaders || body.isEmpty

            if verbose && beforeTheBody {
                // `* ` is curl's connection log and `> ` is the request it sent; neither is the
                // response. `< ` marks a response header, and what follows it is one.
                //
                // The *space* is what makes a marker a marker. `<html></html>` is a body line that
                // begins with `<`, and stripping one character off it because the transcript is
                // verbose turned the response into `html></html>`.
                //
                // Only before the body: inside one, `* ` is a Markdown bullet and `> ` is a quote,
                // and dropping those loses the response. The price is curl's closing `* Connection
                // #0 … left intact`, which stays in the body -- a visible extra line, against a
                // silently missing one.
                if isMarker(line, "*") || isMarker(line, ">") { continue }
                if isMarker(line, "<") { line = String(line.dropFirst(min(2, line.count))) }
            }

            // A status line is only a head where one can legally be: before the first, or in the
            // gap between a head and the body it never produced (a redirect chain, a `100
            // Continue`). Once the body has a line in it, `HTTP/1.1 503 Service Unavailable` is
            // text -- an RFC, a server log, a proxy transcript -- and believing it replaced the
            // real status with a quoted one and dropped everything that had been read so far.
            if beforeTheBody, let head = parseHead(line) {
                if let current, !skippingInterim { heads.append(current) }
                skippingInterim = (100..<200).contains(head.status)
                current = skippingInterim ? nil : head
                inHeaders = true
                sawHead = true
                // A redirect's own body belongs to the redirect, not to what it pointed at. (Empty
                // already in every case that reaches here except the prologue, which is not body.)
                body.removeAll(keepingCapacity: true)
                continue
            }

            if inHeaders {
                if line.isEmpty {
                    inHeaders = false
                    if let head = current { heads.append(head) }
                    current = nil
                    skippingInterim = false
                    continue
                }
                if !skippingInterim, let colon = line.firstIndex(of: ":") {
                    let name = String(line[line.startIndex..<colon])
                    let value = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    current?.headers.append(Header(name: name, value: value))
                }
                continue
            }

            body.append(line)
        }
        // A transcript cut off inside the headers still has a status worth showing.
        if let current, !skippingInterim { heads.append(current) }

        guard !heads.isEmpty || timing != nil else { return nil }

        // The `-w` argument begins with a newline so the sentinel always starts a row of its own;
        // a body that ended in a newline therefore leaves one blank row in front of it, which is
        // Nyx's doing and not the server's.
        while body.last?.isEmpty == true { body.removeLast() }

        // Built with a placeholder kind so `contentType` -- which reads the head and the sentinel
        // by one rule -- is the thing that answers what the body is, rather than a second copy of
        // that rule here.
        var exchange = HTTPExchange(redirects: Array(heads.dropLast()), final: heads.last,
                                    bodyLines: body, bodyKind: .empty, timing: timing)
        exchange.bodyKind = bodyKind(of: body, contentType: exchange.contentTypeOfWhatIsOnScreen)
        return exchange
    }

    /// `HTTP/2 200`, `HTTP/1.1 404 Not Found`. Hand-written rather than a regular expression: this
    /// runs over every row of every curl block, and `NSRegularExpression` compiles a pattern and
    /// allocates a match object to answer a question three character comparisons settle.
    static func parseHead(_ line: String) -> Head? {
        guard line.hasPrefix("HTTP/") else { return nil }
        let rest = line.dropFirst("HTTP/".count)
        guard let afterVersion = rest.firstIndex(of: " ") else { return nil }
        let version = rest[rest.startIndex..<afterVersion]
        guard !version.isEmpty, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let tail = rest[rest.index(after: afterVersion)...]
        let afterCode = tail.firstIndex(of: " ") ?? tail.endIndex
        let code = tail[tail.startIndex..<afterCode]
        guard code.count == 3, let status = Int(code), code.allSatisfy(\.isNumber) else { return nil }
        let reason = afterCode == tail.endIndex
            ? ""
            : String(tail[tail.index(after: afterCode)...]).trimmingCharacters(in: .whitespaces)
        return Head(version: String(version), status: status, reason: reason, headers: [])
    }

    private static func isHeadLine(_ line: String) -> Bool { parseHead(line) != nil }

    /// Whether a line is one of curl's `-v` markers: the character followed by a space, or the
    /// character alone (which is how it writes the blank line ending the headers).
    private static func isMarker(_ line: String, _ marker: Character) -> Bool {
        line == String(marker) || line.hasPrefix("\(marker) ")
    }

    /// The `< ` a `-v` transcript puts in front of a response header, removed -- used only to ask
    /// whether the transcript is verbose in the first place.
    private static func strippingVerbosePrefix(_ line: String) -> String {
        guard isMarker(line, "<") else { return line }
        return String(line.dropFirst(min(2, line.count)))
    }

    /// The prefix, then `http_code time_total time_namelookup time_connect time_appconnect
    /// time_starttransfer size_download num_redirects`, then the content type to the end of the
    /// line. Eight fields split on single spaces and a ninth that is whatever is left, because the
    /// content type is the one value that can itself contain a space.
    ///
    /// Anything that does not parse cleanly is not a sentinel. A body can print anything at all,
    /// including this prefix, and a half-believed sentinel would put an invented status and latency
    /// in the block's header -- worse than no summary.
    static func parseSentinel(_ line: String) -> Timing? {
        guard line.hasPrefix(RequestRun.sentinelPrefix) else { return nil }
        var remainder = line.dropFirst(RequestRun.sentinelPrefix.count)
        var fields: [Substring] = []
        while fields.count < 8 {
            guard let space = remainder.firstIndex(of: " ") else {
                // The eighth field may end the line: an empty content type leaves a trailing space
                // that the grid trims away before this ever sees it.
                fields.append(remainder)
                remainder = remainder[remainder.endIndex...]
                break
            }
            fields.append(remainder[remainder.startIndex..<space])
            remainder = remainder[remainder.index(after: space)...]
        }
        guard fields.count == 8,
              let status = Int(fields[0]),
              let total = Double(fields[1]),
              let nameLookup = Double(fields[2]),
              let connect = Double(fields[3]),
              let appConnect = Double(fields[4]),
              let startTransfer = Double(fields[5]),
              let size = Int(fields[6]),
              let redirects = Int(fields[7]) else { return nil }
        return Timing(status: status, total: total, nameLookup: nameLookup, connect: connect,
                      appConnect: appConnect, startTransfer: startTransfer, sizeDownload: size,
                      numRedirects: redirects, contentType: String(remainder))
    }

    /// Empty first, then binary, then JSON.
    ///
    /// Binary outranks the content type on purpose: a server that mislabels a PNG as JSON is common
    /// and the consequence of believing it is a pretty-printer fed control bytes. The content type
    /// alone is enough for `.json` after that -- a truncated or streaming JSON body is still JSON,
    /// and refusing to say so because `JSONSerialization` cannot finish it would hide the one fact
    /// the user wanted.
    static func bodyKind(of lines: [String], contentType: String?) -> BodyKind {
        let joined = lines.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if isBinary(joined) { return .binary }
        if let contentType, contentType.range(of: "json", options: .caseInsensitive) != nil { return .json }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
                return .json
            }
        }
        return .text
    }

    /// A NUL, or more than one scalar in twenty being a control character, in the first 4 KB.
    ///
    /// Sampled rather than measured whole: this runs on the frame path, and a 40 MB body answers
    /// the question in its first page exactly as well as in all of it.
    private static func isBinary(_ text: String) -> Bool {
        var seen = 0
        var suspicious = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 0 { return true }
            seen += 1
            // Tab and newline are how text is laid out; the other C0 codes and DEL are not.
            if (scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r")
                || scalar.value == 0x7f {
                suspicious += 1
            }
            if seen >= 4096 { break }
        }
        guard seen > 0 else { return false }
        return Double(suspicious) > Double(seen) * 0.05
    }
}
