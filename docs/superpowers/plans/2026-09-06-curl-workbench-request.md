# Curl Workbench — Request Side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nyx recognises a curl, edits it in a structured sheet, runs it transparently through the shell, reads the status and timing back into the block header, exports it, saves it as a button, and remembers it in the palette.

**Architecture:** All decisions are value types in `Sources/NyxCore/HTTP/` (tokenizer, `CurlCommand` round-trip parser/serialiser with masking, detection, the flags Nyx adds, the exchange parser and HTTP summary, exports, history). `NyxApp` adds the `RequestEditor` sheet, the "⌘E Workbench" pill, routing of the two existing editor keys, block-menu items and the palette section. Lenses and watch are the second plan (`2026-09-06-curl-workbench-response.md`), which consumes `HTTPExchange` from Task 5 here.

**Tech Stack:** Swift 6.0.3 in Swift 5 mode, SwiftPM, swift-testing, AppKit; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-06-curl-workbench-design.md` (§4, §5, §6.1, §8, §9 and the App half of §10 are this plan's).

## Global Constraints

- `NyxCore` imports only Foundation and CNyxPTY; never AppKit, Metal, CoreText, QuartzCore. Everything that decides goes there and is unit-tested.
- Tests are swift-testing (`import Testing`, `@Test`, `#expect`). Hoist mutating calls out of `#expect`/`#require`. If `swift test` hangs before any test runs: `pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test; swift test --no-parallel`.
- The build stays warning-free (`swift build 2>&1 | grep -c warning:` → 0, also with `--build-tests`); `make bench` ≥ 180 MB/s.
- No new key bindings for opening: `edit_and_run_command` (⌘E) and `paste_with_editor` (⌘⇧V) route to the workbench when their text is a curl. New actions: `new_request` (no key), `toggle_http_lens` (⌘⇧J) and `stop_watch` (⌘.) are *declared* in Task 8 and implemented in the response plan.
- Config keys and defaults, verbatim: `http-lens = pretty`, `http-hint = on`, `http-watch-interval = 5`, `http-history = 50`.
- Sentinel line, verbatim: `--nyx-http-- ` followed by nine `-w` variables separated by single spaces: `%{http_code} %{time_total} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{size_download} %{num_redirects} %{content_type}`; the `-w` argument is that line wrapped in `\n…\n` and single quotes. Never `%{json}` (it carries the certificate chain since curl 8.2).
- Masking replaces a secret value with `••••` plus its last four characters (`••••9f2c`); values shorter than eight characters become `••••` alone.
- Every commit carries both trailers: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01YHJ5Uc1qA7f7FHixuhp8Gy`. `git add` by name; never touch `CLAUDE.md`, `.claude/`, `docs/testing.md`, `docs/workflow.md`, `docs/checklist.md`.
- Every piece of chrome gets a `UISnapshot` case per state in both appearances; look at the PNGs before calling a task done.

---

### Task 1: `ShellWords` tokenizer

**Files:**
- Create: `Sources/NyxCore/HTTP/ShellWords.swift`
- Test: `Tests/NyxCoreTests/ShellWordsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct ShellWord: Equatable {
      public enum Piece: Equatable { case text(String), variable(String) }   // variable keeps its `$…` spelling verbatim
      public let pieces: [Piece]
      public var text: String            // pieces joined, variables verbatim
      public var isVariable: Bool        // exactly one piece and it is a variable
      public var containsVariable: Bool
      public init(_ text: String)        // one text piece
      public init(pieces: [Piece])
  }
  public enum ShellWords {
      public static func split(_ line: String) -> [ShellWord]?   // nil on an unterminated quote
      public static func quote(_ word: ShellWord) -> String       // the spelling `CurlCommand.shellLine` uses
  }
  ```

Rules for `split`: whitespace separates words; `'…'` is literal; `"…"` honours `\"`, `\\`, `\$`, and keeps `$VAR`, `${VAR}`, `$(…)` as `.variable` pieces; a bare `\` escapes the next character; `\` followed by a newline is a continuation and vanishes; a bare (unquoted) `$NAME`, `${…}` or `$(…)` is a `.variable` piece; `#` starts a comment only at the start of a word outside quotes. `|`, `||`, `&&`, `;`, `>`, `<`, `2>` are returned as ordinary words (the caller decides what they mean).

Rules for `quote`: a word with only text and no characters outside `[A-Za-z0-9_./:@%=+,-]` is written bare; text containing a single quote is written in double quotes with `\"`, `\\`, `\$` escaped; otherwise single quotes; a word that is exactly one variable is written bare; a word mixing text and variables is written in double quotes with the variables verbatim.

- [ ] **Step 1: Tests** in `ShellWordsTests.swift` (all must fail first):
  - `splitsOnWhitespaceAndKeepsQuotesTogether`: `curl -H 'Accept: application/json' "https://x/y z"` → 4 words with texts `curl`, `-H`, `Accept: application/json`, `https://x/y z`.
  - `backslashNewlineIsAContinuation`: `"curl \\\n  -s \\\n  https://x"` → `curl`, `-s`, `https://x`.
  - `variablesSurvive`: `-H "Authorization: Bearer $TOKEN"` → word 2 pieces `[.text("Authorization: Bearer "), .variable("$TOKEN")]`, `containsVariable == true`, `isVariable == false`; a bare `$TOKEN` word `isVariable == true`.
  - `singleQuotesAreLiteral`: `'$NOT_A_VAR'` → one `.text("$NOT_A_VAR")` piece.
  - `escapesInDoubleQuotes`: `"a \"b\" \\ \$x"` → text `a "b" \ $x`.
  - `unterminatedQuoteIsNil`.
  - `quoteRoundTrips`: for each of `plain`, `has space`, `it's`, `$TOKEN`, `Bearer $TOKEN`, `a"b`: `split(quote(word)) == [word]`.
  - `quoteIsBareWhenSafe`: `quote(ShellWord("https://api.example.com/v1?x=1"))` is unquoted.
