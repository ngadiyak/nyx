import Foundation
import Testing
@testable import NyxCore

/// Loads `Fixtures/export/<name>.<ext>`, the expected output of `RequestExport.render` for one
/// curl fixture and one format -- written by hand first, the same discipline `CurlFixtures` uses
/// for the curl side.
private func exportFixture(_ name: String, _ ext: String) throws -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/export") else {
        throw CurlFixtures.Missing(name: "\(name).\(ext)", reason: "not in the test bundle")
    }
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Fixture 01: a Chrome "copy as cURL" POST -- 14 headers, a JSON body with a real
// newline inside a string value, one untranslated flag (`--compressed`).

@Test func fixture01AsHTTPie() throws {
    let command = try CurlFixtures.command("01-chrome-copy-as-curl")
    let expected = try exportFixture("01-chrome-copy-as-curl", "http")
    #expect(RequestExport.render(command, as: .httpie) == expected)
}

@Test func fixture01AsFetch() throws {
    let command = try CurlFixtures.command("01-chrome-copy-as-curl")
    let expected = try exportFixture("01-chrome-copy-as-curl", "js")
    #expect(RequestExport.render(command, as: .fetch) == expected)
}

@Test func fixture01AsPython() throws {
    let command = try CurlFixtures.command("01-chrome-copy-as-curl")
    let expected = try exportFixture("01-chrome-copy-as-curl", "py")
    #expect(RequestExport.render(command, as: .pythonRequests) == expected)
}

@Test func fixture01AsGo() throws {
    let command = try CurlFixtures.command("01-chrome-copy-as-curl")
    let expected = try exportFixture("01-chrome-copy-as-curl", "go")
    #expect(RequestExport.render(command, as: .go) == expected)
}

// MARK: - Fixture 03: a GitHub API GET -- `-L`, a bearer token behind `$GITHUB_TOKEN`, two plain
// headers, two query parameters, nothing left untranslated.

@Test func fixture03AsHTTPie() throws {
    let command = try CurlFixtures.command("03-github-api")
    let expected = try exportFixture("03-github-api", "http")
    #expect(RequestExport.render(command, as: .httpie) == expected)
}

@Test func fixture03AsFetch() throws {
    let command = try CurlFixtures.command("03-github-api")
    let expected = try exportFixture("03-github-api", "js")
    #expect(RequestExport.render(command, as: .fetch) == expected)
}

@Test func fixture03AsPython() throws {
    let command = try CurlFixtures.command("03-github-api")
    let expected = try exportFixture("03-github-api", "py")
    #expect(RequestExport.render(command, as: .pythonRequests) == expected)
}

@Test func fixture03AsGo() throws {
    let command = try CurlFixtures.command("03-github-api")
    let expected = try exportFixture("03-github-api", "go")
    #expect(RequestExport.render(command, as: .go) == expected)
}

// MARK: - Fixture 06: `-G` with two `--data-urlencode` pairs and no query of its own -- the pairs
// become the whole query, in every target's own query-building call rather than a body.

@Test func fixture06AsHTTPie() throws {
    let command = try CurlFixtures.command("06-get-with-urlencode")
    let expected = try exportFixture("06-get-with-urlencode", "http")
    #expect(RequestExport.render(command, as: .httpie) == expected)
}

@Test func fixture06AsFetch() throws {
    let command = try CurlFixtures.command("06-get-with-urlencode")
    let expected = try exportFixture("06-get-with-urlencode", "js")
    #expect(RequestExport.render(command, as: .fetch) == expected)
}

@Test func fixture06AsPython() throws {
    let command = try CurlFixtures.command("06-get-with-urlencode")
    let expected = try exportFixture("06-get-with-urlencode", "py")
    #expect(RequestExport.render(command, as: .pythonRequests) == expected)
}

@Test func fixture06AsGo() throws {
    let command = try CurlFixtures.command("06-get-with-urlencode")
    let expected = try exportFixture("06-get-with-urlencode", "go")
    #expect(RequestExport.render(command, as: .go) == expected)
}

// MARK: - Rules the two fixtures do not each exercise

