import Testing
@testable import NyxCore

// MARK: - The method popup

@Test func setMethodGETClearsExplicitMethodWithoutBody() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl -X POST https://api.example.com/v1/items")))
    model.setMethod("GET")
    // No body, so curl sends GET on its own: writing `-X GET` would add a word that changes
    // nothing, and the round trip would stop matching what the user pasted.
    #expect(model.command.method == nil)
    #expect(model.command.effectiveMethod == "GET")

    var withBody = RequestEditorModel(command: try #require(CurlCommand.parse("curl -d 'a=1' https://api.example.com/v1/items")))
    withBody.setMethod("GET")
    // With a body curl would send POST, so GET has to be said out loud.
    #expect(withBody.command.method == "GET")
    #expect(withBody.command.effectiveMethod == "GET")

    withBody.setMethod("POST")
    #expect(withBody.command.method == nil, "a body already means POST")
    #expect(withBody.command.effectiveMethod == "POST")
}

@Test func methodsIncludeAnUnusualMethod() throws {
    let plain = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    #expect(plain.methods == ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])

    let odd = RequestEditorModel(command: try #require(CurlCommand.parse("curl -X PURGE https://x/y")))
    #expect(odd.methods.contains("PURGE"), "a method the popup cannot show is one it would silently change")
    #expect(odd.methods.count == 8)
}

// MARK: - Text a field hands back

@Test func fieldTextKeepsVariablesAndQuotes() {
    let variable = ShellWords.word(literal: "$TOKEN")
    #expect(variable.containsVariable)
    #expect(ShellWords.quote(variable) == "$TOKEN")

    let mixed = ShellWords.word(literal: "Bearer $TOKEN")
    #expect(mixed.containsVariable)
    #expect(mixed.text == "Bearer $TOKEN")

    // A header value that happens to contain shell punctuation is *text*, not syntax: letting the
    // splitter eat its quotes would send `Chromium;v=128` where the user typed quotation marks.
    let quoted = ShellWords.word(literal: "\"Chromium\";v=\"128\"")
    #expect(!quoted.containsVariable)
    #expect(quoted.text == "\"Chromium\";v=\"128\"")

    let spaced = ShellWords.word(literal: "hello $NAME world")
    #expect(spaced.text == "hello $NAME world")
}

// MARK: - The URL field

@Test func setURLKeepsRawWithVariables() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    model.setURLString("$API/v1/items?state=open")

    #expect(model.command.url.raw.containsVariable, "$API must stay a variable, not become literal text")
    #expect(model.command.url.string == "$API/v1/items?state=open")
    #expect(model.command.url.query == [CurlCommand.QueryItem(name: "state", value: "open")])
    // Double quotes, never single: the shell has to expand `$API`, not hand curl four characters.
    #expect(model.command.shellLine(masking: .none, layout: .oneLine).hasSuffix("\"$API/v1/items?state=open\""))
    #expect(!model.queryIsEditable)
    #expect(model.paramsNote != nil)

    model.setURLString("https://api.example.com/v1/items?state=open&per_page=100")
    #expect(!model.command.url.raw.containsVariable)
    #expect(model.command.url.host == "api.example.com")
    #expect(model.command.url.query.count == 2)
    #expect(model.queryIsEditable)
    #expect(model.paramsNote == nil)
}

@Test func setQueryRewritesTheURL() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl 'https://x/y?a=1&b=2'")))
    model.setQuery([CurlCommand.QueryItem(name: "a", value: "9")])
    #expect(model.command.url.string == "https://x/y?a=9")
    #expect(model.command.shellLine(masking: .none, layout: .oneLine).hasSuffix("'https://x/y?a=9'"))

    model.setQuery([])
    // Deleting every parameter drops the `?` too, rather than leaving a URL nobody typed.
    #expect(model.command.url.string == "https://x/y")
}