- [ ] **Step 2: Run** `swift test --no-parallel --filter ShellWordsTests` → fails to compile.
- [ ] **Step 3: Implement** `ShellWords.swift` as a single-pass scanner over `unicodeScalars` with states `bare`, `single`, `double`; collect pieces, flushing a text piece when a variable begins.
- [ ] **Step 4: Run** the filter → all pass. `swift build 2>&1 | grep -c warning:` → 0.
- [ ] **Step 5: Commit** `git add Sources/NyxCore/HTTP/ShellWords.swift Tests/NyxCoreTests/ShellWordsTests.swift` — "Shell words: a tokenizer that keeps variables as variables".

---

### Task 2: `CurlCommand` — model and parser

**Files:**
- Create: `Sources/NyxCore/HTTP/CurlCommand.swift`
- Create: `Tests/NyxCoreTests/Fixtures/curl/` — 12 fixture files (below) plus `Tests/NyxCoreTests/CurlFixtures.swift` that loads them via `Bundle.module` (add `resources: [.copy("Fixtures")]` to the `NyxCoreTests` target in `Package.swift` if not already present)
- Test: `Tests/NyxCoreTests/CurlCommandParseTests.swift`

**Interfaces:**
- Consumes: `ShellWords.split`, `ShellWord`.
- Produces:
  ```swift
  public struct CurlCommand: Equatable {
      public struct Header: Equatable { public var name: String; public var value: ShellWord; public var removes: Bool }  // `Name:` removes, `Name;` sends empty
      public struct QueryItem: Equatable { public var name: String; public var value: String? }
      public struct URLParts: Equatable {
          public var scheme: String?; public var host: String; public var port: Int?; public var path: String
          public var query: [QueryItem]; public var fragment: String?
          public var raw: ShellWord                              // the word as written, kept for variables/globs
          public var string: String                              // rebuilt from parts when `raw` has no variables, else raw.text
      }
      public enum Body: Equatable {
          case data([ShellWord])                                 // -d/--data, joined with & by curl
          case raw(ShellWord)                                    // --data-raw
          case binary(ShellWord)                                 // --data-binary
          case urlencoded([ShellWord])                           // --data-urlencode
          case json(ShellWord)                                   // --json
          case form([(name: String, value: ShellWord)])          // -F
          case upload(ShellWord)                                 // -T
      }
      public enum Auth: Equatable { case none, basic(user: String, password: ShellWord?), bearer(ShellWord), header(ShellWord) }
      public struct Flags: OptionSet, Equatable { include, silent, showError, location, insecure, compressed, verbose, fail, noBuffer }
      public struct Output: Equatable { public var file: ShellWord?; public var remoteName: Bool; public var dumpHeaders: ShellWord?; public var writeOut: ShellWord? }
      public struct Timing: Equatable { public var maxTime: Double?; public var connectTimeout: Double?; public var retry: Int?; public var retryDelay: Double? }
      public struct Cookies: Equatable { public var send: ShellWord?; public var jar: ShellWord? }
      public struct Other: Equatable { public var option: String; public var value: ShellWord? }

      public var prefix: [ShellWord]           // `FOO=bar`, `sudo`, `time`, `env` words before `curl`, verbatim
      public var method: String?               // nil = curl's default (GET, or POST with a body)
      public var head: Bool                    // -I
      public var get: Bool                     // -G
      public var url: URLParts
      public var headers: [Header]
      public var body: Body?
      public var auth: Auth
      public var flags: Flags
      public var output: Output
      public var timing: Timing
      public var cookies: Cookies
      public var other: [Other]
      public var trailingPipeline: String      // everything from the first top-level `|`, `||`, `&&`, `;` onward, verbatim ("" when none)

      public var effectiveMethod: String       // method ?? (head ? "HEAD" : body == nil || get ? "GET" : "POST")
      public static func parse(_ line: String) -> CurlCommand?
  }
  ```

