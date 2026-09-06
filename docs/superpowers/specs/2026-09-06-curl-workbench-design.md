# Curl workbench — design

Date: 2026-09-06. Status: approved in chat (four scope decisions, below); spec awaiting the owner's read.

## 1. What this is

Nyx recognises a `curl` command — pasted, typed, or sitting in the scrollback — and turns the
terminal into a place where an HTTP request can be read, changed, run, watched and shared without
leaving the shell. Three people are being served:

- **Developer:** "copy as cURL" from the browser, change one header and the body, run it, read the
  JSON without squinting, run it again after a code change and see what differs.
- **Tester:** the same request every five seconds while a deploy rolls, a coloured timeline of
  status codes, latency percentiles after twenty runs, the run that broke folded open by itself.
- **DevOps:** a health check polled until it answers 200, the request saved as a button on the tab
  bar or in the project's `.nyx`, and the whole thing handed to a colleague as HTTPie or Python.

Nothing here replaces the shell. Every request runs as an ordinary command in the user's own shell,
appears in the transcript exactly as it ran, lands in shell history, and works over ssh and in a
remote session. The workbench is a better way to *write* the command and a better way to *read*
what came back.

## 2. Decisions taken with the owner (2026-09-06)

| Question | Decision |
|---|---|
| How a request runs | **Transparently through the shell.** Nyx appends visible flags to the curl it runs (`-sS`, `-i`, `-w` with a one-line timing sentinel) and parses the block's output. The transcript shows exactly what ran. |
| Where the workbench lives | **A sheet for editing, lenses in the block.** The editor is a structured sheet in the place of today's ⌘⇧V editor; the response stays in the normal output block, read through lenses; watch and repeat are states of a block. |
| Trigger on paste | **Hint + the existing editor keys.** A pasted curl lands on the prompt as today, with a pill at the end of the command line: "⌘E Workbench". ⌘E (edit the command line) on a curl opens the workbench, and ⌘⇧V (paste through the editor) with a curl on the clipboard opens it too; on anything else both open the plain editor as now. "Open in Workbench…" is in every curl block's ⋯ menu; "New Request…" is in the palette. |
| v1 scope | Editor + lenses; watch / repeat / poll; export and saving (buttons, `.nyx`, history in the palette). **Assertions and secret masking in export are v2**, except that the visible command in the sheet and the block masks secrets from day one (§5.3), because a screenshot is the most common leak. |

## 3. Architecture

Everything that decides something is a value type in `NyxCore/HTTP/` with tests; `NyxApp` draws
the sheet, the pill, the menu items and the timeline, and sends bytes to the shell. No new module.

```
NyxCore/HTTP/
  ShellWords.swift        tokenizer: quotes, backslashes, `\`-newline continuations, $VAR kept verbatim
  CurlCommand.swift       the model + parse(from: String) + shellLine(masking:) round trip
  CurlDetection.swift     is this command line a curl? (after env assignments / sudo / time)
  RequestRun.swift        the flags Nyx adds to run a request, and the sentinel line
  HTTPExchange.swift      parse a block's output rows into head(s), headers, body, timing
  JSONDocument.swift      tolerant JSON tree, pretty printer, fold points, path subset
  ResponseLens.swift      which view of an exchange to show; lens lines with styles
  LensBuffer.swift        lens lines materialised as Rows; the display mapping over a region
  WatchSeries.swift       interval / count / until state machine with an injected clock; stats
  RequestExport.swift     HTTPie, fetch, Python requests, Go
  RequestHistory.swift    last N parsed requests, persistence format
NyxApp/
  RequestEditor.swift     the sheet
  Pane.swift              pill, lens rendering hook, watch scheduling, block menu additions
  TabController.swift     palette "Requests" section, New Request…, quick-action saving
```

Data flow for one request:

1. `Pane.paste` (or ⌘E / ⌘⇧V, or a block action) → `CurlDetection.isCurl(commandLine)` → `CurlCommand.parse`.
2. `RequestEditor` edits a `CurlCommand`; the preview shows `command.shellLine(masking: .display)`.
3. Run → `RequestRun.commandLine(for: command)` (the user's curl plus the flags in §5.4) → sent to the shell as a typed line. The shell runs it; OSC 133 marks make it a block.
4. When the block finishes (`CommandWatcher`), `HTTPExchange.parse(outputLines:)` → the block header gets the HTTP summary (§6.1); if the body is JSON and the default lens is `pretty`, `LensBuffer` replaces the output rows in the display (§6.2).
5. A watch series (§7) re-sends the same line on schedule; each run is a new block; the series' timeline and stats sit on the newest block.

## 4. Recognising a curl

`CurlDetection.isCurl(_ line: String) -> Bool` is true when the first command word is `curl` after
skipping leading `VAR=value` assignments, `sudo`, `time`, `env`, and `command`. A pipeline whose
*first* command is curl counts (`curl … | jq .`); the workbench edits the curl and keeps the rest of
the pipeline verbatim as `CurlCommand.trailingPipeline`. A curl that is not the first command
(`cat body.json | curl -d @- …`) is not recognised in v1 (§11).

`xh`, `http` (HTTPie) and `wget` are **not** recognised in v1 (§11).

## 5. The model: `CurlCommand`

### 5.1 Parse

`CurlCommand.parse(_ line: String) -> CurlCommand?` tokenizes with `ShellWords` (single quotes,
double quotes with `\"` and `\\`, bare backslash escapes, `\`+newline continuations dropped,
`$VAR`/`${VAR}`/`$(…)` kept verbatim as a token piece flagged `isVariable`), then reads curl's
options in order. Understood options (long and short, `--opt=value` and `--opt value`):

| Field | Options |
|---|---|
| `method` | `-X/--request`, `-G/--get` (moves `-d` data to the query), `-I/--head` |
| `url` | first non-option word or `--url`; parsed into scheme, host, port, path, query items; globbing `{}`/`[]` left as text |
| `headers` | `-H/--header` (repeatable; `Name: value`; `Name;` for empty; `Name:` removes) |
| `body` | `-d/--data`, `--data-raw`, `--data-binary`, `--data-urlencode`, `--json` (sets Content-Type and Accept), `-F/--form` (multipart items), `-T/--upload-file`; `@file` and `@-` references kept as references |
| `auth` | `-u/--user`, `--basic`, `--digest`, `--oauth2-bearer`; a `Authorization:` header is recognised as auth too |
| `flags` | `-i/--include`, `-s/--silent`, `-S/--show-error`, `-L/--location`, `-k/--insecure`, `--compressed`, `-v/--verbose`, `-f/--fail`, `-N/--no-buffer` |
| `output` | `-o/--output`, `-O/--remote-name`, `-D/--dump-header`, `-w/--write-out` |
| `timing` | `--max-time`, `--connect-timeout`, `--retry`, `--retry-delay` |
| `cookies` | `-b/--cookie`, `-c/--cookie-jar` |
| `other` | every option not listed above, kept verbatim in order with its value (`-x proxy`, `--http2`, `--resolve`, …) |

Combined short flags (`-sSL`) are split. Parsing never fails on an unknown option — it is kept in
`other` — so every curl round-trips. It returns nil only when the line is not a curl at all or has
no URL.

### 5.2 Serialise

`shellLine(masking: Masking, layout: Layout) -> String` writes the command back:

- Option order: `curl`, method, flags (as one `-sSL` group when all short), headers (each `-H` on
  its own line in `.multiline` layout), auth, body, output, timing, cookies, `other` in original
  order, the URL last, then `trailingPipeline`.
- Quoting: single quotes unless the value contains a single quote (then `"…"` with escapes); a
  value that is entirely a variable reference is left unquoted so the shell expands it; a value
  with `isVariable` pieces inside text uses double quotes.
- Layout `.multiline` breaks after each option group with `\` and two spaces of indent; `.oneLine`
  joins with single spaces. The sheet shows multiline; the shell gets one line (a multi-line paste
  into the shell's line editor is what the whole editor exists to avoid).
- Round-trip law, tested over a corpus: `parse(x.shellLine(.none, .oneLine)) == x` for every
  parsed `x`, and `ShellWords.split(x.shellLine(...)) == ShellWords.split(original)` modulo quoting
  style for a curl whose options are all understood.

### 5.3 Masking

`Masking.display` replaces the value part of secrets with `••••` plus the last four characters:
`Authorization: Bearer ••••9f2c`, `-u nik:••••`, `--oauth2-bearer ••••`, headers named
`X-API-Key`, `X-Auth-Token`, `Api-Key`, `Cookie`, and query items or form fields named `token`,
`api_key`, `apikey`, `key`, `secret`, `password`, `access_token` (case-insensitive). A variable
reference is never masked (it is not a secret, it is a name). `Masking.none` writes everything.

The sheet's preview and the block's command row use `.display`; the line sent to the shell,
"Copy Command", exports and history use `.none` (v2 adds masked export).

### 5.4 Running: `RequestRun`

`RequestRun.commandLine(for: CurlCommand) -> String` returns the user's curl plus, when absent:

- `-sS` unless `-v` or `-N` is set (progress meter lines would corrupt the exchange parse; `-S`
  keeps errors visible),
- `-i` unless `-I`, `-o`, `-O` or `-D` is set (headers are what the lenses read),
- `-w '\n--nyx-http-- %{http_code} %{time_total} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{size_download} %{num_redirects} %{content_type}\n'` unless `-w` is set — nine
  space-separated variables, content type last because it may contain spaces; `url_effective` is
  not included (the redirect chain in the headers says where the request went). Not `%{json}`:
  since curl 8.2 it carries the whole certificate chain, several kilobytes per request in the
  transcript. If the block's output has no sentinel line the summary shows what it can from the
  status line alone.

The additions are visible in the transcript. The sentinel line is drawn like any other output row
in the raw lens; every other lens hides it and shows its content as the latency line (§6.1).

A trailing pipeline (`| jq .`) is kept after the additions, so `curl … -i -w … | jq .` would break
jq: when `trailingPipeline` is non-empty, `-i` and `-w` are **not** added, the block shows the
pipeline's output, and the summary is limited to exit status and duration. The sheet says so in
its Options tab ("Pipeline present: headers and timing unavailable").

## 6. Reading the response

### 6.1 `HTTPExchange`

`HTTPExchange.parse(lines: [String]) -> HTTPExchange?` reads a finished block's output:

- Zero or more response heads (`HTTP/1.1 301 Moved Permanently` … blank line), the last one is
  `final`, the rest are `redirects`; `HTTP/2 200` and `HTTP/1.0` accepted; a `100 Continue` head is
  skipped.
- With `-v`, lines starting `* `, `> ` are dropped and `< ` lines form the head.
- The body is everything between the last head's blank line and the sentinel line (or the end).
- The sentinel line gives `status`, `timeTotal`, `timeNamelookup`, `timeConnect`,
  `timeAppconnect`, `timeStarttransfer`, `sizeDownload`, `numRedirects`, `contentType` — eight
  numbers then the content type to the end of the line.
- `bodyKind`: `.json` when Content-Type says so *or* the body parses as JSON; `.text`; `.binary`
  (a NUL or > 5 % non-printables in the first 4 KB); `.empty`.

Returns nil when there is no head and no sentinel: the block is then an ordinary block.

**Block summary** (replaces `BlockHeader.summary` for HTTP blocks): `200 · 142 ms · 1.2 KB · json`;
`404 · 89 ms`; `exit 7 · could not resolve host` when curl failed before a response (curl's exit
codes 6, 7, 28, 35, 52, 56, 60 get a short reason). Colour: 2xx green, 3xx amber, 4xx/5xx and curl
failures red, in the block's existing state colours. The sticky prompt strip shows the same summary.

### 6.2 Lenses

`ResponseLens` is what to show instead of the raw rows:

| Lens | Shows |
|---|---|
| `.raw` | the rows as printed (no replacement) |
| `.pretty` | headers folded to one line (`▸ 12 headers · content-type: application/json`), then the body pretty-printed with 2-space indent, arrays and objects foldable per node, keys/strings/numbers/literals coloured; the latency line last |
| `.headers` | the final head and its headers, one per line, plus the redirect chain |
| `.body` | the body only, pretty if JSON |
| `.filter(path)` | the JSON at `path` (§6.3), pretty |
| `.grep(pattern)` | body lines matching the pattern, with the match highlighted, line numbers |
| `.diff(previous)` | the pretty body against the previous run of the same request in the series (§7): removed lines red, added green, unchanged dim; a header line `3 lines changed · status 200 → 200 · 142 ms → 138 ms` |

A lens produces `[LensLine]` — text plus style spans (`key`, `string`, `number`, `literal`,
`header`, `added`, `removed`, `dim`, `match`) and, for foldable nodes, a `foldID` and depth.
`LensBuffer` turns them into `Row`s in the terminal's cell format with the theme's colours, so the
renderer draws them like any other row and the row cache works unchanged.

**Display mapping.** `DisplayRow` gains `.lens(commandID: UInt32, line: Int)`. When a block has a
lens other than `.raw`, `Terminal.displayRows(...)` maps its output rows to the lens's lines
(fewer or more than the output rows). The fold placeholder rule already does this for fewer rows;
the viewport arithmetic (`snapViewportOutOfFold`, cursor slot, hover placement) is extended the
same way, with tests per function. Selection over lens rows selects lens text (the `LensBuffer`
rows are a second selection domain; a drag that starts on a lens row stays inside that lens) and
copies what is visible. "Copy Output" copies the lens text; "Copy Body" and "Copy Headers" appear
for HTTP blocks and copy the raw parts.

**Default lens** is `http-lens` (§9): `pretty` for JSON bodies, `raw` otherwise. Switching: the
hover overlay gets a `{ }` button for HTTP blocks, the ⋯ menu gets a Lens submenu, ⌘⇧J toggles
pretty ↔ raw on the block under the pointer or the last HTTP block. A lens is per block and
remembered for the session (`LensChoices`, keyed by command id like `OutputFolding`, pruned with it).

**Limits.** Lenses apply to bodies up to 2 MB or 20,000 lines; above that the block stays raw and
the menu says "Body too large for lenses — Save Output…". Lens lines are computed off the main
thread once per (command id, lens) and cached; the render path only reads rows.

### 6.3 JSON path subset

`JSONPath.parse` accepts jq's everyday subset: `.a.b`, `.a["key with spaces"]`, `.a[0]`,
`.a[-1]`, `.a[1:3]`, `.a[]`, `.a[]?.b`, `keys`, `length`, `.[] | .id` (one pipe stage), and a
top-level `..` search for a key (`..name`). Anything else is rejected with "not supported here —
Run with jq" which appends `| jq '<expr>'` to the command and runs it. The filter field in the
block (opened by the Lens ▸ Filter… item or `/` while the pointer is on an HTTP block) evaluates as
you type against the cached document.

## 7. Watch, repeat, poll

`WatchSeries` in Core:

```swift
public struct WatchPlan: Equatable {
    public enum Stop: Equatable { case never, count(Int), until(Condition) }
    public enum Condition: Equatable {
        case status(Int), statusClass(Int), statusNot(Int), bodyContains(String), bodyLacks(String)
    }
    public let interval: Double          // seconds between the end of one run and the start of the next
    public let stop: Stop
}
public struct WatchSeries: Equatable {
    public init(plan: WatchPlan, command: String, startedAt: Double)
    public mutating func recordRun(id: UInt32, exchange: HTTPExchange?, exitStatus: Int32, at: Double)
    public func nextRunTime(now: Double) -> Double?     // nil when finished
    public var runs: [Run]                             // id, status, timeTotal, at
    public var isFinished: Bool
    public var stats: Stats?                           // n, min, p50, p95, max over timeTotal; failures
    public func timeline(last n: Int) -> [Dot]         // status class per run, newest last
}
```

Rules: the next run is sent only when the shell is at a prompt (the `CommandWatcher` says the last
command finished); if the previous run is still running when the interval elapses, the series waits
for it and then runs immediately. A series stops on its plan, on ⌘. while its block is the latest
HTTP block, on the Stop button in the block header, when the pane closes, and when the user types
anything at the prompt (a series must never race the user's own typing).

Presentation: each run is an ordinary block. Every run but the newest is folded `.all` by the
series (respecting `openedByHand`). The newest block's header reads `watch 5s · run 12 · 200 · 142 ms`
with a timeline of the last 30 runs as coloured dots and a Stop button; after the series finishes
the header shows the stats: `20 runs · p50 138 ms · p95 210 ms · 1 failure`. The default lens for
runs after the first is `.diff(previous)` when the body is JSON; the first run uses the ordinary
default. A run whose status class differs from the previous run's is *not* folded, so the run that
broke stays open.

Entry points: the sheet's Run button has a menu: "Run", "Run every…" (interval, stop rule), "Run
10 times", "Run until 200"; the block's ⋯ menu has "Run every 5 s" and "Watch…"; the palette has
"Stop Watching".

## 8. Export, saving, history

`RequestExport.render(_ command: CurlCommand, as: Format) -> String` for `.httpie`, `.fetch`,
`.pythonRequests`, `.go`. Each is a faithful translation of method, URL, headers, body, auth and
the `-L`/`-k` flags; options with no equivalent are listed in a trailing comment. Tested against a
fixture per format.

Saving: "Save as Button…" writes `quick = <name> | send | <one-line curl>` through `ConfigWriter`
(the existing quick-action editor pre-filled); "Save to project" writes the same line into the
directory's `.nyx` (through `ProjectActions`, subject to its approval gate); both from the sheet and
the block menu.

History: `RequestHistory` keeps the last `http-history` (default 50) distinct requests run through
the workbench or recognised as HTTP blocks, newest first, in `~/.config/nyx/requests` (one
`shellLine(.none, .oneLine)` per line, 0600, written atomically). The palette gets a "Requests"
section: `GET api.example.com/users · 2 min ago`, choosing one opens the sheet. `Masking.display`
in the palette rows.

## 9. Configuration and actions

| Key | Default | Meaning |
|---|---|---|
| `http-lens` | `pretty` | default lens for JSON bodies: `pretty` or `raw` |
| `http-hint` | `on` | the "⌘E Workbench" pill on a pasted curl |
| `http-watch-interval` | `5` | seconds, the sheet's and the menu's default |
| `http-history` | `50` | requests kept; `0` disables history |

No new key for opening: `edit_and_run_command` (⌘E) and `paste_with_editor` (⌘⇧V) open the
workbench when their text is a curl and the plain editor otherwise, so each key keeps meaning
"edit this properly". New actions: `toggle_http_lens` (⌘⇧J, pretty ↔ raw on the block under the
pointer or the last HTTP block), `stop_watch` (⌘. while a series is active; otherwise ⌘. keeps its
current meaning), `new_request` (palette and Shell menu, no default key). All in `ActionCatalog`
and the menus; the pill's text is produced in Core from the bound chord, so a rebinding changes it.

## 10. Testing

Core: a corpus of 40 real curls (`Tests/NyxCoreTests/Fixtures/curl/*.sh` — Chrome copy-as-cURL
with 20 headers and `--data-raw` JSON, Postman, GitHub API docs, Stripe with `-u`, multi-line with
`\`, `-G --data-urlencode`, `-F` multipart, `--json`, `@file`, variables, a pipeline) with the
round-trip law; masking; `RequestRun` additions and the pipeline exception; `HTTPExchange` on
redirect chains, `-v` output, no sentinel, curl failure exits, binary body; pretty printer and fold
points; the JSON path subset with rejections; `LensBuffer` display mapping against every viewport
function that `OutputFolding` is tested against; `WatchSeries` schedule, stop rules, stats,
timeline, the "user typed" stop; exports against fixtures; history persistence and pruning.

App: `UISnapshot` cases for the sheet (each tab, light and dark), the pill, an HTTP block in each
lens, a watch header running and finished, the palette Requests section; a pixel test for the
summary colours; the rung-6 `NYX_SMOKE_QA` script: paste a curl → pill → ⌘E → change a header →
Run → block summary `200` → pretty lens → filter `.items[0].id` → Run every 1 s ×3 → stats → Save
as Button → button appears. Run against a local `python3 -m http.server`-style fixture server
started by the hook, so the test needs no network.

Performance: lens computation must not touch the render path; `make bench` unchanged; a 2 MB JSON
body pretty-prints under 200 ms off-thread.

## 11. Left open (not in v1)

- Assertions with pass/fail badges, and masked secrets in exports and history.
- `xh`, `http`, `wget` import; curl that is not the first command of a pipeline.
- Diffing across sessions (history stores commands, not responses).
- A side panel / persistent workbench; `.http` file import; environments and variable pickers
  beyond leaving `$VAR` alone.
- Lenses for non-JSON structured bodies (XML, HTML, CSV).