/// Every option this model has no field for, plus the flags with no target-language equivalent,
/// land in one trailing comment -- and nothing else does, so a translated option never shows up
/// twice.
@Test func untranslatedOptionsAreListed() throws {
    let command = try #require(CurlCommand.parse(
        "curl -N -f --http2 --resolve api.example.com:443:127.0.0.1 https://api.example.com/x"))

    for format in ExportFormat.allCases {
        let rendered = RequestExport.render(command, as: format)
        let prefix = format == .fetch || format == .go ? "// not translated: " : "# not translated: "
        #expect(rendered.contains("\(prefix)-f, -N, --http2, --resolve api.example.com:443:127.0.0.1"))
    }
}

/// A command with nothing left over gets no comment at all -- fixture 03 already covers this for
/// real output, this pins the absence explicitly so a regression that always appends a trailing
/// newline-plus-comment could not slip through unnoticed.
@Test func noCommentWhenNothingIsUntranslated() throws {
    let command = try CurlFixtures.command("03-github-api")
    for format in ExportFormat.allCases {
        #expect(!RequestExport.render(command, as: format).contains("not translated"))
    }
}

/// `$TOKEN` becomes an environment lookup in every format but HTTPie, where it is still a shell
/// command and `$TOKEN` already means "look this up" without Nyx doing anything to it.
@Test func variablesBecomeEnvLookups() throws {
    let command = try #require(CurlCommand.parse(
        "curl -H \"X-Api-Key: $API_KEY\" https://api.example.com/x"))

    #expect(RequestExport.render(command, as: .httpie).contains("\"X-Api-Key:$API_KEY\""))
    #expect(RequestExport.render(command, as: .fetch).contains("\"X-Api-Key\": `${process.env.API_KEY}`,"))
    #expect(RequestExport.render(command, as: .pythonRequests).contains("\"X-Api-Key\": os.environ[\"API_KEY\"],"))
    #expect(RequestExport.render(command, as: .pythonRequests).contains("import os\n"))
    #expect(RequestExport.render(command, as: .go).contains("req.Header.Set(\"X-Api-Key\", os.Getenv(\"API_KEY\"))"))
}

/// A variable used *inside* a larger value takes each language's embedding form rather than its
/// standalone one -- a bearer token is the case that comes up constantly, so this is fixture 03's
/// own shape, spelled out explicitly against each of the brief's four forms.
@Test func variablesEmbeddedInALargerValueAreInterpolatedNotSubstituted() throws {
    let command = try CurlFixtures.command("03-github-api")

    #expect(RequestExport.render(command, as: .httpie).contains("\"Authorization:Bearer $GITHUB_TOKEN\""))
    #expect(RequestExport.render(command, as: .fetch).contains("`Bearer ${process.env.GITHUB_TOKEN}`"))
    #expect(RequestExport.render(command, as: .pythonRequests).contains("f\"Bearer {os.environ['GITHUB_TOKEN']}\""))
    #expect(RequestExport.render(command, as: .go).contains("\"Bearer \"+os.Getenv(\"GITHUB_TOKEN\")"))
}

/// Basic auth has a dedicated spelling in three of the four formats, and fetch's own translation
/// -- the brief's point -- happens to *be* a header built with `btoa`, not a fallback to one.
@Test func basicAuthUsesEachFormatsOwnMechanism() throws {
    let command = try #require(CurlCommand.parse("curl -u nik:s3cret https://api.example.com/x"))

    #expect(RequestExport.render(command, as: .httpie).contains("-a nik:s3cret"))
    #expect(RequestExport.render(command, as: .fetch).contains("\"Authorization\": `Basic ${btoa(\"nik:s3cret\")}`,"))
    #expect(RequestExport.render(command, as: .pythonRequests).contains("auth=(\"nik\", \"s3cret\"),"))
    #expect(RequestExport.render(command, as: .go).contains("req.SetBasicAuth(\"nik\", \"s3cret\")"))
}

