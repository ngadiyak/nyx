import Testing
@testable import NyxCore

private func exchange(status: Int, total: Double, size: Int, type: String, body: String) -> HTTPExchange {
    let parsed = HTTPExchange.parse(lines: [
        "HTTP/2 \(status)",
        "content-type: \(type)",
        "",
        body,
        "",
        "\(RequestRun.sentinelPrefix)\(status) \(total) 0.003 0.049 0.106 \(total) \(size) 0 \(type)",
    ])
    return parsed!
}

@Test func success200() throws {
    let summary = try #require(HTTPSummary.make(exchange: exchange(status: 200, total: 0.142, size: 1229,
                                                                   type: "application/json",
                                                                   body: "{\"ok\":true}"),
                                                exitStatus: 0, duration: 0.2))
    #expect(summary.text == "200 \u{b7} 142 ms \u{b7} 1.2 KB \u{b7} json")
    #expect(summary.tone == .success)
}

@Test func notFound() throws {
    let summary = try #require(HTTPSummary.make(exchange: exchange(status: 404, total: 0.031, size: 9,
                                                                   type: "text/plain", body: "not found"),
                                                exitStatus: 0, duration: 0.1))
    #expect(summary.text == "404 \u{b7} 31 ms \u{b7} 9 B")
    #expect(summary.tone == .failure)
}

@Test func redirect302() throws {
    let summary = try #require(HTTPSummary.make(exchange: exchange(status: 302, total: 0.02, size: 0,
                                                                   type: "text/html", body: ""),
                                                exitStatus: 0, duration: 0.1))
    #expect(summary.text == "302 \u{b7} 20 ms")
    #expect(summary.tone == .redirect)
}

/// curl could not make the request at all: there is no status to show, and "exit 7" on its own
/// tells the user nothing they can act on.
@Test func curlExit7() throws {
    let summary = try #require(HTTPSummary.make(exchange: nil, exitStatus: 7, duration: 0.05))
    #expect(summary.text == "exit 7 \u{b7} connection refused")
    #expect(summary.tone == .failure)
}

/// An exit code curl's manual does not give a one-line meaning for still says what happened.
@Test func anUnknownExitCodeStillReportsItself() throws {
    let summary = try #require(HTTPSummary.make(exchange: nil, exitStatus: 99, duration: nil))
    #expect(summary.text == "exit 99")
    #expect(summary.tone == .failure)
}

@Test func secondsWhenSlow() throws {
    let summary = try #require(HTTPSummary.make(exchange: exchange(status: 200, total: 1.44, size: 0,
                                                                   type: "text/plain", body: ""),
                                                exitStatus: 0, duration: 1.5))
    #expect(summary.text == "200 \u{b7} 1.4 s")
    #expect(summary.tone == .success)
}

/// Without a sentinel there is no `time_total`, and the shell's own duration for the block is the
/// honest substitute -- it includes curl's start-up, which is why the sentinel is preferred.
@Test func withoutASentinelTheBlockDurationIsUsed() throws {
    let parsed = try #require(HTTPExchange.parse(lines: ["HTTP/1.1 200 OK", "", "hi"]))
    let summary = try #require(HTTPSummary.make(exchange: parsed, exitStatus: 0, duration: 0.088))
    #expect(summary.text == "200 \u{b7} 88 ms")
}

/// No sentinel, no duration: the status alone, rather than a made-up time.
@Test func withNoTimeAtAllTheStatusStandsAlone() throws {
    let parsed = try #require(HTTPExchange.parse(lines: ["HTTP/1.1 200 OK", "", "hi"]))
    let summary = try #require(HTTPSummary.make(exchange: parsed, exitStatus: 0, duration: nil))
    #expect(summary.text == "200")
}

@Test func nilWithoutAnything() {
    #expect(HTTPSummary.make(exchange: nil, exitStatus: 0, duration: 1.2) == nil)
    #expect(HTTPSummary.make(exchange: nil, exitStatus: nil, duration: nil) == nil)
}

/// curl wrote its `-w` line but never reached a server: `http_code` is `000` and the exit code is
/// what says why. Showing "0 · 12 ms" instead is a status nobody can look up.
@Test func aFailedRequestPrefersItsExitCodeOverAZeroStatus() throws {
    let parsed = try #require(HTTPExchange.parse(
        lines: ["\(RequestRun.sentinelPrefix)000 0.012 0.011 0.000 0.000 0.000 0 0"]))
    let summary = try #require(HTTPSummary.make(exchange: parsed, exitStatus: 6, duration: 0.02))
    #expect(summary.text == "exit 6 \u{b7} could not resolve host")
    #expect(summary.tone == .failure)
}

@Test func sizesAreScaledToWhatIsWorthReading() {
    #expect(HTTPSummary.sizeText(0) == nil)
    #expect(HTTPSummary.sizeText(61) == "61 B")
    #expect(HTTPSummary.sizeText(1023) == "1023 B")
    #expect(HTTPSummary.sizeText(1229) == "1.2 KB")
    #expect(HTTPSummary.sizeText(1024 * 1024) == "1.0 MB")
    #expect(HTTPSummary.sizeText(3 * 1024 * 1024 + 512 * 1024) == "3.5 MB")
}