Parsing rules (implement as a table `[String: OptionKind]` where `OptionKind` is `.flag(keyPath)`, `.value(handler)`; long options accept `--opt value` and `--opt=value`; short options accept `-Hvalue` and `-H value`; a combined short group `-sSL` is split when every letter is a boolean flag, otherwise the first letter takes the rest as its value). Table (short, long → field): `-X/--request` method; `-G/--get`; `-I/--head`; `--url`; `-H/--header`; `-d/--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, `--json`, `-F/--form`, `-T/--upload-file`; `-u/--user`, `--oauth2-bearer`, `--basic`/`--digest` (kept in `other`); `-i/--include`, `-s/--silent`, `-S/--show-error`, `-L/--location`, `-k/--insecure`, `--compressed`, `-v/--verbose`, `-f/--fail`, `-N/--no-buffer`; `-o/--output`, `-O/--remote-name`, `-D/--dump-header`, `-w/--write-out`; `--max-time`, `--connect-timeout`, `--retry`, `--retry-delay`; `-b/--cookie`, `-c/--cookie-jar`. Any other `-x`/`--long` goes to `other` with a value if the next word does not start with `-` and the option is in curl's known value-taking list (`-x --proxy -A --user-agent -e --referer -m --resolve --cacert --cert --key -E --interface --http1.1 --http2 --http3 -4 -6 --proto --ciphers --tlsv1.2 --unix-socket --abstract-unix-socket -r --range -C --continue-at -z --time-cond --limit-rate --max-redirs --retry-max-time --keepalive-time --local-port --dns-servers --path-as-is --request-target --aws-sigv4 --netrc-file --socks5 --socks5-hostname --proxy-user -U --noproxy --alt-svc --etag-save --etag-compare`; boolean ones are `--http1.1 --http2 --http3 -4 -6 --path-as-is --tlsv1.2 --tlsv1.3 --tcp-nodelay --tr-encoding --ipv4 --ipv6 -n --netrc --ssl --ssl-reqd --anyauth --ntlm --negotiate --no-keepalive --disable -q --globoff -g --raw --junk-session-cookies -j --create-dirs --parallel -Z`). A `Authorization: Bearer x` header becomes `auth = .bearer(x)` and is removed from `headers`; any other `Authorization:` header becomes `.header(value)`. The first non-option word is the URL; a second one goes to `other` as `.init(option: "", value: word)`. `URLParts` is parsed by hand (scheme up to `://`, host up to `/`, `?`, `#` or `:`, port digits, path, query split on `&` then `=`, fragment) and never through `Foundation.URL`, which rejects globs and variables. Returns nil when no word after the prefix is `curl`, or when there is no URL.

Fixtures (`Tests/NyxCoreTests/Fixtures/curl/NN-name.sh`, one command each; write them by hand, real shapes): 01-chrome-copy-as-curl (POST, 14 `-H`, `--data-raw` JSON, `--compressed`), 02-postman (`--location --request PUT`, `--header`, `--data '{…}'`), 03-github-api (`-L -H "Accept: …" -H "Authorization: Bearer $GITHUB_TOKEN"`), 04-stripe-basic-auth (`-u sk_test_4eC39HqLyjWDarjtT1zdp7dc:` `-d amount=2000 -d currency=usd`), 05-multiline-continuations, 06-get-with-urlencode (`-G --data-urlencode "q=hello world"`), 07-form-upload (`-F file=@photo.jpg -F 'meta={"a":1};type=application/json'`), 08-json-flag (`--json '{"x":1}'`), 09-body-from-file (`-d @body.json`), 10-pipeline (`curl -s https://x/api | jq '.items[]'`), 11-prefix-and-globs (`API=https://x curl "$API/users/[1-3]" -o "out_#1.json"`), 12-head-and-timeouts (`-I --max-time 5 --retry 3 -k -x http://proxy:3128`).

- [ ] **Step 1: Tests** — one `@Test` per fixture asserting the fields that matter (e.g. 01: `effectiveMethod == "POST"`, `headers.count == 14`, `body == .raw(…)`, `flags.contains(.compressed)`; 03: `auth == .bearer(ShellWord(pieces: [.variable("$GITHUB_TOKEN")]))`, `flags.contains(.location)`; 04: `auth == .basic(user: "sk_test_…", password: ShellWord(""))`, `body == .data([…, …])`; 06: `get == true`, `body == .urlencoded([...])`; 10: `trailingPipeline == "| jq '.items[]'"`, `flags.contains(.silent)`; 11: `prefix == [ShellWord("API=https://x")]`, `url.raw.containsVariable`, `output.file?.text == "out_#1.json"`; 12: `head == true`, `timing.maxTime == 5`, `timing.retry == 3`, `other` contains `-x http://proxy:3128`), plus `notACurlIsNil` (`ls -la`), `curlWithoutURLIsNil` (`curl -s`), `combinedShortFlagsSplit` (`-sSL` → three flags), `combinedShortWithValue` (`-sH 'A: b'` → silent + header), `optionEqualsValue` (`--max-time=10`), `bearerHeaderBecomesAuth`, `unknownOptionKeptInOrder` (`--http2 --resolve x:443:1.2.3.4` → two `other` entries in that order).
- [ ] **Step 2: Run** the filter → compile failure.
- [ ] **Step 3: Implement** `CurlCommand.swift` (model + `parse` + `URLParts.parse`) and the fixture loader.
- [ ] **Step 4: Run** → pass; warnings 0.
- [ ] **Step 5: Commit** — "CurlCommand: every real curl parses, unknown options included".

---

### Task 3: `CurlCommand` — serialiser, masking, round-trip law

