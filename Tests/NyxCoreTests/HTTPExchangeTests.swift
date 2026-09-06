import Testing
@testable import NyxCore

/// A sentinel exactly as curl 8.7 writes it for `RequestRun.writeOutArgument`: the prefix, eight
/// numbers on single spaces, then the content type to the end of the line.
private func sentinel(status: Int = 200, total: Double = 0.142, size: Int = 1229,
                      redirects: Int = 0, type: String = "application/json") -> String {
    "\(RequestRun.sentinelPrefix)\(status) \(total) 0.003208 0.049189 0.106052 0.140538 \(size) \(redirects) \(type)"
}

@Test func plainJSON200() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/2 200",
        "content-type: application/json",
        "content-length: 24",
        "",
        "{\"ok\":true,\"name\":\"nyx\"}",
        "",
        sentinel(),
    ]))
    #expect(exchange.status == 200)
    #expect(exchange.bodyKind == .json)
    #expect(exchange.timing?.total == 0.142)
    #expect(exchange.timing?.sizeDownload == 1229)
    #expect(exchange.timing?.contentType == "application/json")
    #expect(exchange.redirects.isEmpty)
    // "HTTP/2 200" has no reason phrase at all -- HTTP/2 abolished it, and curl prints the line
    // exactly as the protocol gives it.
    #expect(exchange.final?.version == "2")
    #expect(exchange.final?.reason == "")
    #expect(exchange.final?.headers == [HTTPExchange.Header(name: "content-type", value: "application/json"),
                                        HTTPExchange.Header(name: "content-length", value: "24")])
    #expect(exchange.bodyLines == ["{\"ok\":true,\"name\":\"nyx\"}"])
}

@Test func redirectChain() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 301 Moved Permanently",
        "Location: https://example.com/",
        "",
        "HTTP/1.1 200 OK",
        "Content-Type: text/plain",
        "",
        "hello",
        "",
        sentinel(total: 0.3, size: 5, redirects: 1, type: "text/plain"),
    ]))
    #expect(exchange.redirects.count == 1)
    #expect(exchange.redirects.first?.status == 301)
    #expect(exchange.redirects.first?.reason == "Moved Permanently")
    #expect(exchange.final?.status == 200)
    #expect(exchange.status == 200)
    #expect(exchange.timing?.numRedirects == 1)
    // The 301's own (empty) body must not survive into the final response's.
    #expect(exchange.bodyLines == ["hello"])
    #expect(exchange.bodyKind == .text)
}

@Test func verboseMode() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "* Host example.com:443 was resolved.",
        "* Connected to example.com (93.184.216.34) port 443",
        "> GET / HTTP/2",
        "> Host: example.com",
        ">",
        "< HTTP/2 200",
        "< content-type: text/html",
        "<",
        "<html></html>",
        "* Connection #0 to host example.com left intact",
    ]))
    #expect(exchange.final?.status == 200)
    #expect(exchange.final?.headers.count == 1)
    // `<html></html>` keeps its first character: the marker is `< `, with the space, and stripping
    // a bare `<` turned the response into `html></html>`.
    //
    // curl's closing line stays in the body on purpose. Chatter is only stripped before the body
    // begins, because inside one a leading `* ` is a bullet and a leading `> ` is a quote -- an
    // extra visible line is a far smaller loss than a silently missing one.
    #expect(exchange.bodyLines == ["<html></html>",
                                   "* Connection #0 to host example.com left intact"])
    #expect(exchange.timing == nil)
}

/// A body line that begins with `* ` is only curl's own chatter in a transcript that is *actually*
/// verbose. A plain `curl -i` of a Markdown file prints bullet lists, and stripping those would eat
/// the response.
@Test func bulletsInABodyAreNotVerboseChatter() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 200 OK",
        "Content-Type: text/markdown",
        "",
        "* one",
        "* two",
    ]))
    #expect(exchange.bodyLines == ["* one", "* two"])
}

@Test func noSentinelStillParsesHead() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 404 Not Found",
        "Content-Type: text/plain",
        "",
        "nope",
    ]))
    #expect(exchange.status == 404)
    #expect(exchange.timing == nil)
}

