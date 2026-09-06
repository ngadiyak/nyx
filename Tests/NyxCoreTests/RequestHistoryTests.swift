import Foundation
import Testing
@testable import NyxCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ secondsAgo: TimeInterval) -> Date { epoch.addingTimeInterval(-secondsAgo) }

// MARK: - Recording

@Test func recordsNewestFirst() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://a.example.com/one", at: at(300))
    history.record("curl https://b.example.com/two", at: at(60))
    #expect(history.entries.map(\.line) == ["curl https://b.example.com/two",
                                            "curl https://a.example.com/one"])
    #expect(history.entries[0].at == at(60))
}

/// The same request run again is one row, at the top -- a list where `curl …/healthz` appears
/// eleven times is not a history, it is a log.
@Test func reRunMovesToTop() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://a.example.com/one", at: at(300))
    history.record("curl https://b.example.com/two", at: at(200))
    history.record("curl https://a.example.com/one", at: at(10))
    #expect(history.entries.count == 2)
    #expect(history.entries[0].line == "curl https://a.example.com/one")
    #expect(history.entries[0].at == at(10))
}

/// Dedup is on what the request *is*, not on the text: the same call written `-H a -H b` and
/// `-H b -H a` is the same request, and `--silent` is `-s`.
@Test func reRunIsRecognisedThroughADifferentSpelling() {
    var history = RequestHistory(limit: 10)
    history.record("curl --silent https://a.example.com/one", at: at(300))
    history.record("curl -s https://a.example.com/one", at: at(10))
    #expect(history.entries.count == 1)
    #expect(history.entries[0].line == "curl -s https://a.example.com/one")
}

/// A different URL, header or body is a different request, however similar it reads.
@Test func aDifferentRequestIsItsOwnRow() {
    var history = RequestHistory(limit: 10)
    history.record("curl -H 'X-A: 1' https://a.example.com/one", at: at(300))
    history.record("curl -H 'X-A: 2' https://a.example.com/one", at: at(10))
    #expect(history.entries.count == 2)
}

@Test func limitTrims() {
    var history = RequestHistory(limit: 3)
    for index in 0..<6 {
        history.record("curl https://a.example.com/\(index)", at: at(TimeInterval(600 - index)))
    }
    #expect(history.entries.map(\.line) == ["curl https://a.example.com/5",
                                            "curl https://a.example.com/4",
                                            "curl https://a.example.com/3"])
}

/// `http_history = 0` is a user saying "do not keep this". It has to mean nothing is kept, not
/// "kept until something trims it".
@Test func zeroLimitRecordsNothing() {
    var history = RequestHistory(limit: 0)
    history.record("curl https://a.example.com/one", at: epoch)
    #expect(history.entries.isEmpty)
    #expect(history.serialised().isEmpty)
}

/// A line that is not a request cannot be dedup'd, re-run or titled, so it is not kept at all.
@Test func aLineThatIsNotACurlIsNotRecorded() {
    var history = RequestHistory(limit: 10)
    history.record("make test", at: epoch)
    history.record("curl --help", at: epoch)              // no URL: `parse` returns nil
    history.record("curl 'https://a.example.com", at: epoch)  // unterminated quote
    #expect(history.entries.isEmpty)
}

// MARK: - The file

@Test func roundTripsThroughText() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://a.example.com/one", at: at(300))
    history.record("curl -X POST -d 'x=1' https://b.example.com/two", at: at(60))
    let text = history.serialised()
    #expect(text == "1699999940\tcurl -X POST -d 'x=1' https://b.example.com/two\n"
                  + "1699999700\tcurl https://a.example.com/one\n")
    #expect(RequestHistory.parse(text, limit: 10) == history)
}

