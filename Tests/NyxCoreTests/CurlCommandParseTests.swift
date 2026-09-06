import Testing
@testable import NyxCore

// MARK: - Fixtures: the shapes people actually paste

@Test func chromeCopyAsCurlParses() throws {
    let c = try CurlFixtures.command("01-chrome-copy-as-curl")

    #expect(c.effectiveMethod == "POST")
    #expect(c.method == nil)
    #expect(c.headers.count == 14)
    #expect(c.headers.first == CurlCommand.Header(name: "accept", value: ShellWord("*/*"), removes: false))
    // A `;` inside a header *value* must not be mistaken for the `Name;` empty-value terminator:
    // the `:` comes first, so it wins.
    #expect(c.headers[8].name == "sec-ch-ua")
    #expect(c.headers[8].value.text == "\"Chromium\";v=\"128\", \"Not;A=Brand\";v=\"24\"")

    // `$'...\n...'` is decoded by the tokenizer, so the body carries a real newline.
    let body = "{\"model\":\"claude-opus\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\nthere\"}]}"
    #expect(c.body == .raw(ShellWord(body)))
    #expect(c.flags.contains(.compressed))
    #expect(c.url.scheme == "https")
    #expect(c.url.host == "api.example.com")
    #expect(c.url.path == "/v1/messages")
    #expect(c.url.string == "https://api.example.com/v1/messages")
    #expect(c.trailingPipeline == "")
}

@Test func postmanExportParses() throws {
    let c = try CurlFixtures.command("02-postman")

    #expect(c.method == "PUT")
    #expect(c.effectiveMethod == "PUT")
    #expect(c.flags.contains(.location))
    // The Authorization header moves into `auth`; only Content-Type stays behind.
    #expect(c.headers.map(\.name) == ["Content-Type"])
    #expect(c.auth == .header(ShellWord("Basic YWxhZGRpbjpvcGVuc2VzYW1l")))
    #expect(c.body == .data([ShellWord("{\"name\":\"Ada Lovelace\",\"active\":true}")]))
    #expect(c.url.string == "https://api.example.com/v1/users/42")
}

@Test func githubBearerTokenStaysAVariable() throws {
    let c = try CurlFixtures.command("03-github-api")

    #expect(c.flags.contains(.location))
    #expect(c.auth == .bearer(ShellWord(pieces: [.variable("$GITHUB_TOKEN")])))
    #expect(c.headers.map(\.name) == ["Accept", "X-GitHub-Api-Version"])
    #expect(c.effectiveMethod == "GET")
    #expect(c.url.path == "/repos/nyx/nyx/issues")
    #expect(c.url.query == [
        CurlCommand.QueryItem(name: "state", value: "open"),
        CurlCommand.QueryItem(name: "per_page", value: "100"),
    ])
    #expect(c.url.string == "https://api.github.com/repos/nyx/nyx/issues?state=open&per_page=100")
}

@Test func stripeBasicAuthHasAnEmptyPassword() throws {
    let c = try CurlFixtures.command("04-stripe-basic-auth")

    #expect(c.auth == .basic(user: "sk_test_4eC39HqLyjWDarjtT1zdp7dc", password: ShellWord("")))
    #expect(c.body == .data([
        ShellWord("amount=2000"),
        ShellWord("currency=usd"),
        ShellWord("source=tok_visa"),
        ShellWord("description=First payment"),
    ]))
    #expect(c.effectiveMethod == "POST")
    #expect(c.headers.isEmpty)
}

@Test func multilineContinuationsParse() throws {
    let c = try CurlFixtures.command("05-multiline-continuations")

    #expect(c.method == "POST")
    #expect(c.url.string == "https://api.example.com/v2/search")   // set by --url, not a bare word
    #expect(c.headers.count == 2)
    #expect(c.body == .data([ShellWord("{\"query\":\"nyx\",\"limit\":25}")]))
    #expect(c.timing.maxTime == 30)
    #expect(c.timing.retry == 2)
    #expect(c.timing.retryDelay == 1)
    #expect(c.flags.contains(.silent))
    #expect(c.flags.contains(.showError))
    #expect(c.other.isEmpty)
}

@Test func getWithUrlencodeStaysAGet() throws {
    let c = try CurlFixtures.command("06-get-with-urlencode")

    #expect(c.get)
    #expect(c.body == .urlencoded([ShellWord("q=hello world"), ShellWord("lang=en")]))
    #expect(c.effectiveMethod == "GET")   // -G, so a body does not make it a POST
    #expect(c.flags.contains(.silent))
    #expect(c.flags.contains(.showError))
}