/// A `-o file` curl prints nothing but the sentinel: no head, and still an exchange worth showing.
@Test func sentinelWithoutAHeadIsStillAnExchange() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [sentinel(status: 201)]))
    #expect(exchange.final == nil)
    #expect(exchange.status == 201)
    #expect(exchange.bodyKind == .empty)
}

@Test func noHeadNoSentinelIsNil() {
    #expect(HTTPExchange.parse(lines: ["hello", "world"]) == nil)
    #expect(HTTPExchange.parse(lines: []) == nil)
}

/// A `100 Continue` is an interim answer, not the response and not a redirect.
@Test func continueIsSkipped() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 100 Continue",
        "",
        "HTTP/1.1 201 Created",
        "Location: /things/1",
        "",
    ]))
    #expect(exchange.redirects.isEmpty)
    #expect(exchange.final?.status == 201)
    #expect(exchange.final?.headers.count == 1)
}

@Test func binaryBody() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 200 OK",
        "Content-Type: application/octet-stream",
        "",
        "\u{0}\u{1}\u{2}gibberish",
    ]))
    #expect(exchange.bodyKind == .binary)
}

@Test func emptyBody204() throws {
    // curl 8.7 writes an empty content type as nothing after `num_redirects`, and the terminal
    // right-trims the row, so the sentinel arrives with eight fields and no ninth.
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 204 No Content",
        "Date: Sun, 06 Sep 2026 05:35:54 GMT",
        "",
        "",
        "\(RequestRun.sentinelPrefix)204 0.011 0.001 0.002 0.003 0.010 0 0",
    ]))
    #expect(exchange.bodyKind == .empty)
    #expect(exchange.bodyLines.isEmpty)
    #expect(exchange.timing?.contentType == "")
    #expect(exchange.timing?.sizeDownload == 0)
    #expect(exchange.status == 204)
}

/// A body line that happens to start with the prefix but does not carry eight numbers is a body
/// line. Believing it would put a made-up status and latency in the header.
@Test func aMalformedSentinelIsBody() throws {
    let bogus = "\(RequestRun.sentinelPrefix)not a sentinel"
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 200 OK",
        "Content-Type: text/plain",
        "",
        bogus,
    ]))
    #expect(exchange.timing == nil)
    #expect(exchange.bodyLines == [bogus])
}

/// A `%{http_code}` of `000` means curl never got a response -- it is not a status to show.
@Test func aZeroCodeSentinelHasNoStatus() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "\(RequestRun.sentinelPrefix)000 0.012 0.011 0.000 0.000 0.000 0 0",
    ]))
    #expect(exchange.status == nil)
    #expect(exchange.timing?.status == 0)
}

@Test func failureReasons() {
    #expect(HTTPExchange.curlFailureReason(exitStatus: 6) == "could not resolve host")
    #expect(HTTPExchange.curlFailureReason(exitStatus: 7) == "connection refused")
    #expect(HTTPExchange.curlFailureReason(exitStatus: 28) == "timed out")
    #expect(HTTPExchange.curlFailureReason(exitStatus: 60) == "certificate not trusted")
    #expect(HTTPExchange.curlFailureReason(exitStatus: 99) == nil)
    #expect(HTTPExchange.curlFailureReason(exitStatus: 0) == nil)
}

/// The transcript a real request leaves in the grid: CRs already consumed by the terminal, the
/// lowercase header names HTTP/2 uses, and the blank row the `-w` argument's leading newline makes.
@Test func aRealHealthCheckTranscript() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/2 200",
        "alt-svc: h3=\":443\"; ma=2592000",
        "content-type: application/json",
        "date: Sun, 06 Sep 2026 05:35:54 GMT",
        "via: 1.1 Caddy",
        "content-length: 61",
        "",
        "{\"online\":0,\"pairings\":0,\"attachments\":0,\"dropped_binary\":0}",
        "",
        "--nyx-http-- 200 0.157325 0.003921 0.051385 0.108482 0.157108 61 0 application/json",
    ]))
    #expect(exchange.status == 200)
    #expect(exchange.bodyKind == .json)
    #expect(exchange.timing?.total == 0.157325)
    #expect(exchange.timing?.nameLookup == 0.003921)
    #expect(exchange.timing?.connect == 0.051385)
    #expect(exchange.timing?.appConnect == 0.108482)
    #expect(exchange.timing?.startTransfer == 0.157108)
    #expect(exchange.timing?.sizeDownload == 61)
}