/// Whatever else is in the file, the palette gets rows it can act on: a truncated write, a line
/// with no tab, a timestamp that is not a number, and a command that is not a curl are dropped
/// rather than turned into a row that opens an editor on nonsense.
@Test func aDamagedFileLosesOnlyItsDamagedLines() {
    let text = """
    1699999940\tcurl https://b.example.com/two
    not-a-number\tcurl https://c.example.com/three
    curl https://d.example.com/four
    1699999800\tmake test

    1699999700\tcurl https://a.example.com/one
    """
    let history = RequestHistory.parse(text, limit: 10)
    #expect(history.entries.map(\.line) == ["curl https://b.example.com/two",
                                            "curl https://a.example.com/one"])
}

/// The file is read back under the *current* limit, not the one that wrote it: turning the setting
/// down has to shorten the list on the next launch rather than on the next fifty requests.
@Test func readingAppliesTheCurrentLimit() {
    var history = RequestHistory(limit: 10)
    for index in 0..<6 {
        history.record("curl https://a.example.com/\(index)", at: at(TimeInterval(600 - index)))
    }
    let reread = RequestHistory.parse(history.serialised(), limit: 2)
    #expect(reread.entries.map(\.line) == ["curl https://a.example.com/5",
                                           "curl https://a.example.com/4"])
}

/// A tab inside the command -- `-d $'a\tb'` -- belongs to the command, not to the separator.
@Test func onlyTheFirstTabSeparates() {
    let history = RequestHistory.parse("1699999940\tcurl -H 'X-A: 1\t2' https://a.example.com/x",
                                       limit: 10)
    #expect(history.entries.first?.line == "curl -H 'X-A: 1\t2' https://a.example.com/x")
}

@Test func theHistoryFileSitsBesideTheConfig() {
    #expect(RequestHistoryPath.resolve(environment: [:], home: "/Users/x").path
            == "/Users/x/.config/nyx/requests")
    #expect(RequestHistoryPath.resolve(environment: ["NYX_CONFIG": "/tmp/nyx-a/config"],
                                       home: "/Users/x").path == "/tmp/nyx-a/requests")
    #expect(RequestHistoryPath.resolve(environment: ["NYX_REQUEST_HISTORY": "/tmp/r"],
                                       home: "/Users/x").path == "/tmp/r")
}

// MARK: - Palette rows

@Test func paletteTitlesAreMethodAndHostPath() {
    var history = RequestHistory(limit: 10)
    history.record("curl -sS https://api.example.com/users", at: at(7200))
    history.record("curl -X POST -d '{}' https://api.example.com/v2/deployments", at: at(120))
    let items = history.paletteItems(now: epoch)
    #expect(items.map(\.title) == ["POST api.example.com/v2/deployments",
                                   "GET api.example.com/users"])
    // The trailing column names the kind first, the way a Theme, Tab or Quick Action row does:
    // a palette whose right-hand column says "2 min ago" on some rows and "Theme" on others gives
    // the reader nothing to read down.
    #expect(items.map(\.detail) == ["Request \u{b7} 2 min ago", "Request \u{b7} 2 h ago"])
    #expect(items.map(\.kind) == [.request(id: RequestHistory.identifier(for: history.entries[0].line)),
                                  .request(id: RequestHistory.identifier(for: history.entries[1].line))])
    // Everything on the row, plus the method and host on their own, so `post deployments` and
    // `example.com` both find it.
    #expect(items[0].searchText.contains("POST"))
    #expect(items[0].searchText.contains("api.example.com"))
    #expect(items[0].searchText.contains("/v2/deployments"))
}

/// A row is one line of a list, not a URL bar. A path long enough to push the age off the right
/// edge is cut, and the cut is visible.
@Test func aLongPathIsTruncated() {
    var history = RequestHistory(limit: 10)
    let path = "/v2/organisations/acme/projects/nyx/deployments/latest/logs"
    history.record("curl https://api.example.com\(path)", at: epoch)
    let title = history.paletteItems(now: epoch)[0].title
    #expect(title == "GET api.example.com/v2/organisations/acme/projects/nyx/dep…")
    // 40 characters of path, the ellipsis included.
    #expect(title.dropFirst("GET api.example.com".count).count == 40)
    // The whole path is still searchable, so the row can be found by the part that was cut.
    #expect(history.paletteItems(now: epoch)[0].searchText.contains("logs"))
}