@Test func formUploadKeepsTheTypeSuffix() throws {
    let c = try CurlFixtures.command("07-form-upload")

    #expect(c.method == "POST")
    #expect(c.body == .form([
        CurlCommand.FormItem(name: "file", value: ShellWord("@photo.jpg")),
        CurlCommand.FormItem(name: "meta", value: ShellWord("{\"a\":1};type=application/json")),
    ]))
}

@Test func jsonFlagIsItsOwnBody() throws {
    let c = try CurlFixtures.command("08-json-flag")

    #expect(c.body == .json(ShellWord("{\"x\":1}")))
    #expect(c.effectiveMethod == "POST")
    #expect(c.url.string == "https://api.example.com/v1/echo")
}

@Test func bodyFromFileKeepsTheAtSign() throws {
    let c = try CurlFixtures.command("09-body-from-file")

    #expect(c.body == .data([ShellWord("@body.json")]))
    #expect(c.flags.contains(.include))
    #expect(c.url.scheme == "http")
    #expect(c.url.host == "localhost")
    #expect(c.url.port == 8080)
    #expect(c.url.path == "/v1/import")
    #expect(c.url.string == "http://localhost:8080/v1/import")
}

@Test func pipelineIsSplitOffAndRoundTrips() throws {
    let c = try CurlFixtures.command("10-pipeline")

    #expect(c.trailingPipeline == "| jq '.items[]'")
    #expect(c.flags.contains(.silent))
    #expect(c.url.string == "https://api.example.com/v1/items")
    #expect(c.other.isEmpty)   // nothing from the pipeline leaked into the curl side
}

@Test func envPrefixAndGlobsSurvive() throws {
    let c = try CurlFixtures.command("11-prefix-and-globs")

    #expect(c.prefix == [ShellWord("API=https://api.example.com")])
    #expect(c.url.raw.containsVariable)
    #expect(c.url.string == "$API/users/[1-3]")   // a variable in the word: never rebuilt
    #expect(c.output.file?.text == "out_#1.json")
    #expect(c.output.remoteName == false)
}

@Test func headAndTimeoutsParse() throws {
    let c = try CurlFixtures.command("12-head-and-timeouts")

    #expect(c.head)
    #expect(c.effectiveMethod == "HEAD")
    #expect(c.timing.maxTime == 5)
    #expect(c.timing.retry == 3)
    #expect(c.flags.contains(.insecure))
    #expect(c.other == [CurlCommand.Other(option: "-x", value: ShellWord("http://proxy.local:3128"))])
    #expect(c.url.string == "https://api.example.com/health")
}

// MARK: - The rules the fixtures do not pin down

@Test func notACurlIsNil() {
    #expect(CurlCommand.parse("ls -la") == nil)
}

@Test func curlWithoutURLIsNil() {
    #expect(CurlCommand.parse("curl -s") == nil)
}

@Test func curlLaterInAPipelineIsNil() {
    // The workbench edits the first command; `curl` fed from a pipe is somebody else's request.
    #expect(CurlCommand.parse("cat body.json | curl -d @- https://x/y") == nil)
}

@Test func curlWithAnUnterminatedQuoteIsNil() {
    #expect(CurlCommand.parse("curl -H 'Accept: json https://x/y") == nil)
}

@Test func combinedShortFlagsSplit() throws {
    let c = try #require(CurlCommand.parse("curl -sSL https://x/y"))
    #expect(c.flags.contains(.silent))
    #expect(c.flags.contains(.showError))
    #expect(c.flags.contains(.location))
    #expect(c.other.isEmpty)
}

@Test func combinedShortWithValue() throws {
    let c = try #require(CurlCommand.parse("curl -sH 'A: b' https://x/y"))
    #expect(c.flags.contains(.silent))
    #expect(c.headers == [CurlCommand.Header(name: "A", value: ShellWord("b"), removes: false)])
}

@Test func shortOptionValueMayBeAttached() throws {
    let c = try #require(CurlCommand.parse("curl -XPUT -H'A: b' https://x/y"))
    #expect(c.method == "PUT")
    #expect(c.headers.map(\.name) == ["A"])
}

@Test func optionEqualsValue() throws {
    let c = try #require(CurlCommand.parse("curl --max-time=10 --request=DELETE https://x/y"))
    #expect(c.timing.maxTime == 10)
    #expect(c.method == "DELETE")
}

@Test func bearerHeaderBecomesAuth() throws {
    let c = try #require(CurlCommand.parse("curl -H 'Authorization: Bearer abc123' https://x/y"))
    #expect(c.auth == .bearer(ShellWord("abc123")))
    #expect(c.headers.isEmpty)
}