/// A response body that quotes HTTP itself -- a log file, an RFC, a proxy's own transcript -- must
/// not have its quoted status line believed. `curl -i` of a server log turned `HTTP/1.1 503` in the
/// text into the response's status and threw the real body away.
@Test func aStatusLineInsideTheBodyIsNotAHead() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 200 OK",
        "Content-Type: text/plain",
        "",
        "line one",
        "HTTP/1.1 503 Service Unavailable",
        "x-fake: yes",
        "",
        "line two",
    ]))
    #expect(exchange.status == 200)
    #expect(exchange.redirects.isEmpty)
    #expect(exchange.bodyLines.count == 5)
    #expect(exchange.bodyLines == ["line one", "HTTP/1.1 503 Service Unavailable", "x-fake: yes",
                                   "", "line two"])
}

/// The same rule from the other side: a head *is* accepted straight after one whose body was empty,
/// which is what a redirect chain and a `100 Continue` both look like.
@Test func aHeadIsAcceptedWhileTheBodyIsStillEmpty() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "HTTP/1.1 302 Found",
        "Location: /next",
        "",
        "HTTP/1.1 302 Found",
        "Location: /last",
        "",
        "HTTP/1.1 200 OK",
        "",
        "done",
    ]))
    #expect(exchange.redirects.count == 2)
    #expect(exchange.status == 200)
    #expect(exchange.bodyLines == ["done"])
}

/// Anything printed before the first status line is curl's or the shell's, not the response: it
/// must not count as a body and lock the real head out.
@Test func chatterBeforeTheFirstHeadDoesNotBlockIt() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "Note: Unnecessary use of -X or --request, GET is already inferred.",
        "HTTP/1.1 200 OK",
        "",
        "body",
    ]))
    #expect(exchange.status == 200)
    #expect(exchange.bodyLines == ["body"])
}

/// `-v` chatter is stripped only while curl is still talking about the connection and the headers.
/// Once the body has started, a line beginning `* ` or `> ` is the *body's* -- a Markdown bullet, a
/// quoted mail, a diff -- and eating it loses the response.
@Test func verboseMarkersInsideABodyAreKept() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "* Connected to example.com (93.184.216.34) port 443",
        "> GET /notes.md HTTP/2",
        ">",
        "< HTTP/2 200",
        "< content-type: text/markdown",
        "<",
        "# Notes",
        "* one",
        "> quoted",
    ]))
    #expect(exchange.final?.status == 200)
    #expect(exchange.bodyLines == ["# Notes", "* one", "> quoted"])
}

/// `curl -o file` that could not write the file prints its own error to the terminal and the
/// sentinel says `application/json` -- about the body it sent to the file, not about the error text
/// on screen. Believing it labelled `curl: (56) Failure writing output` as JSON.
@Test func aContentTypeForABodyThatWentElsewhereDoesNotLabelWhatIsOnScreen() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "curl: (56) Failure writing output to destination, passed 61 returned 4294967295",
        "",
        "\(RequestRun.sentinelPrefix)200 0.155 0.003 0.049 0.106 0.150 0 0 application/json",
    ]))
    #expect(exchange.bodyKind == .text)
    #expect(exchange.status == 200)
}

/// The case that rule must not break: a plain `curl -w …` with no `-i` has no head either, and its
/// body *is* on screen -- `size_download` is what says which of the two this is.
@Test func aHeadlessBodyThatWasDownloadedKeepsItsContentType() throws {
    let exchange = try #require(HTTPExchange.parse(lines: [
        "{\"ok\":true}",
        "",
        "\(RequestRun.sentinelPrefix)200 0.155 0.003 0.049 0.106 0.150 11 0 application/json",
    ]))
    #expect(exchange.bodyKind == .json)
}