/// The palette is the one surface a screenshot catches. A password in the URL is bulleted on the
/// row; the line the editor opens on is the real one, which is why masking is a display option.
@Test func secretsMaskedInPalette() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://admin:hunter2secret@api.example.com/v1/users", at: epoch)
    #expect(history.paletteItems(now: epoch)[0].title
            == "GET admin:\u{2022}\u{2022}\u{2022}\u{2022}cret@api.example.com/v1/users")
    #expect(history.paletteItems(now: epoch, masking: .none)[0].title
            == "GET admin:hunter2secret@api.example.com/v1/users")
    #expect(history.entries[0].line == "curl https://admin:hunter2secret@api.example.com/v1/users")
}

/// `$TOKEN` is a reference, not a credential: bulleting it would hide the one thing that says
/// where the value comes from.
@Test func aVariableInTheURLIsNotMasked() {
    var history = RequestHistory(limit: 10)
    history.record("curl \"https://admin:$TOKEN@api.example.com/v1/users\"", at: epoch)
    #expect(history.paletteItems(now: epoch)[0].title
            == "GET admin:$TOKEN@api.example.com/v1/users")
}

/// A URL with no path is the host on its own -- not a trailing slash the user did not type.
@Test func aHostWithNoPathIsJustTheHost() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://example.com", at: epoch)
    #expect(history.paletteItems(now: epoch)[0].title == "GET example.com")
}

/// Every row resolves to the request it was built from, in the order the list is in.
@Test func rowsResolveToTheEntriesTheyCameFrom() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://a.example.com/one", at: at(300))
    history.record("curl https://b.example.com/two", at: at(60))
    let lines = history.paletteItems(now: epoch).compactMap { item -> String? in
        guard case .request(let id) = item.kind else { return nil }
        return history.line(for: id)
    }
    #expect(lines == ["curl https://b.example.com/two", "curl https://a.example.com/one"])
}

// MARK: - Rows address the request, not the position

/// The defect this replaced an index with an id for: a curl finishing in another tab while the
/// palette is open pushes every row down one, and the row the user is looking at would have run
/// its neighbour's command.
@Test func aRowStillRunsItsOwnRequestAfterTheListMoves() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://a.example.com/one", at: at(300))
    history.record("curl https://b.example.com/two", at: at(60))
    let chosen = history.paletteItems(now: epoch)[1]          // the older of the two
    #expect(chosen.title == "GET a.example.com/one")

    history.record("curl https://c.example.com/three", at: epoch)  // the list moves under it
    guard case .request(let id) = chosen.kind else {
        Issue.record("not a request row")
        return
    }
    #expect(history.line(for: id) == "curl https://a.example.com/one")
}

/// A row for a request that has since been trimmed off the end, or dropped by a hand edit, has
/// nothing to run. It says so rather than running whatever now sits at that place in the list.
@Test func aRowForAForgottenRequestResolvesToNothing() {
    var history = RequestHistory(limit: 1)
    history.record("curl https://a.example.com/one", at: at(60))
    let chosen = history.paletteItems(now: epoch)[0]
    history.record("curl https://b.example.com/two", at: epoch)   // trims the first one away
    guard case .request(let id) = chosen.kind else {
        Issue.record("not a request row")
        return
    }
    #expect(history.line(for: id) == nil)
}

/// The id is a hash of the line, so it is the same in every process and carries no part of the
/// credential the line may hold -- a palette row is passed around and logged.
@Test func anIdentifierIsStableAndCarriesNoSecret() {
    let line = "curl https://admin:hunter2secret@api.example.com/v1/users"
    let id = RequestHistory.identifier(for: line)
    #expect(id == RequestHistory.identifier(for: line))
    #expect(id != RequestHistory.identifier(for: line + " "))
    #expect(!id.contains("hunter2secret"))
}

// MARK: - The file, awkwardly written