@Test func unknownOptionKeptInOrder() throws {
    let c = try #require(CurlCommand.parse("curl --http2 --resolve x:443:1.2.3.4 https://x/y"))
    #expect(c.other == [
        CurlCommand.Other(option: "--http2", value: nil),
        CurlCommand.Other(option: "--resolve", value: ShellWord("x:443:1.2.3.4")),
    ])
}

@Test func headerWithoutAValueRemovesIt() throws {
    let c = try #require(CurlCommand.parse("curl -H 'Accept:' -H 'X-Empty;' https://x/y"))
    #expect(c.headers == [
        CurlCommand.Header(name: "Accept", value: ShellWord(""), removes: true),
        CurlCommand.Header(name: "X-Empty", value: ShellWord(""), removes: false),
    ])
}

@Test func secondURLGoesToOther() throws {
    let c = try #require(CurlCommand.parse("curl https://a/1 https://b/2"))
    #expect(c.url.string == "https://a/1")
    #expect(c.other == [CurlCommand.Other(option: "", value: ShellWord("https://b/2"))])
}

@Test func userWithoutAColonHasNoPassword() throws {
    let c = try #require(CurlCommand.parse("curl -u alice https://x/y"))
    #expect(c.auth == .basic(user: "alice", password: nil))
}

@Test func oauth2BearerIsAuthToo() throws {
    let c = try #require(CurlCommand.parse("curl --oauth2-bearer $TOKEN https://x/y"))
    #expect(c.auth == .bearer(ShellWord(pieces: [.variable("$TOKEN")])))
}

@Test func outputAndCookiesAndDumpAreCaptured() throws {
    let c = try #require(CurlCommand.parse("curl -O -D headers.txt -w '%{http_code}' -b a=1 -c jar.txt https://x/y"))
    #expect(c.output.remoteName)
    #expect(c.output.dumpHeaders == ShellWord("headers.txt"))
    #expect(c.output.writeOut == ShellWord("%{http_code}"))
    #expect(c.cookies.send == ShellWord("a=1"))
    #expect(c.cookies.jar == ShellWord("jar.txt"))
}

@Test func shortMaxTimeIsTheSameOptionAsTheLongOne() throws {
    let c = try #require(CurlCommand.parse("curl -m 2.5 --connect-timeout 1 https://x/y"))
    #expect(c.timing.maxTime == 2.5)
    #expect(c.timing.connectTimeout == 1)
}

@Test func aNonNumericTimeoutIsKeptRatherThanDropped() throws {
    // Losing it silently would leave the workbench showing a request that is not the one on screen.
    let c = try #require(CurlCommand.parse("curl --max-time later https://x/y"))
    #expect(c.timing.maxTime == nil)
    #expect(c.other == [CurlCommand.Other(option: "--max-time", value: ShellWord("later"))])
}

@Test func doubleDashEndsOptions() throws {
    let c = try #require(CurlCommand.parse("curl -- -weird-host/path"))
    #expect(c.url.string == "-weird-host/path")
    #expect(c.other.isEmpty)
}

@Test func prefixKeepsSudoAndEnvVerbatim() throws {
    let c = try #require(CurlCommand.parse("sudo FOO=bar env curl https://x/y"))
    #expect(c.prefix.map(\.text) == ["sudo", "FOO=bar", "env"])
}

@Test func mixedBodyKindsKeepTheLastOne() throws {
    let c = try #require(CurlCommand.parse("curl -d a=1 --data-binary @f.bin https://x/y"))
    #expect(c.body == .binary(ShellWord("@f.bin")))
}

@Test func urlWithFragmentAndNoPathSplits() throws {
    let c = try #require(CurlCommand.parse("curl 'https://x.dev?a#top'"))
    #expect(c.url.host == "x.dev")
    #expect(c.url.path == "")
    #expect(c.url.query == [CurlCommand.QueryItem(name: "a", value: nil)])
    #expect(c.url.fragment == "top")
    #expect(c.url.string == "https://x.dev?a#top")
}

@Test func pipelineKeepsRedirectionsVerbatim() throws {
    let c = try #require(CurlCommand.parse("curl -s https://x/y && echo done 2>&1"))
    #expect(c.trailingPipeline == "&& echo done 2>&1")
    #expect(c.url.string == "https://x/y")
}

@Test func headerThatIsOnlyAVariableIsKeptWhole() throws {
    // No colon to split on, so it cannot become a name/value pair; `other` round-trips it exactly.
    let c = try #require(CurlCommand.parse("curl -H \"$AUTH_HEADER\" https://x/y"))
    #expect(c.headers.isEmpty)
    #expect(c.other == [CurlCommand.Other(option: "-H", value: ShellWord(pieces: [.variable("$AUTH_HEADER")]))])
}