@Test func paramRowsUnderGetAreTheBodyReadOnly() throws {
    let model = RequestEditorModel(command: try CurlFixtures.command("06-get-with-urlencode"))
    let rows = model.paramRows(revealed: false)
    #expect(rows.map(\.name) == ["q", "lang"])
    #expect(rows.map(\.value) == ["hello world", "en"])
    #expect(rows.allSatisfy { !$0.isEditable }, "these live in the body; editing them here has nowhere to write")
    #expect(model.paramsNote != nil)

    let dataUnderG = RequestEditorModel(command: try #require(CurlCommand.parse("curl -G -d 'a=1&token=supersecrettoken' https://x/y")))
    let split = dataUnderG.paramRows(revealed: false)
    #expect(split.map(\.name) == ["a", "token"])
    #expect(split[1].value == "••••oken", "a secret parameter is masked in the table too")
    #expect(dataUnderG.paramRows(revealed: true)[1].value == "supersecrettoken")
}

// MARK: - Headers

@Test func headerRowsShowJSONsImpliedHeaders() throws {
    let model = RequestEditorModel(command: try CurlFixtures.command("08-json-flag"))
    let rows = model.headerRows(revealed: false)
    // `--json` sends both of these itself; the tab would otherwise claim the request has no
    // headers at all, which is the opposite of what curl will do.
    #expect(rows.map(\.name) == ["Content-Type", "Accept"])
    #expect(rows.allSatisfy { $0.value == "application/json" && !$0.isEditable })
    #expect(model.headersNote != nil)

    let secret = RequestEditorModel(command: try #require(CurlCommand.parse("curl -H 'X-API-Key: abcdefghijkl' https://x/y")))
    // Masked and therefore not editable: a field showing four bullets that accepted typing would
    // write the bullets into the request.
    #expect(secret.headerRows(revealed: false) == [RequestEditorModel.Field(name: "X-API-Key", value: "••••ijkl", isEditable: false)])
    #expect(secret.headerRows(revealed: true) == [RequestEditorModel.Field(name: "X-API-Key", value: "abcdefghijkl", isEditable: true)])

    // A reference to a secret is not the secret: `$TOKEN` stays readable and editable.
    let variable = RequestEditorModel(command: try #require(CurlCommand.parse("curl -H \"X-API-Key: $KEY\" https://x/y")))
    #expect(variable.headerRows(revealed: false) == [RequestEditorModel.Field(name: "X-API-Key", value: "$KEY", isEditable: true)])
}

@Test func setHeadersReplacesTheList() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl -H 'A: 1' https://x/y")))
    model.setHeaders([CurlCommand.Header(name: "B", value: ShellWord("2"), removes: false)])
    #expect(model.command.headers.map(\.name) == ["B"])
    #expect(model.command.shellLine(masking: .none, layout: .oneLine).contains("-H 'B: 2'"))
}

// MARK: - The body

@Test func setBodyTextSetsContentType() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    model.setBodyText("{\"a\":1}", contentType: "application/json")
    #expect(model.command.body == .raw(ShellWord("{\"a\":1}")))
    #expect(model.command.headers == [CurlCommand.Header(name: "Content-Type", value: ShellWord("application/json"), removes: false)])
    #expect(model.bodyText == "{\"a\":1}")
    #expect(model.bodyIsJSON)
    #expect(model.command.effectiveMethod == "POST", "a body with no -X is a POST")

    // A second content type replaces the first rather than sending two.
    model.setBodyText("a=1", contentType: "application/x-www-form-urlencoded")
    #expect(model.command.headers.count == 1)
    #expect(model.command.headers[0].value.text == "application/x-www-form-urlencoded")
    #expect(!model.bodyIsJSON)

    // Emptied, the body goes away entirely: `--data-raw ''` would keep making it a POST with a
    // zero-length body, which is not what deleting the text means.
    model.setBodyText("", contentType: nil)
    #expect(model.command.body == nil)
}

@Test func bodyTextReadsEverySpelling() throws {
    let data = RequestEditorModel(command: try #require(CurlCommand.parse("curl -d a=1 -d b=2 https://x/y")))
    #expect(data.bodyText == "a=1&b=2", "curl joins every -d with &")

    let json = RequestEditorModel(command: try CurlFixtures.command("08-json-flag"))
    #expect(json.bodyText == "{\"x\":1}")
    #expect(json.bodyIsJSON)

    let form = RequestEditorModel(command: try CurlFixtures.command("07-form-upload"))
    #expect(form.bodyText == "", "a multipart form is not text this tab can edit")

    let none = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    #expect(none.bodyText == "")
}

@Test func prettyPrintBody() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl -H 'Content-Type: application/json' --data-raw '{\"b\":1,\"a\":[1,2]}' https://x/y")))
    let printed = model.prettyPrintBody()
    #expect(printed)
    #expect(model.bodyText == """
    {
      "b": 1,
      "a": [
        1,
        2
      ]
    }
    """, "the keys stay in the order they were written")

    var notJSON = RequestEditorModel(command: try #require(CurlCommand.parse("curl -d 'a=1' https://x/y")))
    let second = notJSON.prettyPrintBody()
    #expect(!second)
    #expect(notJSON.bodyText == "a=1", "a body that is not JSON is left exactly as it was")
}

// MARK: - Auth, flags, timing

@Test func authFieldsHideTheSecretUntilRevealed() throws {
    let basic = RequestEditorModel(command: try CurlFixtures.command("04-stripe-basic-auth"))
    let hidden = basic.authFields(revealed: false)
    #expect(hidden.kind == .basic)
    #expect(!hidden.isEditable, "a masked field must not accept typing")
    #expect(hidden.secret.hasPrefix("••••") || hidden.user.hasPrefix("••••"))
    #expect(basic.authFields(revealed: true).isEditable)

    let bearer = RequestEditorModel(command: try CurlFixtures.command("03-github-api"))
    let fields = bearer.authFields(revealed: false)
    #expect(fields.kind == .bearer)
    // The token is `$GITHUB_TOKEN`: a reference, not a credential, so it stays readable.
    #expect(fields.secret == "$GITHUB_TOKEN")
    #expect(fields.isEditable)

    let none = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    #expect(none.authFields(revealed: false) == RequestEditorModel.AuthFields(kind: .none, user: "", secret: "", isEditable: true))
}

@Test func setAuthAndFlagsAndTiming() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    model.setAuth(.bearer(ShellWords.word(literal: "$TOKEN")))
    // Double quotes, not single: the shell has to expand the reference the user typed.
    #expect(model.command.shellLine(masking: .none, layout: .oneLine)
        .contains("-H \"Authorization: Bearer $TOKEN\""))

    model.toggle(.location)
    #expect(model.command.flags.contains(.location))
    model.toggle(.location)
    #expect(!model.command.flags.contains(.location))

    model.setTiming(maxTime: 30, retry: 3)
    #expect(model.command.timing.maxTime == 30)
    #expect(model.command.timing.retry == 3)
    model.setTiming(maxTime: nil, retry: nil)
    #expect(model.command.timing.maxTime == nil)
    #expect(model.command.timing.retry == nil)
}

// MARK: - Output

@Test func outputModeRoundTrip() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    for mode in RequestEditorModel.OutputMode.allCases {
        model.setOutputMode(mode, savePath: "/tmp/body.json")
        #expect(model.outputMode == mode, "\(mode) did not read back")
    }
    model.setOutputMode(.headersAndBody, savePath: nil)
    #expect(model.command.output.file == nil)
    #expect(model.command.output.dumpHeaders == nil)
    #expect(model.command.flags.contains(.include))

    model.setOutputMode(.bodyOnly, savePath: nil)
    #expect(!model.command.flags.contains(.include))
    // The whole mechanism: without somewhere for the headers to go, `RequestRun` adds `-i` back
    // and "Body only" is a menu item that changes nothing a user can see.
    #expect(model.command.output.dumpHeaders?.text == "/dev/null")
    #expect(!RequestRun.additions(for: model.command).include)
    #expect(model.runLine.contains("-D /dev/null"))
    #expect(!model.runLine.contains("-i"))

    // And it goes away again, rather than sitting in a saved command forever.
    model.setOutputMode(.headersAndBody, savePath: nil)
    #expect(model.command.output.dumpHeaders == nil)

    // Asked to save with nowhere to save it, the command is left alone rather than quietly
    // becoming a request whose body goes nowhere.
    let before = model.command
    model.setOutputMode(.saveBody, savePath: nil)
    #expect(model.command == before)
}

@Test func statusOnlyKeepsSentinel() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    model.setOutputMode(.statusOnly, savePath: nil)
    #expect(model.command.output.file?.text == "/dev/null")
    let writeOut = try #require(model.command.output.writeOut?.text)
    #expect(writeOut.hasPrefix("%{http_code}\\n"))
    // The sentinel is how the response side finds the status and the timings at all: a `-w` that
    // replaced it rather than preceding it would leave every run of this command unparsed.
    #expect(writeOut.hasSuffix(RequestRun.writeOutArgument))

    // And back again: the status-only `-w` is Nyx's, so leaving the mode takes it away.
    model.setOutputMode(.bodyOnly, savePath: nil)
    #expect(model.command.output.writeOut == nil)
    #expect(model.command.output.file == nil)
}

// MARK: - Badges and the preview

@Test func badgesCountThings() throws {
    let model = RequestEditorModel(command: try CurlFixtures.command("01-chrome-copy-as-curl"))
    #expect(model.tabBadges[.params] == 0)
    #expect(model.tabBadges[.headers] == 14)
    #expect(model.tabBadges[.body] == 1)
    #expect(model.tabBadges[.auth] == 0)
    #expect(model.tabBadges[.options] == 1, "--compressed is the only option set")

    let github = RequestEditorModel(command: try CurlFixtures.command("03-github-api"))
    #expect(github.tabBadges[.params] == 2)
    #expect(github.tabBadges[.headers] == 2)
    #expect(github.tabBadges[.body] == 0)
    #expect(github.tabBadges[.auth] == 1)
    #expect(github.tabBadges[.options] == 1, "-L")

    // `-s` has no checkbox on the tab, so counting it would put a number on a tab that shows
    // nothing to explain it.
    let piped = RequestEditorModel(command: try CurlFixtures.command("10-pipeline"))
    #expect(piped.tabBadges[.options] == 0)

    var timed = github
    timed.setTiming(maxTime: 30, retry: 2)
    #expect(timed.tabBadges[.options] == 3)
}

@Test func previewIsMaskedAndRevealIsNot() throws {
    let model = RequestEditorModel(command: try #require(CurlCommand.parse("curl -H 'Authorization: Bearer sk_live_9f2a4b6c8d' https://x/y")))
    #expect(model.preview.contains("Bearer ••••6c8d"))
    #expect(!model.preview.contains("sk_live_9f2a4b6c8d"))
    #expect(model.revealedPreview.contains("sk_live_9f2a4b6c8d"))
    // Multiline for reading, one line for the clipboard and the shell.
    #expect(model.preview.contains("\\\n"))
    #expect(!model.copyLine.contains("\n"))
    #expect(model.copyLine.contains("sk_live_9f2a4b6c8d"))

    #expect(model.runLine == RequestRun.commandLine(for: model.command))
    #expect(model.runNote == nil)

    let piped = RequestEditorModel(command: try CurlFixtures.command("10-pipeline"))
    #expect(piped.runNote == "Pipeline present: headers and timing unavailable")
}

// MARK: - A new request

@Test func newRequestIsAGETWithEmptyHost() {
    let model = RequestEditorModel.newRequest()
    #expect(model.tab == .params)
    #expect(model.command.effectiveMethod == "GET")
    #expect(model.command.url.host == "")
    #expect(model.command.url.string == "https://")
    #expect(model.command.headers.isEmpty)
    #expect(model.command.body == nil)
}

@Test func watchPlanRequestsSayWhatTheyAre() {
    #expect(WatchPlanRequest.every(seconds: 5).summary == "every 5 s")
    #expect(WatchPlanRequest.every(seconds: 2.5).summary == "every 2.5 s")
    #expect(WatchPlanRequest.times(10).summary == "10 times")
    #expect(WatchPlanRequest.untilStatus(200).summary == "until 200")
}

// MARK: - The button a request can be saved as

@Test func suggestedButtonNameIsTheRequest() throws {
    let model = RequestEditorModel(command: try CurlFixtures.command("03-github-api"))
    #expect(model.suggestedActionName == "GET api.github.com/repos/nyx/nyx/issues")

    let bare = RequestEditorModel(command: try #require(CurlCommand.parse("curl -X POST https://x")))
    #expect(bare.suggestedActionName == "POST x")
}


// MARK: - Half-typed rows

@Test func draftRowsStayInTheTableAndOutOfTheCommand() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl https://x/y")))
    model.setQuery([CurlCommand.QueryItem(name: "", value: "")])
    model.setHeaders([CurlCommand.Header(name: "", value: ShellWord(""), removes: false)])

    // The rows are in the table, because that is where they are being typed.
    #expect(model.paramRows(revealed: true).count == 1)
    #expect(model.headerRows(revealed: true).count == 1)

    // And in nothing that leaves the sheet: `?=` and `-H ';'` -- which curl rejects outright --
    // are what a user got by pressing + and then Run.
    #expect(model.urlString == "https://x/y")
    #expect(model.copyLine == "curl https://x/y")
    #expect(!model.preview.contains("?="))
    #expect(!model.revealedPreview.contains("-H"))
    #expect(!model.runLine.contains("?="))
    #expect(!model.runLine.contains("';'"))

    // Typing a name is all it takes for the row to count.
    model.setQuery([CurlCommand.QueryItem(name: "debug", value: "1")])
    #expect(model.urlString == "https://x/y?debug=1")
    #expect(model.copyLine.contains("https://x/y?debug=1"))
}

@Test func editingAJSONBodyKeepsBothHeadersCurlImplied() throws {
    var model = RequestEditorModel(command: try CurlFixtures.command("08-json-flag"))
    #expect(model.headerRows(revealed: true).map(\.name) == ["Content-Type", "Accept"])

    model.setBodyText("{\"x\":2}", contentType: "application/json")
    // `--json` sent both by itself; `--data-raw` sends neither unless they are written out.
    #expect(model.command.headers.map(\.name) == ["Content-Type", "Accept"])
    #expect(model.command.headers.allSatisfy { $0.value.text == "application/json" })

    // An Accept the user wrote is theirs, and is not overwritten.
    var mine = RequestEditorModel(command: try #require(CurlCommand.parse("curl --json '{\"x\":1}' -H 'Accept: text/plain' https://x/y")))
    mine.setBodyText("{\"x\":2}", contentType: "application/json")
    #expect(mine.command.headers.first { $0.name == "Accept" }?.value.text == "text/plain")
}

@Test func removingTheBodyDropsTheMethodItForced() throws {
    var model = RequestEditorModel(command: try #require(CurlCommand.parse("curl -X GET -d 'a=1' https://x/y")))
    #expect(model.command.method == "GET")
    model.setBodyText("", contentType: nil)
    #expect(model.command.body == nil)
    // `-X GET` was there to beat the POST the body implied. It now says nothing, and a command
    // that grows a word every time it is edited stops being the one that was pasted.
    #expect(model.command.method == nil)
    #expect(model.copyLine == "curl https://x/y")

    // A method that is *not* the default stays.
    var deleting = RequestEditorModel(command: try #require(CurlCommand.parse("curl -X DELETE -d 'a=1' https://x/y")))
    deleting.setBodyText("", contentType: nil)
    #expect(deleting.command.method == "DELETE")
}

// MARK: - The tab labels

/// A badge appearing must not move the word in front of it.
///
/// The five segments are equal width and their labels are centred, so `Headers` slid left the
/// instant a header was added and slid back when the last one was removed -- five labels dancing
/// while you type into a table. The count sits in a field of constant width instead, written with
/// figure spaces, which are exactly as wide as the digits they stand in for.
@Test func aTabLabelIsTheSameWidthWithAndWithoutItsCount() throws {
    let empty = try #require(CurlCommand.parse("curl https://example.com"))
    let loaded = try #require(CurlCommand.parse(
        "curl -H 'a: 1' -H 'b: 2' -H 'c: 3' https://example.com?x=1"))
    for tab in RequestEditorModel.Tab.allCases {
        let bare = RequestEditorModel(command: empty).tabLabel(tab)
        let full = RequestEditorModel(command: loaded).tabLabel(tab)
        #expect(bare.count == full.count, "\(tab): \u{201C}\(bare)\u{201D} vs \u{201C}\(full)\u{201D}")
        #expect(bare.hasPrefix(tab.rawValue))
    }
}

@Test func aTabLabelShowsTheCountAndNotAZero() throws {
    let loaded = try #require(CurlCommand.parse("curl -H 'a: 1' -H 'b: 2' https://example.com"))
    let model = RequestEditorModel(command: loaded)
    #expect(model.tabLabel(.headers).contains("2"))
    // Nothing to say is said with nothing: a "0" on four of five tabs is noise on every request.
    #expect(!model.tabLabel(.auth).contains("0"))
}

/// A count nobody can read at a glance is not worth reflowing the control for: past ninety-nine
/// the badge says so and stops growing.
@Test func anAbsurdCountIsCappedRatherThanWidening() throws {
    var line = "curl https://example.com"
    for index in 0..<120 { line += " -H 'h\(index): 1'" }
    let many = try #require(CurlCommand.parse(line))
    let model = RequestEditorModel(command: many)
    #expect(model.tabLabel(.headers).contains("99+"))
    // Still the same width as the same tab with no badge at all -- which is the whole point.
    let empty = try #require(CurlCommand.parse("curl https://example.com"))
    #expect(model.tabLabel(.headers).count
        == RequestEditorModel(command: empty).tabLabel(.headers).count)
}