**Files:**
- Create: `Sources/NyxCore/HTTP/CurlSerialiser.swift` (an extension of `CurlCommand`)
- Create: `Sources/NyxCore/HTTP/SecretMasking.swift`
- Test: `Tests/NyxCoreTests/CurlSerialiseTests.swift`, `Tests/NyxCoreTests/SecretMaskingTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum Masking: Equatable { case none, display }
  public enum CurlLayout: Equatable { case oneLine, multiline }
  extension CurlCommand {
      public func shellLine(masking: Masking, layout: CurlLayout) -> String
  }
  public enum SecretMasking {
      public static let secretHeaders: Set<String>      // lower-cased: authorization, x-api-key, x-auth-token, api-key, cookie, x-amz-security-token, proxy-authorization
      public static let secretParameters: Set<String>   // lower-cased: token, api_key, apikey, key, secret, password, access_token, client_secret, refresh_token
      public static func masked(_ value: String) -> String        // "••••" + last 4 when count >= 8, else "••••"
      public static func maskedHeaderValue(name: String, value: String) -> String   // "Bearer ••••9f2c" keeps the scheme word
      public static func isSecretHeader(_ name: String) -> Bool
      public static func isSecretParameter(_ name: String) -> Bool
  }
  ```

Serialisation order (spec §5.2): prefix words, `curl`, `-X METHOD` (only when `method != nil`), `-I`, `-G`, flags as one short group in the order `s S L k i v f N` then `--compressed`, headers (`-H 'Name: value'`), auth (`-u user:password` / `--oauth2-bearer x` / `-H 'Authorization: …'`), body, output (`-o`, `-O`, `-D`, `-w`), timing, cookies, `other` in order, the URL, then `trailingPipeline`. `.multiline` puts each group on its own line ending in ` \` with two spaces of indent for continuation lines; `.oneLine` joins with single spaces. Masking `.display` applies `SecretMasking` to header values, `-u` passwords, bearer tokens, query items and `Body.data`/`.urlencoded`/`.form` items whose name is a secret parameter; variables are never masked. URL query is rebuilt from `url.query` unless `url.raw.containsVariable` or the raw contains `[`/`{` (globs), in which case the raw word is written.

- [ ] **Step 1: Tests** — `roundTripLawOverTheCorpus`: for every fixture, `CurlCommand.parse(cmd.shellLine(masking: .none, layout: .oneLine)) == cmd`; `wordsAreStableForUnderstoodOptions`: for fixtures 02, 03, 04, 06, 08, 12 `Set(ShellWords.split(out).map(\.text)) == Set(ShellWords.split(original).map(\.text))`; `multilineBreaksAfterGroups` (fixture 03 has 4 lines, each but the last ends with ` \`); `displayMasksBearer` (`… -H 'Authorization: Bearer ••••9f2c' …` for a 40-char token), `displayMasksBasicPassword` (`-u nik:••••`), `displayMasksQueryToken` (`?token=••••cdef`), `variablesAreNeverMasked` (fixture 03 still shows `$GITHUB_TOKEN`), `shortMaskIsFourDots` (`abc` → `••••`), `bearerKeepsScheme`.
- [ ] **Step 2–4:** fail, implement, pass, warnings 0.
- [ ] **Step 5: Commit** — "CurlCommand writes itself back, masking secrets for the screen".

---

### Task 4: `CurlDetection` and `RequestRun`

**Files:**
- Create: `Sources/NyxCore/HTTP/CurlDetection.swift`, `Sources/NyxCore/HTTP/RequestRun.swift`
- Test: `Tests/NyxCoreTests/CurlDetectionTests.swift`, `Tests/NyxCoreTests/RequestRunTests.swift`

**Interfaces:**
```swift
public enum CurlDetection {
    public static func isCurl(_ line: String) -> Bool     // first command word is `curl` after VAR=…, sudo, time, env, command; pipelines count when curl is first
}
public enum RequestRun {
    public static let sentinelPrefix = "--nyx-http-- "
    public static let writeOutArgument = "\\n--nyx-http-- %{http_code} %{time_total} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{size_download} %{num_redirects} %{content_type}\\n"       // what goes inside the quotes
    public struct Additions: Equatable { public var silent: Bool; public var include: Bool; public var writeOut: Bool }
    public static func additions(for command: CurlCommand) -> Additions
    public static func commandLine(for command: CurlCommand) -> String      // shellLine(.none, .oneLine) with the additions applied to a copy
    public static func note(for command: CurlCommand) -> String?            // "Pipeline present: headers and timing unavailable" or nil
}
```
Rules (spec §5.4): `silent` when neither `.verbose` nor `.noBuffer` nor `.silent` is set (adds `-sS`; if `.silent` is set but not `.showError`, adds `-S`); `include` when none of `head`, `output.file`, `output.remoteName`, `output.dumpHeaders`, `.include` is set and `trailingPipeline` is empty; `writeOut` when `output.writeOut == nil` and `trailingPipeline` is empty.

- [ ] **Step 1: Tests** — detection: `curl https://x` ✓, `API=1 sudo curl …` ✓, `time curl …` ✓, `curl … | jq .` ✓, `cat b | curl -d @- …` ✗, `curlx …` ✗, `echo curl` ✗, empty ✗. Run: `plainGetGetsAllThree` (`-sSi` and the sentinel `-w` present verbatim and the URL still last), `verboseSkipsSilent`, `headSkipsInclude`, `outputFileSkipsInclude`, `pipelineSkipsIncludeAndWriteOut` and `note` non-nil, `userWriteOutIsKept`, `silentWithoutShowErrorAddsS`, `additionsDoNotMutateTheModel`.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5: Commit** — "Recognising a curl, and the visible flags Nyx runs it with".

---

### Task 5: `HTTPExchange` and the block's HTTP summary

**Files:**
- Create: `Sources/NyxCore/HTTP/HTTPExchange.swift`, `Sources/NyxCore/HTTP/HTTPSummary.swift`
- Modify: `Sources/NyxCore/Shell/CommandBlock.swift` (`BlockHeader` gains `httpSummary`), `Sources/NyxCore/Shell/StickyPrompt.swift` (the strip shows the HTTP summary when present)
- Modify: `Sources/NyxApp/Pane.swift` — where headers are built per frame (search `headersOnScreen[` and the `CommandBlock(...).header(now:` calls): for a finished block whose command line `CurlDetection.isCurl`, parse `HTTPExchange` from `outputText(of:)` **once per (command id, contentVersion)** into a `[UInt32: HTTPExchange?]` cache and pass the summary in.
- Test: `Tests/NyxCoreTests/HTTPExchangeTests.swift`, `Tests/NyxCoreTests/HTTPSummaryTests.swift`, extend `BlockHeaderTests`, `StickyPromptTests`

**Interfaces:**
```swift
public struct HTTPExchange: Equatable {
    public struct Head: Equatable { public var version: String; public var status: Int; public var reason: String; public var headers: [(name: String, value: String)] }  // make Equatable via a Header struct
    public enum BodyKind: Equatable { case json, text, binary, empty }
    public struct Timing: Equatable { public var status: Int; public var total: Double; public var nameLookup: Double; public var connect: Double; public var appConnect: Double; public var startTransfer: Double; public var sizeDownload: Int; public var numRedirects: Int; public var contentType: String }
    public var redirects: [Head]
    public var final: Head?
    public var bodyLines: [String]
    public var bodyKind: BodyKind
    public var timing: Timing?
    public var status: Int?                          // final?.status ?? timing status from the sentinel
    public static func parse(lines: [String]) -> HTTPExchange?
    public static func curlFailureReason(exitStatus: Int32) -> String?   // 6 "could not resolve host", 7 "connection refused", 28 "timed out", 35 "TLS handshake failed", 52 "empty reply", 56 "connection reset", 60 "certificate not trusted"
}
public struct HTTPSummary: Equatable {
    public enum Tone: Equatable { case success, redirect, failure }
    public let text: String        // "200 · 142 ms · 1.2 KB · json"
    public let tone: Tone
    public static func make(exchange: HTTPExchange?, exitStatus: Int32?, duration: Double?) -> HTTPSummary?
}
```
Rules: parse head lines matching `^HTTP/[0-9.]+ [0-9]{3}` (a `1xx` head is skipped); `-v` output: drop `* ` and `> ` lines, `< ` lines form a head after stripping the prefix; a line starting with `RequestRun.sentinelPrefix` is split on single spaces into eight numbers (`http_code`, `time_total`, `time_namelookup`, `time_connect`, `time_appconnect`, `time_starttransfer`, `size_download`, `num_redirects`) and the rest of the line is `content_type` (may be empty or contain spaces); a malformed sentinel is ignored; body = lines after the last head's blank line up to the sentinel; `bodyKind`: `.empty` when all blank; `.json` when content-type contains `json` or the trimmed body starts with `{`/`[` and `JSONSerialization` accepts it; `.binary` when a NUL or > 5 % non-printable scalars in the first 4 KB; else `.text`. `parse` returns nil with no head and no sentinel. Summary: `"\(status) · \(ms) ms"` + ` · \(size)` (B / KB one decimal / MB one decimal, from `sizeDownload`) + ` · json` when `.json`; ms from `timing.total` (integer ms; ≥ 1 s shown as `1.4 s`); without a sentinel the time comes from `duration`; without a head but with a non-zero exit: `"exit \(code) · \(reason)"` (or `"exit \(code)"`), tone `.failure`; tone `.success` for 2xx, `.redirect` for 3xx, `.failure` otherwise. `BlockHeader.summary` shows `httpSummary.text` when present, and `BlockHeader.tone` (new: `.success/.redirect/.failure` from the HTTP summary, else derived from `state`) is what `BlockHeaderView` colours the summary with (green = palette index 2, amber = 3, red = 1).

- [ ] **Step 1: Tests** — exchange: `plainJSON200` (head + 2 headers + body + sentinel → status 200, `bodyKind == .json`, `timing?.total == 0.142`), `redirectChain` (301 then 200 → `redirects.count == 1`, `final?.status == 200`), `verboseMode`, `noSentinelStillParsesHead`, `noHeadNoSentinelIsNil`, `continueIsSkipped`, `binaryBody`, `emptyBody204`, `failureReasons` (6, 7, 28, 60, 99→nil). Summary: `success200` → `"200 · 142 ms · 1.2 KB · json"`, `.success`; `notFound` `.failure`; `redirect302` `.redirect`; `curlExit7` → `"exit 7 · connection refused"`; `secondsWhenSlow` → `"200 · 1.4 s"`; `nilWithoutAnything`. Header: `httpSummaryReplacesDuration`; sticky: `stripShowsHTTPSummary`.
- [ ] **Step 2–4:** fail, implement (Core first, then the Pane cache), pass; `make bench` unchanged (the cache must not run on frames whose `contentVersion` did not change).
- [ ] **Step 5:** Snapshot: add UISnapshot cases `block-header-http-{success,redirect,failure}-{dark,light}` by constructing `BlockHeader` values with `httpSummary`; look at them. The summary drawn in the grid goes through `RenderFrame.blockSummaries` (which carries its colour): add a pixel test in `Tests/NyxRenderTests` asserting a `.redirect` summary is drawn in palette index 3 and a `.failure` one in index 1. Commit — "An HTTP block says its status, latency and size in its header".

---

### Task 6: `RequestExport`

**Files:**
- Create: `Sources/NyxCore/HTTP/RequestExport.swift`
- Create: `Tests/NyxCoreTests/Fixtures/export/03-github-api.{http,js,py,go}` — expected outputs for fixture 03, and `01-chrome-copy-as-curl.py`
- Test: `Tests/NyxCoreTests/RequestExportTests.swift`

**Interfaces:**
```swift
public enum ExportFormat: String, CaseIterable, Equatable { case httpie, fetch, pythonRequests, go
    public var title: String   // "HTTPie", "JavaScript fetch", "Python requests", "Go"
}
public enum RequestExport {
    public static func render(_ command: CurlCommand, as format: ExportFormat) -> String
}
```
Each translation covers method, URL (query items as the target's native form), headers, body (JSON bodies as an object literal in fetch/Python when they parse; otherwise a string), auth (basic → `-a` / `auth=` / `SetBasicAuth`; bearer → header), `-L` (`--follow` / `redirect: "follow"` / `allow_redirects=True` / default), `-k` (`--verify=no` / a comment / `verify=False` / `InsecureSkipVerify`), `--max-time` (`--timeout` / `AbortSignal.timeout` / `timeout=` / `client.Timeout`). Options with no equivalent are listed in one trailing comment line: `# not translated: --http2, --resolve …`. Variables are written as `$TOKEN` in HTTPie, `process.env.TOKEN` in fetch, `os.environ["TOKEN"]` in Python, `os.Getenv("TOKEN")` in Go.

- [ ] **Step 1: Tests** — one per format comparing against the fixture file byte-for-byte (write the fixture by hand first, review it as code), `untranslatedOptionsAreListed`, `variablesBecomeEnvLookups`.
- [ ] **Step 2–4:** fail, implement, pass.
- [ ] **Step 5: Commit** — "A request exported as HTTPie, fetch, Python or Go".

---

### Task 7: `RequestHistory` and the palette's Requests section

**Files:**
- Create: `Sources/NyxCore/HTTP/RequestHistory.swift`
- Modify: `Sources/NyxCore/Palette/CommandPalette.swift` (`PaletteItemKind.request(index: Int)`, `PaletteSource.items(... requests: [PaletteItem])`), `Sources/NyxApp/TabController.swift` (build the section; choosing an item opens the workbench — the sheet arrives in Task 9, so until then it opens `CommandEditor` with the line), `Sources/NyxApp/AppDelegate.swift` (one `RequestHistoryStore` per application, file at `~/.config/nyx/requests`)
- Test: `Tests/NyxCoreTests/RequestHistoryTests.swift`, extend `CommandPaletteTests`

**Interfaces:**
```swift
public struct RequestHistory: Equatable {
    public struct Entry: Equatable { public let line: String; public let at: Date }
    public init(limit: Int)
    public var entries: [Entry]                       // newest first
    public mutating func record(_ line: String, at: Date)   // dedups by `CurlCommand.parse(line)` equality (a re-run moves to the top), trims to `limit`; `limit == 0` records nothing
    public static func parse(_ text: String, limit: Int) -> RequestHistory   // one entry per line: "<unix seconds>\t<line>"
    public func serialised() -> String
    public func paletteItems(now: Date, masking: Masking = .display) -> [PaletteItem]   // title "GET api.example.com/users", detail "2 min ago" (RelativeAge: "just now", "N min ago", "N h ago", "yesterday", "N days ago"), searchText = title + host + path + method, kind .request(index)
}
```
App: `RequestHistoryStore` (Foundation only, lives in NyxApp) loads on launch, `record` writes atomically (tmp + rename, 0600) on a serial queue; `Pane` records a line when an HTTP block finishes (Task 5's cache sees a new exchange) and when the sheet runs a request (Task 9).

- [ ] **Step 1: Tests** — `recordsNewestFirst`, `reRunMovesToTop`, `limitTrims`, `zeroLimitRecordsNothing`, `roundTripsThroughText`, `paletteTitlesAreMethodAndHostPath`, `relativeAges`, `secretsMaskedInPalette`; palette: `requestsComeAfterRemote` in `PaletteSource.items`.
- [ ] **Step 2–4:** fail, implement, pass. Snapshot `command-palette-requests-{dark,light}` with three entries; look.
- [ ] **Step 5: Commit** — "The palette remembers your last fifty requests".

---

### Task 8: Config keys and actions

**Files:**
- Modify: `Sources/NyxCore/Config/Config.swift` (`public enum HTTPLens: String, Equatable { case pretty, raw }`; `httpLens: HTTPLens = .pretty`, `httpHint: Bool = true`, `httpWatchInterval: Double = 5`, `httpHistory: Int = 50`; add the four commented lines to `defaultFileText` after `# fold-long-output = 0`), `ConfigParser.swift` (keys `http-lens` pretty|raw, `http-hint` on|off, `http-watch-interval` 1…3600, `http-history` 0…500), `ConfigDiff.swift` (`httpChanged`), `ConfigWriter` needs nothing new, `KeyBinding.swift` (`newRequest = "new_request"`, `toggleHTTPLens = "toggle_http_lens"` ⌘⇧J, `stopWatch = "stop_watch"` ⌘.), `ActionCatalog.swift` (titles "New Request…", "Toggle Pretty Response", "Stop Watching"; `newRequest` in the Shell section after `saveScrollback`; the other two in Go after `notifyWhenDone`), `Sources/NyxApp/TabController.swift` (`case .newRequest`: open the sheet — until Task 9, `CommandEditor` with `curl `; `.toggleHTTPLens` and `.stopWatch`: beep, implemented in the response plan), `docs/configuration.md` (the keys and actions tables)
- Test: `ConfigTests` (defaults, parse, bad value diagnostics, default-file round trip), `ConfigDiffTests`, `ActionCatalogTests`, `KeyBindingTests`

- [ ] **Step 1: Tests** — `httpKeysParse`, `httpKeysHaveDefaults`, `httpBadValuesDiagnose`, `httpChangeIsReported`, `newActionsAreInTheCatalogue`, `defaultChords` (⌘⇧J, ⌘.).
- [ ] **Step 2–4:** fail, implement, pass; the default-file round-trip test passes.
- [ ] **Step 5: Commit** — "Config: http-lens, http-hint, http-watch-interval, http-history; three actions".

---

### Task 9: The `RequestEditor` sheet

**Files:**
- Create: `Sources/NyxCore/HTTP/RequestEditorModel.swift` — the sheet's state as a value type
- Create: `Sources/NyxApp/RequestEditor.swift`
- Modify: `Sources/NyxApp/UISnapshot.swift` (cases per tab and appearance), `Sources/NyxApp/Pane.swift` (`presentRequestEditor(command:then:)` next to `presentCommandEditor`)
- Test: `Tests/NyxCoreTests/RequestEditorModelTests.swift`

**Interfaces:**
```swift
public struct RequestEditorModel: Equatable {
    public enum Tab: String, CaseIterable { case params = "Params", headers = "Headers", body = "Body", auth = "Auth", options = "Options" }
    public var command: CurlCommand
    public var tab: Tab
    public init(command: CurlCommand)
    public var methods: [String]                             // GET POST PUT PATCH DELETE HEAD OPTIONS
    public var preview: String                               // command.shellLine(.display, .multiline)
    public var revealedPreview: String                       // .none
    public var runLine: String                               // RequestRun.commandLine(for:)
    public var runNote: String?                              // RequestRun.note
    public var tabBadges: [Tab: Int]                         // params count, headers count, body 1/0, auth 1/0, options = flags set
    public mutating func setMethod(_ m: String)              // "GET" → method = nil when body == nil, else "GET"
    public mutating func setURLString(_ s: String)           // reparses URLParts; keeps raw when it has variables
    public mutating func setQuery(_ items: [CurlCommand.QueryItem])
    public mutating func setHeaders(_ headers: [CurlCommand.Header])
    public mutating func setBodyText(_ text: String, contentType: String?)   // .raw(text); sets/replaces Content-Type header when given
    public var bodyText: String                              // text of the body when it is data/raw/binary/json; "" otherwise
    public var bodyIsJSON: Bool
    public mutating func prettyPrintBody() -> Bool           // JSONSerialization with .prettyPrinted/.sortedKeys off; false when not JSON
    public mutating func setAuth(_ a: CurlCommand.Auth)
    public mutating func toggle(_ flag: CurlCommand.Flags)
    public mutating func setTiming(maxTime: Double?, retry: Int?)
    public enum OutputMode: String, CaseIterable { case headersAndBody = "Headers and body", bodyOnly = "Body only", statusOnly = "Status line only", saveBody = "Save body to file…" }
    public var outputMode: OutputMode                        // derived from flags/output; setter rewrites them: bodyOnly clears .include, statusOnly = -o /dev/null -w '%{http_code}\n' plus the sentinel, saveBody = -o <path>
    public mutating func setOutputMode(_ m: OutputMode, savePath: String?)
    public static func newRequest() -> RequestEditorModel     // `curl https://` with tab .params
}
```
Sheet (AppKit, 720×480, resizable): top row — method `NSPopUpButton`, URL `NSTextField` (monospaced); `NSSegmentedControl` for the five tabs with badges in the labels ("Headers 14"); per tab: Params and Headers are `NSTableView`s with name/value columns, `+`/`−` buttons, secrets shown masked with a reveal checkbox; Body is an `NSTextView` with a Content-Type popup (application/json, application/x-www-form-urlencoded, text/plain, custom) and a "Pretty-print" button; Auth is a popup (None, Basic, Bearer, Header) with the fields it needs; Options has checkboxes for `-L follow redirects`, `-k allow insecure TLS`, `--compressed`, `-v verbose`, `-f fail on 4xx/5xx`, numeric fields for max time and retries, and the Output mode popup. Bottom: a read-only preview (`preview`, masked; "Reveal" checkbox flips to `revealedPreview`), the `runNote` line when non-nil, buttons `Cancel`, `Copy` (copies `revealedPreview` one-line), `Export ▾` (the four formats → pasteboard), `Save ▾` (menu: `Save as Button…` opens `QuickActionEditor` prefilled with `name = "<METHOD> <host><path>"`, `.send`, the one-line command; on finish appends through the same path the tab bar's editor uses; `Save to Project…` writes the same line into the pane's cwd `.nyx` as Task 10 describes), `Run ▾` (default; menu: Run, Run every…, Run 10 times, Run until 200 — the menu items other than Run call `onWatch(WatchPlan)` which Task 9 leaves as a stored closure the response plan wires). Return in the URL field = Run. Esc = Cancel. `onFinish: ((String?) -> Void)?` receives `runLine` or nil, like `CommandEditor`.

- [ ] **Step 1: Model tests** — `setMethodGETClearsExplicitMethodWithoutBody`, `setURLKeepsRawWithVariables`, `setBodyTextSetsContentType`, `prettyPrintBody`, `outputModeRoundTrip` (each mode set then read back), `statusOnlyKeepsSentinel`, `badgesCountThings`, `previewIsMaskedAndRevealIsNot`, `newRequestIsAGETWithEmptyHost`.
- [ ] **Step 2–4:** fail, implement the model, pass.
- [ ] **Step 5: The sheet** — build `RequestEditor` on `RequestEditorModel`; every control's action mutates the model and re-renders (one `render()` method reading the model; no state in the views). Presentation: copy `presentCommandEditor`'s sheet-window code path (contentViewController, not contentView).
- [ ] **Step 6: Snapshots** — `request-editor-{params,headers,body,auth,options}-{dark,light}` on fixture 01's command, plus `request-editor-pipeline-note-dark` on fixture 10. Look at every one: badges readable, masked values, the preview wraps, the note visible.
- [ ] **Step 7: Commit** — "The request editor: a curl as a form".

---

### Task 10: Wiring — pill, editor keys, block menu, palette, rung 6

**Files:**
- Create: `Sources/NyxCore/HTTP/WorkbenchHint.swift` — `public enum WorkbenchHint { public static func text(chord: String) -> String  // "\(chord) Workbench"; public static func shouldShow(commandLine: String, hintEnabled: Bool, altScreen: Bool) -> Bool }`
- Modify: `Sources/NyxApp/Pane.swift`:
  - after `performPaste` of a curl (`CurlDetection.isCurl(text)`) and `config.httpHint`, show the pill: a small rounded label drawn by a new `WorkbenchHintView` (NyxApp, same style as `RemoteStripView`'s button) placed at the end of the current command line's last row (use `CommandBlockChrome.summaryPlacement` on the bottom prompt's rows), hidden on the next key press or after 8 s, and clicking it opens the workbench;
  - `pasteWithEditor()`: when `CurlDetection.isCurl(text)` and `CurlCommand.parse(text)` succeeds → `presentRequestEditor`; else the plain editor;
  - `editAndRunCommand(atAbsoluteRow:)` and `editCurrentInput`: same routing;
  - `perform(_ action: BlockAction, on:)`: new cases `.openInWorkbench`, `.copyAs(ExportFormat)`, `.saveAsButton`, `.saveToProject` (writes `quick = <name> | send | <line>` into the pane's cwd `.nyx` through `ProjectActionsFile` — appending to the existing text — and lets the existing approval gate re-ask, since the digest changed) (Core: `BlockAction` gains them; `BlockHeader.actions` includes them only when `isHTTP` — a new `BlockHeader.isHTTP: Bool` set from `CurlDetection.isCurl(commandLine)`; menu group "Request" after `.editAndRun`);
  - when the sheet's `onFinish` gives a line: `send` it as a paste + `\r` (bracketed), and `RequestHistoryStore.record(line)`.
- Modify: `Sources/NyxApp/TabController.swift`: `.newRequest` opens `presentRequestEditor(command: RequestEditorModel.newRequest().command)`; the palette's `.request(index)` opens the sheet with the entry's line; `ActionCatalog`/menu validation greys `Open in Workbench` when the block is not HTTP.
- Modify: `docs/architecture.md` (a `HTTP/` row in the NyxCore table; "Where to add things": "A request feature"), `docs/status.md` (Done: the request side), `README.md` (one paragraph under features).
- Test: `Tests/NyxCoreTests/WorkbenchHintTests.swift`, `BlockHeaderTests` (`httpBlocksOfferTheRequestGroup`, `plainBlocksDoNot`), snapshots `workbench-hint-{dark,light}`.

- [ ] **Step 1: Tests and Core changes** — hint rules (`shouldShow` false when hint off, on alt screen, or when the line is not a curl), the `BlockAction` additions and their titles ("Open in Workbench…", "Copy as HTTPie", …, "Save as Button…").
- [ ] **Step 2: App wiring** as listed.
- [ ] **Step 3: Rung 6** — temporary `NYX_SMOKE_QA=workbench` hook in `AppDelegate`: start `python3 -m http.server` on a free port serving a `fixtures/` directory with `users.json`, paste `curl -sS http://127.0.0.1:PORT/users.json`, assert the pill is visible, trigger ⌘E, assert the sheet is up with tab Params, set a header through the model, run, wait for the block, assert the header summary matches `^200 · \d+ ms · [\d.]+ K?B · json$`, assert the history file has one line, open the block's ⋯ menu and assert the Request group is present, `Save as Button` → assert a `quick =` line was written to a temp config. Print each assertion; remove the hook before the final commit (`grep -rn NYX_SMOKE_QA Sources Tests` → nothing).
- [ ] **Step 4: Ladder** — warnings 0 (library and tests), `swift test --no-parallel` count, `make bench`, `NYX_UI_SNAPSHOT` PNGs looked at.
- [ ] **Step 5: Commit** — "The workbench is reachable: pill, ⌘E, ⌘⇧V, the block menu, the palette".