/// A file with Windows line endings -- an editor, a `scp` from elsewhere -- is still a list of
/// requests. Splitting on "\n" alone left the `\r` on the end of every command, so no line parsed
/// as the same request twice and dedup silently stopped working.
@Test func aCRLFFileIsReadAsLines() {
    let text = "1699999940\tcurl https://b.example.com/two\r\n"
             + "1699999700\tcurl https://a.example.com/one\r\n"
    let history = RequestHistory.parse(text, limit: 10)
    #expect(history.entries.map(\.line) == ["curl https://b.example.com/two",
                                            "curl https://a.example.com/one"])
}

/// Launch reads this file before the first window is drawn. Whatever is in it -- a log somebody
/// redirected here, a file that grew unbounded under an older build -- it must not be a pause.
@Test func aHugeFileIsNotReadWhole() {
    let line = "1699999700\tcurl https://a.example.com/"
    let text = (0..<5_000).map { "\(line)\($0)" }.joined(separator: "\n")
    let history = RequestHistory.parse(text, limit: 10)
    // The newest `limit` survive, and only `limit * 20` lines were looked at to find them.
    #expect(history.entries.count == 10)
    #expect(history.entries[0].line == "curl https://a.example.com/0")
    #expect(history.entries[9].line == "curl https://a.example.com/9")
}

// MARK: - Finding the section

/// Typing "theme" finds the themes; "request" and "curl" have to find these. A palette where you
/// must already know the host you are looking for is a list, not a search.
@Test func theSectionIsFoundByTypingRequestOrCurl() {
    var history = RequestHistory(limit: 10)
    history.record("curl https://api.example.com/users", at: epoch)
    let items = history.paletteItems(now: epoch)
    var byKind = CommandPalette(items: items)
    byKind.setQuery("request")
    #expect(byKind.selected?.title == "GET api.example.com/users")
    var byTool = CommandPalette(items: items)
    byTool.setQuery("curl")
    #expect(byTool.selected?.title == "GET api.example.com/users")
}

// MARK: - What gets remembered is the request, not the run

/// A request run from the workbench and the same one typed by hand are one row, not two.
///
/// The line a workbench run puts on the shell carries Nyx's own `-sSi -w '<sentinel>'`, and both
/// places that record a request see *that* line -- the pane, as the sheet finishes, and the block
/// reader, off the grid. Stored as it stands, the palette then offered a row whose form showed
/// flags nobody typed, whose `Save as Button` wrote the sentinel into the config file, and which
/// counted as a different request from the hand-typed one beside it.
@Test func aRunAndTheSameRequestTypedByHandAreOneRow() throws {
    let typed = try #require(CurlCommand.parse("curl -H 'x-a: 1' https://api.example.com/v1/users"))
    var history = RequestHistory(limit: 10)
    history.record(RequestRun.commandLine(for: typed), at: at(60))
    history.record("curl -H 'x-a: 1' https://api.example.com/v1/users", at: at(0))
    #expect(history.entries.count == 1)
    let line = try #require(history.entries.first?.line)
    #expect(!line.contains("nyx-http"))
    #expect(!line.contains("-sSi"))
    #expect(line == "curl -H 'x-a: 1' https://api.example.com/v1/users")
}

/// The other order, because dedup keeps the *newest* spelling: recording the run second must not
/// put the sentinel back.
@Test func recordingARunSecondStillStoresTheRequest() throws {
    let typed = try #require(CurlCommand.parse("curl https://api.example.com/v1/users"))
    var history = RequestHistory(limit: 10)
    history.record("curl https://api.example.com/v1/users", at: at(60))
    history.record(RequestRun.commandLine(for: typed), at: at(0))
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.line == "curl https://api.example.com/v1/users")
}

/// And a line that is not a run keeps every character of what was typed -- the strip is the
/// inverse of a run, not a normaliser.
@Test func aLineThatIsNotARunIsStoredVerbatim() {
    var history = RequestHistory(limit: 10)
    let line = "curl -sS --compressed 'https://api.example.com/v1/items?page=2'"
    history.record(line, at: at(0))
    #expect(history.entries.first?.line == line)
}