/// `-L`, `-k` and `--max-time` each take the brief's per-format spelling, including Go's for
/// `-L`: curl needed a flag to follow redirects, `net/http`'s client already does by default, so
/// the only correct translation is to write nothing.
@Test func locationInsecureAndMaxTimeTranslatePerFormat() throws {
    let command = try #require(CurlCommand.parse("curl -L -k --max-time 30 https://api.example.com/x"))

    let httpie = RequestExport.render(command, as: .httpie)
    #expect(httpie.contains("--follow"))
    #expect(httpie.contains("--verify=no"))
    #expect(httpie.contains("--timeout=30"))

    let fetch = RequestExport.render(command, as: .fetch)
    #expect(fetch.contains("redirect: \"follow\","))
    #expect(fetch.contains("signal: AbortSignal.timeout(30000),"))
    #expect(fetch.contains("-k: fetch cannot disable TLS certificate verification"))

    let python = RequestExport.render(command, as: .pythonRequests)
    #expect(python.contains("allow_redirects=True,"))
    #expect(python.contains("verify=False,"))
    #expect(python.contains("timeout=30,"))

    let go = RequestExport.render(command, as: .go)
    #expect(go.contains("InsecureSkipVerify: true"))
    #expect(go.contains("Timeout: 30 * time.Second,"))
    #expect(!go.contains("CheckRedirect")) // net/http already follows redirects by default
}

/// HTTPie's `field=value` items only stand in for a JSON body when every value is a string --
/// anything else (nesting, a bool, a number) has no lossless `field=value` spelling, and falls
/// back to `--raw`. Fixture 01 already covers the fallback; this covers the flat case the brief
/// names explicitly.
@Test func httpieFlatJSONObjectBecomesFieldItems() throws {
    let command = try #require(CurlCommand.parse(
        "curl --json '{\"name\":\"Ada\",\"role\":\"admin\"}' https://api.example.com/x"))
    let rendered = RequestExport.render(command, as: .httpie)
    #expect(rendered.contains("name=Ada"))
    #expect(rendered.contains("role=admin"))
    #expect(!rendered.contains("--raw"))
}

/// Whether `needles` each appear in `haystack`, in that order -- used below where the thing that
/// matters is the *sequence* the three `-G` items come out in, not just that each one is present
/// somewhere.
private func appearsInOrder(_ needles: [String], in haystack: String) -> Bool {
    var searchStart = haystack.startIndex
    for needle in needles {
        guard let range = haystack.range(of: needle, range: searchStart ..< haystack.endIndex) else { return false }
        searchStart = range.upperBound
    }
    return true
}

/// `-G` puts the URL's own query first, then the `-d` pairs in the order they were written --
/// never re-sorted (Go's `url.Values.Encode()` would; that is exactly why `renderGo` does not use
/// it) and never turned into a body, in any of the four targets.
@Test func getWithDataBecomesQueryItemsInOrderNotABody() throws {
    let command = try #require(CurlCommand.parse("curl -G -d a=1 -d 'b=x y' 'https://x/p?c=3'"))

    let httpie = RequestExport.render(command, as: .httpie)
    #expect(appearsInOrder(["c==3", "a==1", "'b==x y'"], in: httpie))
    #expect(!httpie.contains("--raw"))

    let fetch = RequestExport.render(command, as: .fetch)
    #expect(fetch.contains("new URLSearchParams()"))
    #expect(appearsInOrder(["params.append(\"c\", \"3\")", "params.append(\"a\", \"1\")", "params.append(\"b\", \"x y\")"], in: fetch))
    #expect(fetch.contains("method: \"GET\","))
    #expect(!fetch.contains("body:"))

    let python = RequestExport.render(command, as: .pythonRequests)
    #expect(appearsInOrder(["\"c\": \"3\",", "\"a\": \"1\",", "\"b\": \"x y\","], in: python))
    #expect(!python.contains("data="))

    let go = RequestExport.render(command, as: .go)
    #expect(go.contains("net/url"))
    #expect(appearsInOrder([
        "url.QueryEscape(\"c\") + \"=\" + url.QueryEscape(\"3\")",
        "url.QueryEscape(\"a\") + \"=\" + url.QueryEscape(\"1\")",
        "url.QueryEscape(\"b\") + \"=\" + url.QueryEscape(\"x y\")",
    ], in: go))
    #expect(go.contains("http.NewRequest(\"GET\", \"https://x/p\"+\"?\"+query, nil)"))
}
