# Nyx Phase 1 (Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working single-window native macOS terminal: PTY + VT parser + screen model + Metal renderer + AppKit view, in which zsh, vim, htop, fzf and Claude Code run without artifacts and `cat` of a huge file never freezes the UI.

**Architecture:** Three Swift modules with one-way dependencies (`Nyx` app → `NyxRender` → `NyxCore`) plus a tiny C target `CNyxPTY` for `forkpty`. A reader thread per session parses PTY bytes into the `Terminal` model under a lock; the AppKit view snapshots visible rows on a display-link tick and renders them with one instanced Metal draw call.

**Tech Stack:** Swift 6.0.3 toolchain in Swift 5 language mode (`swift-tools-version:5.10`), SwiftPM only (no Xcode), swift-testing (`import Testing`; XCTest is NOT available on this machine), AppKit, Metal (shaders compiled at runtime from a string), Core Text.

**Spec:** `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md` (this plan implements §11 "Этап 1"; sections §4–§5 and §6.1 are the detailed requirements).

## Global Constraints

- Work in the repository `~/projects/nyx` (NOT `~/projects/main`). All paths below are relative to it.
- Deployment target macOS 14. `Package.swift` starts with `// swift-tools-version:5.10`. No external packages.
- Tests use swift-testing: `import Testing`, `@Test`, `#expect`, `#require`. Run with `swift test`. Filter with `swift test --filter <TestNameSubstring>`.
- `NyxCore` must not import AppKit, Metal, CoreText or QuartzCore. `NyxRender` must not import CNyxPTY or touch PTYs.
- Metal shader source lives in a Swift string constant and is compiled with `device.makeLibrary(source:options:)`. There is no `metal` compiler on this machine.
- Cell size targets from the spec: `Cell` is a 20-byte value type, scrollback default 10 000 lines, OSC payload limit 64 KiB.
- Commit after every task with a message like `feat(core): VT parser state machine`. Include the trailer lines:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_014u6CmMe92XrF1UPpE5QWD8
  ```
- Never claim a task is done without running the listed command and seeing the expected output.

## File Structure

```
Package.swift                          SwiftPM manifest (5 targets + 2 test targets)
Makefile                               build / test / app / install / bench
.gitignore
scripts/bundle.sh                      assembles build/Nyx.app from the release binary
scripts/gen_width_table.py             generates Sources/NyxCore/Unicode/WidthTable.swift from unicode.org data
Resources/Info.plist
Sources/CNyxPTY/include/nyx_pty.h      C API: nyx_pty_spawn / nyx_pty_resize
Sources/CNyxPTY/nyx_pty.c              forkpty + execve
Sources/NyxCore/PTY/PTY.swift          Swift wrapper over CNyxPTY (read/write/resize/wait)
Sources/NyxCore/Unicode/WidthTable.swift   generated range tables
Sources/NyxCore/Unicode/CharWidth.swift    width(scalar) -> 0/1/2
Sources/NyxCore/Parser/CSIParams.swift     parameter list with sub-parameters
Sources/NyxCore/Parser/VTParser.swift      DEC ANSI state machine + UTF-8 decoder
Sources/NyxCore/Terminal/Color.swift       Color (packed), RGB, Palette
Sources/NyxCore/Terminal/Cell.swift        Cell, CellAttrs, UnderlineStyle, Pen
Sources/NyxCore/Terminal/Row.swift         Row, Scrollback ring buffer
Sources/NyxCore/Terminal/Screen.swift      Screen (grid + cursor + margins + tabs), Cursor
Sources/NyxCore/Terminal/Charset.swift     DEC Special Graphics mapping
Sources/NyxCore/Terminal/Terminal.swift    the model: print/execute/csi/esc/osc/dcs, modes, responses, events
Sources/NyxCore/Terminal/Terminal+Resize.swift  reflow on resize, viewport access
Sources/NyxCore/Keys/KeyEncoder.swift      KeyEvent -> bytes (xterm encoding)
Sources/NyxCore/Session/TerminalSession.swift  PTY + reader thread + lock + write queue
Sources/NyxRender/FontSet.swift            CTFont set + CellMetrics
Sources/NyxRender/GlyphAtlas.swift         Core Text rasterization into a 2048² RGBA atlas
Sources/NyxRender/Shaders.swift            MSL source string
Sources/NyxRender/Renderer.swift           RenderFrame, Instance building, Metal pipeline
Sources/NyxApp/main.swift
Sources/NyxApp/AppDelegate.swift
Sources/NyxApp/MainMenu.swift
Sources/NyxApp/Theme.swift                 nyx-dark palette
Sources/NyxApp/TerminalWindowController.swift
Sources/NyxApp/TerminalView.swift          NSView + NSTextInputClient + display link + input
Sources/NyxApp/AtomicFlag.swift
Sources/NyxBench/main.swift                parser throughput benchmark
Tests/NyxCoreTests/PTYTests.swift
Tests/NyxCoreTests/CharWidthTests.swift
Tests/NyxCoreTests/VTParserTests.swift
Tests/NyxCoreTests/DataStructureTests.swift
Tests/NyxCoreTests/TerminalTestHelpers.swift
Tests/NyxCoreTests/TerminalBasicsTests.swift
Tests/NyxCoreTests/TerminalModesTests.swift
Tests/NyxCoreTests/TerminalResizeTests.swift
Tests/NyxCoreTests/KeyEncoderTests.swift
Tests/NyxCoreTests/TerminalSessionTests.swift
Tests/NyxRenderTests/FontSetTests.swift
Tests/NyxRenderTests/GlyphAtlasTests.swift
Tests/NyxRenderTests/RendererTests.swift
docs/checklist.md                          manual verification checklist
```

---

### Task 1: Package skeleton, CNyxPTY and the Swift PTY wrapper

**Files:**
- Create: `Package.swift`, `Makefile`, `.gitignore`
- Create: `Sources/CNyxPTY/include/nyx_pty.h`, `Sources/CNyxPTY/nyx_pty.c`
- Create: `Sources/NyxCore/PTY/PTY.swift`
- Create: `Sources/NyxRender/Placeholder.swift`, `Sources/NyxApp/main.swift`, `Sources/NyxBench/main.swift` (minimal, replaced in later tasks)
- Test: `Tests/NyxCoreTests/PTYTests.swift`, `Tests/NyxRenderTests/Placeholder.swift`

**Interfaces:**
- Produces: `public final class PTY` with `init(path:argv:environment:cwd:cols:rows:) throws`, `read(into: UnsafeMutableRawBufferPointer) -> Int`, `write(_ bytes: [UInt8]) -> Bool`, `resize(cols:rows:)`, `close()`, `terminate()`, `wait() -> Int32`, `let fd: Int32`, `let pid: pid_t`. `public struct PTYError: Error { let code: Int32 }`.

- [ ] **Step 1: Create the manifest, Makefile and gitignore**

`Package.swift`:
```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Nyx",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CNyxPTY", path: "Sources/CNyxPTY"),
        .target(name: "NyxCore", dependencies: ["CNyxPTY"], path: "Sources/NyxCore"),
        .target(
            name: "NyxRender",
            dependencies: ["NyxCore"],
            path: "Sources/NyxRender",
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("CoreText"), .linkedFramework("QuartzCore")]
        ),
        .executableTarget(
            name: "Nyx",
            dependencies: ["NyxCore", "NyxRender"],
            path: "Sources/NyxApp",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "nyx-bench", dependencies: ["NyxCore"], path: "Sources/NyxBench"),
        .testTarget(name: "NyxCoreTests", dependencies: ["NyxCore"], path: "Tests/NyxCoreTests"),
        .testTarget(name: "NyxRenderTests", dependencies: ["NyxRender"], path: "Tests/NyxRenderTests"),
    ]
)
```

`Makefile`:
```make
.PHONY: build release test app install bench clean run

build:
	swift build

release:
	swift build -c release

test:
	swift test

run:
	swift run Nyx

app: release
	scripts/bundle.sh

install: app
	rm -rf /Applications/Nyx.app && cp -R build/Nyx.app /Applications/

bench:
	swift run -c release nyx-bench $(FILE)

clean:
	rm -rf .build build
```

`.gitignore`:
```
.build/
build/
.swiftpm/
*.xcodeproj
.DS_Store
```

Placeholders so every target compiles:

`Sources/NyxRender/Placeholder.swift`: `public enum NyxRenderPlaceholder {}`
`Sources/NyxApp/main.swift`: `print("nyx")`
`Sources/NyxBench/main.swift`: `print("bench")`
`Tests/NyxRenderTests/Placeholder.swift`:
```swift
import Testing
@Test func renderTargetLinks() { #expect(true) }
```

- [ ] **Step 2: Write the failing PTY tests**

`Tests/NyxCoreTests/PTYTests.swift`:
```swift
import Testing
import Foundation
@testable import NyxCore

private func drain(_ pty: PTY) -> String {
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = buf.withUnsafeMutableBytes { pty.read(into: $0) }
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

@Test func ptySpawnsShellAndReadsOutput() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "echo hello"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: nil, cols: 80, rows: 24)
    let text = drain(pty)
    #expect(text == "hello\r\n")
    #expect(pty.wait() == 0)
}

@Test func ptyReportsWindowSizeAndCwd() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "stty size; pwd"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: "/private/tmp", cols: 100, rows: 30)
    let text = drain(pty)
    _ = pty.wait()
    #expect(text.contains("30 100"))
    #expect(text.contains("/private/tmp"))
}

@Test func ptyResizeIsVisibleToChild() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "sleep 0.3; stty size"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: nil, cols: 80, rows: 24)
    pty.resize(cols: 120, rows: 40)
    let text = drain(pty)
    _ = pty.wait()
    #expect(text.contains("40 120"))
}

@Test func ptyWriteReachesChild() throws {
    let pty = try PTY(path: "/bin/sh", argv: ["sh", "-c", "read line; echo got:$line"],
                      environment: ["PATH": "/bin:/usr/bin"], cwd: nil, cols: 80, rows: 24)
    #expect(pty.write(Array("ping\n".utf8)))
    let text = drain(pty)
    _ = pty.wait()
    #expect(text.contains("got:ping"))
}

@Test func ptySpawnFailureThrows() {
    #expect(throws: PTYError.self) {
        _ = try PTY(path: "/nonexistent/binary", argv: ["x"], environment: [:], cwd: nil, cols: 80, rows: 24)
    }
}
```
Note: the last test expects `execve` failure to surface as an error. Because exec fails in the child, the parent only sees EOF; we detect it via `wait()` returning 127 in the initializer? No — keep it simple: the initializer succeeds, and the test instead checks that `wait()` returns 127. Replace the last test with:
```swift
@Test func ptyExecFailureExitsWith127() throws {
    let pty = try PTY(path: "/nonexistent/binary", argv: ["x"], environment: [:], cwd: nil, cols: 80, rows: 24)
    _ = drain(pty)
    #expect(pty.wait() == 127)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ~/projects/nyx && swift test --filter pty 2>&1 | tail -20`
Expected: build error `cannot find 'PTY' in scope`.

- [ ] **Step 4: Write the C target**

`Sources/CNyxPTY/include/nyx_pty.h`:
```c
#ifndef NYX_PTY_H
#define NYX_PTY_H
#include <sys/types.h>

typedef struct {
    int fd;      /* master fd, or -1 on failure */
    pid_t pid;   /* child pid, or -1 */
    int err;     /* errno when fd == -1 */
} nyx_pty_result;

/* forkpty + execve. argv/envp are NULL-terminated. cwd may be NULL. */
nyx_pty_result nyx_pty_spawn(const char *path, char *const argv[], char *const envp[],
                             const char *cwd, unsigned short cols, unsigned short rows);

/* Returns 0 on success, errno otherwise. */
int nyx_pty_resize(int fd, unsigned short cols, unsigned short rows);

#endif
```

`Sources/CNyxPTY/nyx_pty.c`:
```c
#include "nyx_pty.h"
#include <util.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <string.h>

nyx_pty_result nyx_pty_spawn(const char *path, char *const argv[], char *const envp[],
                             const char *cwd, unsigned short cols, unsigned short rows) {
    nyx_pty_result r = { -1, -1, 0 };
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = cols;
    ws.ws_row = rows;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) { r.err = errno; return r; }
    if (pid == 0) {
        sigset_t set;
        sigemptyset(&set);
        sigprocmask(SIG_SETMASK, &set, NULL);
        for (int s = 1; s < NSIG; s++) signal(s, SIG_DFL);
        if (cwd != NULL && chdir(cwd) != 0) { /* keep inherited cwd */ }
        execve(path, argv, envp);
        _exit(127);
    }
    fcntl(master, F_SETFD, FD_CLOEXEC);
    r.fd = master;
    r.pid = pid;
    return r;
}

int nyx_pty_resize(int fd, unsigned short cols, unsigned short rows) {
    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = cols;
    ws.ws_row = rows;
    return ioctl(fd, TIOCSWINSZ, &ws) == 0 ? 0 : errno;
}
```

- [ ] **Step 5: Write the Swift wrapper**

`Sources/NyxCore/PTY/PTY.swift`:
```swift
import CNyxPTY
import Darwin
import Foundation

public struct PTYError: Error, CustomStringConvertible {
    public let code: Int32
    public var description: String { String(cString: strerror(code)) }
}

/// A pseudo-terminal with a spawned child process. `read` blocks; call it from a dedicated thread.
public final class PTY {
    public let fd: Int32
    public let pid: pid_t
    private var closed = false

    public init(path: String, argv: [String], environment: [String: String], cwd: String?, cols: Int, rows: Int) throws {
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            cArgv.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        let result = nyx_pty_spawn(path, cArgv, cEnv, cwd, UInt16(clamping: cols), UInt16(clamping: rows))
        if result.fd < 0 { throw PTYError(code: result.err) }
        fd = result.fd
        pid = result.pid
    }

    deinit { close() }

    /// Blocking read. Returns 0 on EOF, -1 on error (EIO once the child has exited).
    public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        Darwin.read(fd, buffer.baseAddress, buffer.count)
    }

    /// Writes every byte. Returns false on a hard error.
    @discardableResult
    public func write(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { usleep(500); continue }
                return false
            }
            offset += n
        }
        return true
    }

    public func resize(cols: Int, rows: Int) {
        _ = nyx_pty_resize(fd, UInt16(clamping: cols), UInt16(clamping: rows))
    }

    public func close() {
        if !closed { closed = true; Darwin.close(fd) }
    }

    /// Asks the child to hang up (SIGHUP), like closing a real terminal.
    public func terminate() { Darwin.kill(pid, SIGHUP) }

    /// Waits for the child. Returns its exit code, or 128 + signal number.
    public func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
        return 128 + (status & 0x7f)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ~/projects/nyx && swift test --filter pty 2>&1 | tail -20`
Expected: `✔ Test run with 5 tests passed`.

- [ ] **Step 7: Commit**

```bash
cd ~/projects/nyx && git add -A && git commit -m "feat(core): package skeleton, CNyxPTY and PTY wrapper"
```
(Add the trailer lines from Global Constraints to every commit message.)

---

### Task 2: Unicode width table

**Files:**
- Create: `scripts/gen_width_table.py`
- Create: `Sources/NyxCore/Unicode/WidthTable.swift` (generated, committed)
- Create: `Sources/NyxCore/Unicode/CharWidth.swift`
- Test: `Tests/NyxCoreTests/CharWidthTests.swift`

**Interfaces:**
- Produces: `public enum CharWidth { public static func width(_ s: Unicode.Scalar) -> Int }` returning 0, 1 or 2. `enum WidthTable { static let wide: [UInt32]; static let zero: [UInt32] }` — flat arrays of inclusive `[lo, hi, lo, hi, ...]` pairs, sorted.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/CharWidthTests.swift`:
```swift
import Testing
@testable import NyxCore

private func w(_ s: Unicode.Scalar) -> Int { CharWidth.width(s) }

@Test func asciiIsOne() { #expect(w("a") == 1); #expect(w(" ") == 1) }
@Test func cyrillicIsOne() { #expect(w("я") == 1); #expect(w("Ж") == 1) }
@Test func controlsAreZero() { #expect(w("\u{07}") == 0); #expect(w("\u{7F}") == 0); #expect(w("\u{9B}") == 0) }
@Test func combiningIsZero() { #expect(w("\u{0301}") == 0); #expect(w("\u{200D}") == 0); #expect(w("\u{FE0F}") == 0) }
@Test func cjkIsTwo() { #expect(w("漢") == 2); #expect(w("あ") == 2); #expect(w("한") == 2) }
@Test func emojiIsTwo() { #expect(w("😀") == 2); #expect(w("🚀") == 2) }
@Test func boxDrawingIsOne() { #expect(w("─") == 1); #expect(w("│") == 1); #expect(w("┌") == 1) }
@Test func privateUseIsOne() { #expect(w("\u{E0B0}") == 1) }   // nerd-font powerline glyph
@Test func hangulJamoMedialIsZero() { #expect(w("\u{1160}") == 0) }
@Test func softHyphenIsOne() { #expect(w("\u{00AD}") == 1) }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CharWidth 2>&1 | tail -5`
Expected: `cannot find 'CharWidth' in scope`.

- [ ] **Step 3: Write the generator and run it**

`scripts/gen_width_table.py`:
```python
#!/usr/bin/env python3
"""Generates Sources/NyxCore/Unicode/WidthTable.swift from Unicode 16 data files."""
import re, urllib.request, os

BASE = "https://www.unicode.org/Public/16.0.0/ucd/"
FILES = {
    "eaw": BASE + "EastAsianWidth.txt",
    "gc": BASE + "extracted/DerivedGeneralCategory.txt",
    "emoji": BASE + "emoji/emoji-data.txt",
}

def fetch(url):
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read().decode("utf-8")

def parse(text, wanted):
    """Yields (lo, hi) for lines whose property value is in `wanted`."""
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        rng, prop = [p.strip() for p in line.split(";")[:2]]
        if prop not in wanted:
            continue
        if ".." in rng:
            lo, hi = rng.split("..")
        else:
            lo = hi = rng
        yield int(lo, 16), int(hi, 16)

def merge(ranges):
    out = []
    for lo, hi in sorted(ranges):
        if out and lo <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(out[-1][1], hi))
        else:
            out.append((lo, hi))
    return out

def subtract(ranges, cp):
    out = []
    for lo, hi in ranges:
        if lo <= cp <= hi:
            if lo < cp: out.append((lo, cp - 1))
            if cp < hi: out.append((cp + 1, hi))
        else:
            out.append((lo, hi))
    return out

eaw = fetch(FILES["eaw"]); gc = fetch(FILES["gc"]); emoji = fetch(FILES["emoji"])

wide = list(parse(eaw, {"W", "F"})) + list(parse(emoji, {"Emoji_Presentation"}))
zero = list(parse(gc, {"Mn", "Me", "Cf"})) + [(0x1160, 0x11FF), (0x200B, 0x200F), (0x2028, 0x2029), (0x2060, 0x206F)]
wide = merge(wide)
zero = subtract(merge(zero), 0x00AD)  # soft hyphen renders as a visible dash in terminals
# a code point cannot be both: zero wins
wide_only = []
for lo, hi in wide:
    cur = lo
    for zlo, zhi in zero:
        if zhi < cur or zlo > hi: continue
        if zlo > cur: wide_only.append((cur, zlo - 1))
        cur = zhi + 1
    if cur <= hi: wide_only.append((cur, hi))
wide = merge(wide_only)

def swift_array(name, ranges):
    body = ",\n".join("        0x%04X, 0x%04X" % r for r in ranges)
    return "    static let %s: [UInt32] = [\n%s,\n    ]\n" % (name, body)

out = "// Generated by scripts/gen_width_table.py from Unicode 16.0.0. Do not edit.\n\n"
out += "enum WidthTable {\n" + swift_array("wide", wide) + "\n" + swift_array("zero", zero) + "}\n"
path = os.path.join(os.path.dirname(__file__), "..", "Sources", "NyxCore", "Unicode", "WidthTable.swift")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    f.write(out)
print("wrote", path, len(wide), "wide ranges,", len(zero), "zero ranges")
```

Run: `chmod +x scripts/gen_width_table.py && python3 scripts/gen_width_table.py`
Expected: `wrote .../WidthTable.swift NNN wide ranges, MMM zero ranges` (a few hundred each). Requires network access to unicode.org.

- [ ] **Step 4: Write CharWidth**

`Sources/NyxCore/Unicode/CharWidth.swift`:
```swift
/// Display width of a Unicode scalar in terminal cells: 0 (combining/control/zero-width), 1, or 2 (East Asian wide, emoji presentation).
public enum CharWidth {
    public static func width(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        if v < 0x300 { return 1 }          // Latin, Latin-1, nothing wide or combining below U+0300
        if contains(WidthTable.zero, v) { return 0 }
        if contains(WidthTable.wide, v) { return 2 }
        return 1
    }

    /// Width of a grapheme cluster: width of its first non-zero scalar, promoted to 2 by VS16 (U+FE0F).
    public static func width(of cluster: String) -> Int {
        var result = 0
        for s in cluster.unicodeScalars {
            if result == 0 { result = width(s) }
            if s.value == 0xFE0F { result = 2 }
        }
        return result
    }

    @inline(__always)
    static func contains(_ table: [UInt32], _ v: UInt32) -> Bool {
        var lo = 0
        var hi = table.count / 2 - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let a = table[mid * 2], b = table[mid * 2 + 1]
            if v < a { hi = mid - 1 } else if v > b { lo = mid + 1 } else { return true }
        }
        return false
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CharWidth 2>&1 | tail -5`
Expected: all 10 pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(core): Unicode 16 width table and CharWidth"
```

---

### Task 3: VT parser state machine

**Files:**
- Create: `Sources/NyxCore/Parser/CSIParams.swift`
- Create: `Sources/NyxCore/Parser/VTParser.swift`
- Test: `Tests/NyxCoreTests/VTParserTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct CSIParams: Equatable {
      public var items: [[Int]]              // each item is a parameter with its sub-parameters (colon-separated); "" and 0 both stored as 0
      public var count: Int
      public func get(_ i: Int, _ def: Int = 0) -> Int   // def when missing or 0
      public func sub(_ i: Int) -> [Int]
  }
  public protocol TerminalActions: AnyObject {
      func print(_ scalar: Unicode.Scalar)
      func execute(_ byte: UInt8)
      func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
      func esc(intermediates: [UInt8], final: UInt8)
      func osc(_ data: [UInt8])
      func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
      func dcsPut(_ byte: UInt8)
      func dcsUnhook()
  }
  public final class VTParser {
      public init(actions: TerminalActions)      // held weakly
      public func feed(_ bytes: UnsafeBufferPointer<UInt8>)
      public func feed(_ bytes: [UInt8])
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/VTParserTests.swift`:
```swift
import Testing
@testable import NyxCore

enum Action: Equatable {
    case print(Unicode.Scalar)
    case execute(UInt8)
    case csi([[Int]], [UInt8], UInt8)
    case esc([UInt8], UInt8)
    case osc(String)
    case dcsHook([[Int]], [UInt8], UInt8)
    case dcsPut(UInt8)
    case dcsUnhook
}

final class Recorder: TerminalActions {
    var actions: [Action] = []
    func print(_ scalar: Unicode.Scalar) { actions.append(.print(scalar)) }
    func execute(_ byte: UInt8) { actions.append(.execute(byte)) }
    func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8) { actions.append(.csi(params.items, intermediates, final)) }
    func esc(intermediates: [UInt8], final: UInt8) { actions.append(.esc(intermediates, final)) }
    func osc(_ data: [UInt8]) { actions.append(.osc(String(decoding: data, as: UTF8.self))) }
    func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8) { actions.append(.dcsHook(params.items, intermediates, final)) }
    func dcsPut(_ byte: UInt8) { actions.append(.dcsPut(byte)) }
    func dcsUnhook() { actions.append(.dcsUnhook) }
}

func parse(_ s: String) -> [Action] { parse(Array(s.utf8)) }
func parse(_ bytes: [UInt8]) -> [Action] {
    let r = Recorder()
    let p = VTParser(actions: r)
    p.feed(bytes)
    return r.actions
}
func parseByteByByte(_ s: String) -> [Action] {
    let r = Recorder()
    let p = VTParser(actions: r)
    for b in s.utf8 { p.feed([b]) }
    return r.actions
}
private func prints(_ s: String) -> [Action] { s.unicodeScalars.map { .print($0) } }

@Test func plainTextPrints() { #expect(parse("hi") == prints("hi")) }
@Test func c0Executes() { #expect(parse("a\r\n") == [.print("a"), .execute(0x0D), .execute(0x0A)]) }
@Test func cupWithParams() { #expect(parse("\u{1B}[3;4H") == [.csi([[3], [4]], [], 0x48)]) }
@Test func csiWithoutParams() { #expect(parse("\u{1B}[H") == [.csi([], [], 0x48)]) }
@Test func csiEmptyFirstParam() { #expect(parse("\u{1B}[;5H") == [.csi([[0], [5]], [], 0x48)]) }
@Test func privateMarker() { #expect(parse("\u{1B}[?25h") == [.csi([[25]], [0x3F], 0x68)]) }
@Test func intermediateSpace() { #expect(parse("\u{1B}[2 q") == [.csi([[2]], [0x20], 0x71)]) }
@Test func sgrSubparams() { #expect(parse("\u{1B}[4:3;38:2:1:2:3m") == [.csi([[4, 3], [38, 2, 1, 2, 3]], [], 0x6D)]) }
@Test func c0InsideCsiExecutesAndContinues() { #expect(parse("\u{1B}[3\u{08}m") == [.execute(0x08), .csi([[3]], [], 0x6D)]) }
@Test func canAbortsCsi() { #expect(parse("\u{1B}[3\u{18}a") == [.execute(0x18), .print("a")]) }
@Test func escSequences() {
    #expect(parse("\u{1B}7") == [.esc([], 0x37)])
    #expect(parse("\u{1B}(0") == [.esc([0x28], 0x30)])
    #expect(parse("\u{1B}#8") == [.esc([0x23], 0x38)])
}
@Test func oscTerminatedByBel() { #expect(parse("\u{1B}]0;title\u{07}") == [.osc("0;title")]) }
@Test func oscTerminatedByST() { #expect(parse("\u{1B}]0;title\u{1B}\\x") == [.osc("0;title"), .esc([], 0x5C), .print("x")]) }
@Test func oscKeepsUTF8() { #expect(parse("\u{1B}]2;Привет\u{07}") == [.osc("2;Привет")]) }
@Test func oscOverflowIsDropped() {
    let big = String(repeating: "a", count: VTParser.maxOSCLength + 10)
    #expect(parse("\u{1B}]52;c;" + big + "\u{07}x") == [.print("x")])
}
@Test func dcsPassthrough() {
    #expect(parse("\u{1B}P$qm\u{1B}\\") == [.dcsHook([], [0x24], 0x71), .dcsPut(0x6D), .dcsUnhook, .esc([], 0x5C)])
}
@Test func utf8MultiByte() { #expect(parse("я😀") == prints("я😀")) }
@Test func invalidUTF8BecomesReplacement() { #expect(parse([0xFF, 0x61]) == [.print("\u{FFFD}"), .print("a")]) }
@Test func truncatedUTF8ThenAscii() { #expect(parse([0xD1, 0x61]) == [.print("\u{FFFD}"), .print("a")]) }
@Test func overlongUTF8Rejected() { #expect(parse([0xC0, 0x80]) == [.print("\u{FFFD}"), .print("\u{FFFD}")]) }
@Test func splitFeedMatchesWholeFeed() {
    let s = "a\u{1B}[1;31mЖ\u{1B}]0;t\u{07}😀\u{1B}[?1049h"
    #expect(parseByteByByte(s) == parse(s))
}
@Test func paramsCappedAt32() {
    let many = (0..<40).map(String.init).joined(separator: ";")
    guard case .csi(let items, _, _) = parse("\u{1B}[" + many + "m").first else { Issue.record("no csi"); return }
    #expect(items.count == 32)
}
@Test func csiParamsGetDefaults() {
    let p = CSIParams([[0], [7]])
    #expect(p.get(0, 1) == 1)
    #expect(p.get(1, 1) == 7)
    #expect(p.get(5, 3) == 3)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VTParser 2>&1 | tail -5`
Expected: compile error, `TerminalActions` not found.

- [ ] **Step 3: Write CSIParams**

`Sources/NyxCore/Parser/CSIParams.swift`:
```swift
/// CSI parameter list. Each item is one parameter with its colon-separated sub-parameters.
public struct CSIParams: Equatable {
    public var items: [[Int]]

    public init(_ items: [[Int]] = []) { self.items = items }

    public var count: Int { items.count }

    /// The first value of parameter `i`, or `def` when the parameter is absent or zero.
    public func get(_ i: Int, _ def: Int = 0) -> Int {
        guard i < items.count, let v = items[i].first, v != 0 else { return def }
        return v
    }

    /// All sub-parameters of parameter `i` (empty when absent).
    public func sub(_ i: Int) -> [Int] { i < items.count ? items[i] : [] }
}
```

- [ ] **Step 4: Write VTParser**

`Sources/NyxCore/Parser/VTParser.swift`:
```swift
/// Receiver of parser actions. Implemented by `Terminal`.
public protocol TerminalActions: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    func execute(_ byte: UInt8)
    func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
    func esc(intermediates: [UInt8], final: UInt8)
    func osc(_ data: [UInt8])
    func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
    func dcsPut(_ byte: UInt8)
    func dcsUnhook()
}

/// DEC ANSI-compatible escape sequence parser (Paul Williams' state machine) with an inline UTF-8 decoder.
/// 8-bit C1 controls are not recognised: all bytes >= 0x80 are UTF-8.
public final class VTParser {
    public static let maxOSCLength = 65536
    public static let maxParams = 32

    private enum State {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case sosPmApcString
    }

    private weak var actions: TerminalActions?
    private var state: State = .ground
    private var intermediates: [UInt8] = []
    private var params: [[Int]] = []
    private var currentSub: [Int] = []
    private var currentValue = 0
    private var hasDigits = false
    private var oscBuffer: [UInt8] = []
    private var oscOverflow = false
    private var utf8Pending = 0
    private var utf8Value: UInt32 = 0
    private var utf8Min: UInt32 = 0

    public init(actions: TerminalActions) {
        self.actions = actions
        oscBuffer.reserveCapacity(256)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes { advance(b) }
    }

    // MARK: - Byte dispatch

    private func advance(_ b: UInt8) {
        if utf8Pending > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Pending -= 1
                if utf8Pending == 0 {
                    if utf8Value < utf8Min || utf8Value > 0x10FFFF || (0xD800...0xDFFF).contains(utf8Value) {
                        actions?.print("\u{FFFD}")
                    } else {
                        actions?.print(Unicode.Scalar(utf8Value)!)
                    }
                }
                return
            }
            utf8Pending = 0
            actions?.print("\u{FFFD}")
            // fall through: `b` is processed normally
        }

        // "Anywhere" transitions.
        switch b {
        case 0x18, 0x1A:
            leaveStringState()
            actions?.execute(b)
            state = .ground
            return
        case 0x1B:
            leaveStringState()
            enter(.escape)
            return
        default:
            break
        }

        switch state {
        case .ground:
            if b < 0x20 { actions?.execute(b) }
            else if b < 0x7F { actions?.print(Unicode.Scalar(b)) }
            else if b == 0x7F { /* DEL ignored */ }
            else { startUTF8(b) }

        case .escape:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
            case 0x50: enter(.dcsEntry)                       // P
            case 0x58, 0x5E, 0x5F: state = .sosPmApcString    // X ^ _
            case 0x5B: enter(.csiEntry)                       // [
            case 0x5D: enter(.oscString)                      // ]
            case 0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E:
                actions?.esc(intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .escapeIntermediate:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x7E:
                actions?.esc(intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .csiEntry, .csiParam, .csiIntermediate:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x30...0x39 where state != .csiIntermediate:
                currentValue = min(currentValue * 10 + Int(b - 0x30), 65535)
                hasDigits = true
                state = .csiParam
            case 0x3A where state != .csiIntermediate:
                pushSubParam(); state = .csiParam
            case 0x3B where state != .csiIntermediate:
                pushParam(); state = .csiParam
            case 0x3C...0x3F where state == .csiEntry:
                intermediates.append(b); state = .csiParam
            case 0x30...0x3F:
                state = .csiIgnore
            case 0x20...0x2F:
                intermediates.append(b); state = .csiIntermediate
            case 0x40...0x7E:
                finishParams()
                actions?.csi(CSIParams(params), intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .csiIgnore:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .oscString:
            switch b {
            case 0x07:
                dispatchOSC()
                state = .ground
            case 0x00...0x06, 0x08...0x1F:
                break
            default:
                if oscBuffer.count < VTParser.maxOSCLength { oscBuffer.append(b) } else { oscOverflow = true }
            }

        case .dcsEntry, .dcsParam, .dcsIntermediate:
            switch b {
            case 0x00...0x1F: break
            case 0x30...0x39 where state != .dcsIntermediate:
                currentValue = min(currentValue * 10 + Int(b - 0x30), 65535)
                hasDigits = true
                state = .dcsParam
            case 0x3A where state != .dcsIntermediate:
                pushSubParam(); state = .dcsParam
            case 0x3B where state != .dcsIntermediate:
                pushParam(); state = .dcsParam
            case 0x3C...0x3F where state == .dcsEntry:
                intermediates.append(b); state = .dcsParam
            case 0x30...0x3F:
                state = .dcsIgnore
            case 0x20...0x2F:
                intermediates.append(b); state = .dcsIntermediate
            case 0x40...0x7E:
                finishParams()
                actions?.dcsHook(CSIParams(params), intermediates: intermediates, final: b)
                state = .dcsPassthrough
            default: break
            }

        case .dcsPassthrough:
            if b != 0x7F { actions?.dcsPut(b) }

        case .dcsIgnore, .sosPmApcString:
            break
        }
    }

    // MARK: - Helpers

    private func enter(_ s: State) {
        intermediates.removeAll(keepingCapacity: true)
        params.removeAll(keepingCapacity: true)
        currentSub.removeAll(keepingCapacity: true)
        currentValue = 0
        hasDigits = false
        if s == .oscString { oscBuffer.removeAll(keepingCapacity: true); oscOverflow = false }
        state = s
    }

    /// Called before leaving a string-collecting state through ESC/CAN/SUB.
    private func leaveStringState() {
        switch state {
        case .oscString: dispatchOSC()
        case .dcsPassthrough: actions?.dcsUnhook()
        default: break
        }
    }

    private func dispatchOSC() {
        if !oscOverflow { actions?.osc(oscBuffer) }
        oscBuffer.removeAll(keepingCapacity: true)
        oscOverflow = false
    }

    private func pushSubParam() {
        currentSub.append(currentValue)
        currentValue = 0
        hasDigits = false
    }

    private func pushParam() {
        currentSub.append(currentValue)
        if params.count < VTParser.maxParams { params.append(currentSub) }
        currentSub.removeAll(keepingCapacity: true)
        currentValue = 0
        hasDigits = false
    }

    private func finishParams() {
        if hasDigits || !currentSub.isEmpty || !params.isEmpty { pushParam() }
    }

    private func startUTF8(_ b: UInt8) {
        switch b {
        case 0xC2...0xDF: utf8Pending = 1; utf8Value = UInt32(b & 0x1F); utf8Min = 0x80
        case 0xE0...0xEF: utf8Pending = 2; utf8Value = UInt32(b & 0x0F); utf8Min = 0x800
        case 0xF0...0xF4: utf8Pending = 3; utf8Value = UInt32(b & 0x07); utf8Min = 0x10000
        default: actions?.print("\u{FFFD}")
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter VTParser 2>&1 | tail -8`
Expected: all 24 pass. If `overlongUTF8Rejected` fails, check that `0xC0` and `0xC1` are excluded from the 2-byte lead range (they are: `0xC2...0xDF`), so `0xC0` prints U+FFFD and then `0x80` as a stray continuation prints another U+FFFD.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(core): VT parser state machine with UTF-8 decoding"
```

---

### Task 4: Colors, cells, rows, scrollback, screen

**Files:**
- Create: `Sources/NyxCore/Terminal/Color.swift`
- Create: `Sources/NyxCore/Terminal/Cell.swift`
- Create: `Sources/NyxCore/Terminal/Row.swift`
- Create: `Sources/NyxCore/Terminal/Screen.swift`
- Create: `Sources/NyxCore/Terminal/Charset.swift`
- Test: `Tests/NyxCoreTests/DataStructureTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Color: Equatable, Hashable { raw: UInt32; static let `default`; static func indexed(UInt8); static func rgb(UInt8,UInt8,UInt8); var kind: Kind (.default/.indexed/.rgb); var index: UInt8; var r,g,b: UInt8 }
  public struct RGB: Equatable, Hashable { r,g,b: UInt8; init(_:_:_:); init(hex: UInt32); init?(spec: String); var xtermSpec: String; func scaled(_ f: Double) -> RGB }
  public struct Palette: Equatable { colors: [RGB] (256); foreground, background, cursor: RGB; init(ansi: [RGB], foreground:background:cursor:); static func xtermDefault() -> Palette; func resolve(_ c: Color, isForeground: Bool) -> RGB }
  public struct CellAttrs: OptionSet (UInt16) { bold, dim, italic, strike, inverse, blink, hidden, wide, wideSpacer }
  public enum UnderlineStyle: UInt16 { none, single, double, curly, dotted, dashed }
  public struct Cell: Equatable { content: UInt32; fg, bg, ul: Color; attrs: CellAttrs; hyperlink: UInt16; var underline: UnderlineStyle; static let graphemeFlag: UInt32; var graphemeIndex: Int?; var scalar: Unicode.Scalar? }
  public struct Pen: Equatable { fg, bg, ul: Color; attrs: CellAttrs; underline: UnderlineStyle; hyperlink: UInt16; func makeCell() -> Cell }
  public struct Row: Equatable { cells: [Cell]; wrapped: Bool; dirty: Bool; promptMark: UInt8; init(cols: Int, fill: Cell = Cell()); var isBlank: Bool }
  public struct Scrollback { init(capacity: Int); count; mutating push(Row); subscript(Int) -> Row (0 = oldest); mutating removeAll() }
  public struct Cursor: Equatable { x, y: Int }
  public struct Screen { rows: [Row]; cursor: Cursor; pendingWrap: Bool; scrollTop, scrollBottom: Int; tabStops: [Bool]; init(cols:rows:); static func defaultTabStops(cols:) -> [Bool] }
  enum Charset { ascii, decSpecial; func map(_ s: Unicode.Scalar) -> Unicode.Scalar }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/DataStructureTests.swift`:
```swift
import Testing
@testable import NyxCore

@Test func colorPackingRoundTrips() {
    let c = Color.rgb(10, 20, 30)
    #expect(c.kind == .rgb); #expect(c.r == 10); #expect(c.g == 20); #expect(c.b == 30)
    let i = Color.indexed(200)
    #expect(i.kind == .indexed); #expect(i.index == 200)
    #expect(Color.default.kind == .default)
    #expect(MemoryLayout<Cell>.size == 20)
}

@Test func rgbSpecParsing() {
    #expect(RGB(spec: "#ff8000") == RGB(255, 128, 0))
    #expect(RGB(spec: "rgb:ff/80/00") == RGB(255, 128, 0))
    #expect(RGB(spec: "rgb:ffff/8000/0000") == RGB(255, 128, 0))
    #expect(RGB(spec: "nope") == nil)
    #expect(RGB(255, 128, 0).xtermSpec == "rgb:ffff/8080/0000")
}

@Test func xtermPaletteDefaults() {
    let p = Palette.xtermDefault()
    #expect(p.colors.count == 256)
    #expect(p.colors[1] == RGB(hex: 0xCD0000))
    #expect(p.colors[9] == RGB(hex: 0xFF0000))
    #expect(p.colors[16] == RGB(0, 0, 0))
    #expect(p.colors[196] == RGB(255, 0, 0))
    #expect(p.colors[231] == RGB(255, 255, 255))
    #expect(p.colors[232] == RGB(8, 8, 8))
    #expect(p.colors[255] == RGB(238, 238, 238))
    #expect(p.resolve(.default, isForeground: true) == p.foreground)
    #expect(p.resolve(.default, isForeground: false) == p.background)
    #expect(p.resolve(.indexed(1), isForeground: true) == RGB(hex: 0xCD0000))
    #expect(p.resolve(.rgb(1, 2, 3), isForeground: true) == RGB(1, 2, 3))
}

@Test func cellUnderlineStyleBits() {
    var c = Cell()
    #expect(c.underline == .none)
    c.underline = .curly
    c.attrs.insert(.bold)
    #expect(c.underline == .curly)
    #expect(c.attrs.contains(.bold))
    c.underline = .none
    #expect(c.attrs.contains(.bold))
    #expect(c.underline == .none)
}

@Test func cellGraphemeFlag() {
    var c = Cell()
    c.content = Cell.graphemeFlag | 5
    #expect(c.graphemeIndex == 5)
    #expect(c.scalar == nil)
    c.content = 0x41
    #expect(c.graphemeIndex == nil)
    #expect(c.scalar == "A")
}

@Test func scrollbackRingKeepsNewest() {
    var sb = Scrollback(capacity: 3)
    for i in 0..<5 {
        var r = Row(cols: 1); r.cells[0].content = UInt32(0x30 + i)
        sb.push(r)
    }
    #expect(sb.count == 3)
    #expect(sb[0].cells[0].content == 0x32)
    #expect(sb[2].cells[0].content == 0x34)
    sb.removeAll()
    #expect(sb.count == 0)
}

@Test func scrollbackZeroCapacityDropsEverything() {
    var sb = Scrollback(capacity: 0)
    sb.push(Row(cols: 1))
    #expect(sb.count == 0)
}

@Test func screenDefaults() {
    let s = Screen(cols: 20, rows: 5)
    #expect(s.rows.count == 5)
    #expect(s.rows[0].cells.count == 20)
    #expect(s.scrollBottom == 4)
    #expect(s.tabStops[8] && s.tabStops[16] && !s.tabStops[9])
}

@Test func decSpecialGraphics() {
    #expect(Charset.decSpecial.map("q") == "─")
    #expect(Charset.decSpecial.map("l") == "┌")
    #expect(Charset.decSpecial.map("x") == "│")
    #expect(Charset.decSpecial.map("A") == "A")
    #expect(Charset.ascii.map("q") == "q")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DataStructure 2>&1 | tail -5`
Expected: compile errors for missing types.

- [ ] **Step 3: Write Color.swift**

```swift
import Foundation

/// A terminal color: default, one of 256 indexed colors, or 24-bit RGB. Packed in 32 bits.
public struct Color: Equatable, Hashable {
    public enum Kind: UInt8 { case `default` = 0, indexed = 1, rgb = 2 }

    public var raw: UInt32

    public init(raw: UInt32) { self.raw = raw }
    public static let `default` = Color(raw: 0)
    public static func indexed(_ i: UInt8) -> Color { Color(raw: (1 << 24) | UInt32(i)) }
    public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(raw: (2 << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b))
    }

    public var kind: Kind { Kind(rawValue: UInt8(raw >> 24)) ?? .default }
    public var index: UInt8 { UInt8(raw & 0xFF) }
    public var r: UInt8 { UInt8((raw >> 16) & 0xFF) }
    public var g: UInt8 { UInt8((raw >> 8) & 0xFF) }
    public var b: UInt8 { UInt8(raw & 0xFF) }
}

public struct RGB: Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        r = UInt8((hex >> 16) & 0xFF); g = UInt8((hex >> 8) & 0xFF); b = UInt8(hex & 0xFF)
    }

    /// Parses "#rrggbb", "rgb:rr/gg/bb" and "rgb:rrrr/gggg/bbbb" (X11 forms used by OSC 4/10/11/12).
    public init?(spec: String) {
        if spec.hasPrefix("#"), spec.count == 7, let v = UInt32(spec.dropFirst(), radix: 16) {
            self.init(hex: v); return
        }
        if spec.hasPrefix("rgb:") {
            let parts = spec.dropFirst(4).split(separator: "/")
            guard parts.count == 3 else { return nil }
            var out = [UInt8]()
            for p in parts {
                guard let v = UInt32(p, radix: 16) else { return nil }
                switch p.count {
                case 1: out.append(UInt8(v * 17))
                case 2: out.append(UInt8(v))
                case 3: out.append(UInt8(v >> 4))
                case 4: out.append(UInt8(v >> 8))
                default: return nil
                }
            }
            self.init(out[0], out[1], out[2]); return
        }
        return nil
    }

    /// xterm response form, 16 bits per channel.
    public var xtermSpec: String { String(format: "rgb:%02x%02x/%02x%02x/%02x%02x", r, r, g, g, b, b) }

    public func scaled(_ f: Double) -> RGB {
        RGB(UInt8(Double(r) * f), UInt8(Double(g) * f), UInt8(Double(b) * f))
    }
}

public struct Palette: Equatable {
    public var colors: [RGB]
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB

    /// `ansi` is the 16 base colors; the 6x6x6 cube and the 24-step gray ramp are always the xterm defaults.
    public init(ansi: [RGB], foreground: RGB, background: RGB, cursor: RGB) {
        precondition(ansi.count == 16)
        var c = ansi
        for i in 0..<216 {
            let r = i / 36, g = (i / 6) % 6, b = i % 6
            func v(_ x: Int) -> UInt8 { x == 0 ? 0 : UInt8(55 + 40 * x) }
            c.append(RGB(v(r), v(g), v(b)))
        }
        for i in 0..<24 { let v = UInt8(8 + 10 * i); c.append(RGB(v, v, v)) }
        colors = c
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }

    public static let xtermAnsi16: [RGB] = [
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    ].map { RGB(hex: $0) }

    public static func xtermDefault() -> Palette {
        Palette(ansi: xtermAnsi16, foreground: RGB(hex: 0xE5E5E5), background: RGB(0, 0, 0), cursor: RGB(hex: 0xE5E5E5))
    }

    public func resolve(_ c: Color, isForeground: Bool) -> RGB {
        switch c.kind {
        case .default: return isForeground ? foreground : background
        case .indexed: return colors[Int(c.index)]
        case .rgb: return RGB(c.r, c.g, c.b)
        }
    }
}
```

- [ ] **Step 4: Write Cell.swift**

```swift
public struct CellAttrs: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold       = CellAttrs(rawValue: 1 << 0)
    public static let dim        = CellAttrs(rawValue: 1 << 1)
    public static let italic     = CellAttrs(rawValue: 1 << 2)
    public static let strike     = CellAttrs(rawValue: 1 << 3)
    public static let inverse    = CellAttrs(rawValue: 1 << 4)
    public static let blink      = CellAttrs(rawValue: 1 << 5)
    public static let hidden     = CellAttrs(rawValue: 1 << 6)
    public static let wide       = CellAttrs(rawValue: 1 << 7)   // first half of a 2-column glyph
    public static let wideSpacer = CellAttrs(rawValue: 1 << 8)   // second half; never drawn
    static let underlineMask     = CellAttrs(rawValue: 0b111 << 9)
}

public enum UnderlineStyle: UInt16 { case none = 0, single, double, curly, dotted, dashed }

/// One screen cell. 20 bytes.
public struct Cell: Equatable {
    /// 0 = empty. Otherwise a Unicode scalar value, or `graphemeFlag | index` into `Terminal.graphemes` for multi-scalar clusters.
    public var content: UInt32 = 0
    public var fg: Color = .default
    public var bg: Color = .default
    public var ul: Color = .default          // underline color (SGR 58)
    public var attrs: CellAttrs = []
    public var hyperlink: UInt16 = 0         // 0 = none, otherwise 1-based index into `Terminal.hyperlinks`

    public init() {}

    public static let graphemeFlag: UInt32 = 0x8000_0000

    public var underline: UnderlineStyle {
        get { UnderlineStyle(rawValue: (attrs.rawValue >> 9) & 0b111) ?? .none }
        set { attrs = CellAttrs(rawValue: (attrs.rawValue & ~CellAttrs.underlineMask.rawValue) | (newValue.rawValue << 9)) }
    }

    public var graphemeIndex: Int? {
        content & Cell.graphemeFlag != 0 ? Int(content & ~Cell.graphemeFlag) : nil
    }

    public var scalar: Unicode.Scalar? {
        content == 0 || content & Cell.graphemeFlag != 0 ? nil : Unicode.Scalar(content)
    }
}

/// Current SGR state applied to newly printed cells.
public struct Pen: Equatable {
    public var fg: Color = .default
    public var bg: Color = .default
    public var ul: Color = .default
    public var attrs: CellAttrs = []
    public var underline: UnderlineStyle = .none
    public var hyperlink: UInt16 = 0

    public init() {}

    public func makeCell() -> Cell {
        var c = Cell()
        c.fg = fg; c.bg = bg; c.ul = ul; c.attrs = attrs; c.underline = underline; c.hyperlink = hyperlink
        return c
    }
}
```

- [ ] **Step 5: Write Row.swift**

```swift
public struct Row: Equatable {
    public var cells: [Cell]
    /// True when the line continues on the next row (soft wrap). Used by reflow and selection.
    public var wrapped = false
    public var dirty = true
    /// OSC 133 mark: 1 = prompt start (A), 2 = input start (B), 3 = output start (C), 4 = end (D).
    public var promptMark: UInt8 = 0

    public init(cols: Int, fill: Cell = Cell()) {
        cells = Array(repeating: fill, count: cols)
    }

    public var isBlank: Bool { cells.allSatisfy { $0.content == 0 && $0.bg == .default } }
}

/// Fixed-capacity ring buffer of rows that have scrolled off the top of the primary screen.
public struct Scrollback {
    public let capacity: Int
    private var buffer: [Row] = []
    private var head = 0

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    public var count: Int { buffer.count }

    public mutating func push(_ row: Row) {
        guard capacity > 0 else { return }
        if buffer.count < capacity {
            buffer.append(row)
        } else {
            buffer[head] = row
            head = (head + 1) % capacity
        }
    }

    /// 0 is the oldest row.
    public subscript(i: Int) -> Row { buffer[(head + i) % buffer.count] }

    public mutating func removeAll() {
        buffer.removeAll(keepingCapacity: true)
        head = 0
    }
}
```

- [ ] **Step 6: Write Screen.swift and Charset.swift**

`Screen.swift`:
```swift
public struct Cursor: Equatable {
    public var x = 0
    public var y = 0
    public init(x: Int = 0, y: Int = 0) { self.x = x; self.y = y }
}

/// A grid of rows with a cursor, scroll margins and tab stops. The terminal owns two: primary and alternate.
public struct Screen {
    public var rows: [Row]
    public var cursor = Cursor()
    /// Set after printing in the last column; the next printable character wraps first (DECAWM).
    public var pendingWrap = false
    public var scrollTop = 0
    public var scrollBottom: Int
    public var tabStops: [Bool]

    public init(cols: Int, rows count: Int) {
        rows = Array(repeating: Row(cols: cols), count: count)
        scrollBottom = count - 1
        tabStops = Screen.defaultTabStops(cols: cols)
    }

    public static func defaultTabStops(cols: Int) -> [Bool] {
        (0..<cols).map { $0 % 8 == 0 }
    }
}
```

`Charset.swift`:
```swift
enum Charset: Equatable {
    case ascii
    case decSpecial

    /// DEC Special Graphics maps 0x60...0x7E to line-drawing glyphs.
    private static let decSpecialTable: [Unicode.Scalar] = Array("◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars)

    func map(_ s: Unicode.Scalar) -> Unicode.Scalar {
        guard self == .decSpecial, (0x60...0x7E).contains(s.value) else { return s }
        return Charset.decSpecialTable[Int(s.value - 0x60)]
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `swift test --filter DataStructure 2>&1 | tail -5`
Expected: 9 tests pass. If `MemoryLayout<Cell>.size == 20` fails, check field order: three `UInt32`-backed structs (content, fg, bg, ul = 16 bytes) then two `UInt16` (4 bytes).

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat(core): color, cell, row, scrollback and screen types"
```

---

### Task 5: Terminal — printing, cursor movement, erasing, editing, scrolling

**Files:**
- Create: `Sources/NyxCore/Terminal/Terminal.swift`
- Test: `Tests/NyxCoreTests/TerminalTestHelpers.swift`, `Tests/NyxCoreTests/TerminalBasicsTests.swift`

**Interfaces:**
- Produces `public final class Terminal: TerminalActions` with:
  ```swift
  init(cols: Int, rows: Int, scrollbackLimit: Int = 10_000, palette: Palette = .xtermDefault())
  var cols, rows: Int (read-only); var screen: Screen; var scrollback: Scrollback; var pen: Pen; var modes: TerminalModes; var palette: Palette
  var title: String; var cwd: String?; var cursorShape: CursorShape; var responses: [UInt8]; var events: [TerminalEvent]
  var graphemes: [String]; var hyperlinks: [String]; var viewportOffset: Int; var generation: UInt64; var pixelSize: (width: Int, height: Int)
  var cursor: Cursor
  func feed(_ bytes: UnsafeBufferPointer<UInt8>); func feed(_ bytes: [UInt8]); func feed(_ s: String)
  func line(_ y: Int) -> String; func text() -> [String]; func clusterText(of cell: Cell) -> String; func clearDirty()
  ```
  Task 6 adds SGR/modes/OSC/DCS/responses to the same file and Task 7 adds resize/viewport in an extension. In this task `csi`, `esc`, `osc`, `dcs*` handle only what is listed below; the rest are added in Task 6. Write the full skeleton (all protocol methods) now so it compiles.

- [ ] **Step 1: Write the test helpers and the failing tests**

`Tests/NyxCoreTests/TerminalTestHelpers.swift`:
```swift
@testable import NyxCore

func makeTerminal(cols: Int = 10, rows: Int = 3, scrollback: Int = 100) -> Terminal {
    Terminal(cols: cols, rows: rows, scrollbackLimit: scrollback)
}

extension Terminal {
    @discardableResult
    func run(_ s: String) -> Terminal { feed(s); return self }
    var cur: (Int, Int) { (screen.cursor.x, screen.cursor.y) }
    func cell(_ x: Int, _ y: Int) -> Cell { screen.rows[y].cells[x] }
    var responseText: String { String(decoding: responses, as: UTF8.self) }
    func scrollbackLine(_ i: Int) -> String {
        var s = ""
        for c in scrollback[i].cells where !c.attrs.contains(.wideSpacer) { s += c.content == 0 ? " " : clusterText(of: c) }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}
```

`Tests/NyxCoreTests/TerminalBasicsTests.swift`:
```swift
import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

@Test func printsText() {
    let t = makeTerminal().run("hello")
    #expect(t.line(0) == "hello")
    #expect(t.cur == (5, 0))
}

@Test func autoWrapsAndMarksRow() {
    let t = makeTerminal(cols: 5).run("abcdefg")
    #expect(t.text() == ["abcde", "fg", ""])
    #expect(t.screen.rows[0].wrapped)
    #expect(!t.screen.rows[1].wrapped)
}

@Test func pendingWrapClearedByCursorMoves() {
    let t = makeTerminal(cols: 5).run("abcde")
    #expect(t.cur == (4, 0))
    #expect(t.screen.pendingWrap)
    t.run("\nx")
    #expect(t.line(1) == "    x")   // LF keeps column 4, clears the wrap flag
    let u = makeTerminal(cols: 5).run("abcde\r\nx")
    #expect(u.line(1) == "x")
}

@Test func lineFeedAtBottomScrollsIntoScrollback() {
    let t = makeTerminal(rows: 2).run("a\r\nb\r\nc")
    #expect(t.text() == ["b", "c"])
    #expect(t.scrollback.count == 1)
    #expect(t.scrollbackLine(0) == "a")
}

@Test func cursorPositioning() {
    let t = makeTerminal().run(ESC + "[2;3Hx")
    #expect(t.cell(2, 1).scalar == "x")
    t.run(ESC + "[H")
    #expect(t.cur == (0, 0))
    t.run(ESC + "[99;99H")
    #expect(t.cur == (9, 2))
}

@Test func relativeCursorMovesClamp() {
    let t = makeTerminal().run(ESC + "[5C")
    #expect(t.cur == (5, 0))
    t.run(ESC + "[2B" + ESC + "[3D")
    #expect(t.cur == (2, 2))
    t.run(ESC + "[9A" + ESC + "[9D")
    #expect(t.cur == (0, 0))
    t.run(ESC + "[2E")
    #expect(t.cur == (0, 2))
    t.run(ESC + "[5G" + ESC + "[2d")
    #expect(t.cur == (4, 1))
}

@Test func eraseDisplay() {
    let t = makeTerminal(cols: 4).run("aaaa\r\nbbbb\r\ncccc" + ESC + "[2;2H")
    t.run(ESC + "[J")
    #expect(t.text() == ["aaaa", "b", ""])
    let u = makeTerminal(cols: 4).run("aaaa\r\nbbbb\r\ncccc" + ESC + "[2;2H")
    u.run(ESC + "[1J")
    #expect(u.text() == ["", "  bb", "cccc"])
    u.run(ESC + "[2J")
    #expect(u.text() == ["", "", ""])
}

@Test func eraseDisplay3ClearsScrollback() {
    let t = makeTerminal(rows: 1).run("a\r\nb" + ESC + "[3J")
    #expect(t.scrollback.count == 0)
}

@Test func eraseLine() {
    let t = makeTerminal(cols: 5).run("abcde" + ESC + "[3G")
    t.run(ESC + "[K")
    #expect(t.line(0) == "ab")
    let u = makeTerminal(cols: 5).run("abcde" + ESC + "[3G" + ESC + "[1K")
    #expect(u.line(0) == "   de")
    u.run(ESC + "[2K")
    #expect(u.line(0) == "")
}

@Test func eraseUsesPenBackground() {
    let t = makeTerminal(cols: 3).run(ESC + "[44m" + ESC + "[2J")
    #expect(t.cell(2, 2).bg == .indexed(4))
    #expect(t.cell(2, 2).content == 0)
}

@Test func insertAndDeleteChars() {
    let t = makeTerminal(cols: 5).run("abcde" + ESC + "[2G" + ESC + "[2@")
    #expect(t.line(0) == "a  bc")
    t.run(ESC + "[2P")
    #expect(t.line(0) == "abc")
    t.run(ESC + "[H" + ESC + "[2X")
    #expect(t.line(0) == "  c")
}

@Test func insertAndDeleteLines() {
    let t = makeTerminal(cols: 1, rows: 4).run("a\r\nb\r\nc\r\nd" + ESC + "[2;1H" + ESC + "[L")
    #expect(t.text() == ["a", "", "b", "c"])
    t.run(ESC + "[2M")
    #expect(t.text() == ["a", "c", "", ""])
}

@Test func scrollRegionKeepsLinesOutside() {
    let t = makeTerminal(cols: 1, rows: 4).run("a\r\nb\r\nc\r\nd")
    t.run(ESC + "[2;3r")           // region rows 2-3, cursor homes
    #expect(t.cur == (0, 0))
    t.run(ESC + "[3;1H\n")         // LF at bottom of region scrolls only the region
    #expect(t.text() == ["a", "c", "", "d"])
    #expect(t.scrollback.count == 0)
}

@Test func scrollRegionFromTopFeedsScrollback() {
    let t = makeTerminal(cols: 1, rows: 3).run(ESC + "[1;2r" + "a\r\nb\r\nc")
    #expect(t.text() == ["b", "c", ""])
    #expect(t.scrollback.count == 1)
    #expect(t.scrollbackLine(0) == "a")
}

@Test func scrollUpAndDownCommands() {
    let t = makeTerminal(cols: 1, rows: 3).run("a\r\nb\r\nc")
    t.run(ESC + "[S")
    #expect(t.text() == ["b", "c", ""])
    t.run(ESC + "[T")
    #expect(t.text() == ["", "b", "c"])
}

@Test func tabsAndTabStops() {
    let t = makeTerminal(cols: 20).run("\tx")
    #expect(t.cur == (9, 0))
    t.run("\t")
    #expect(t.cur == (16, 0))
    t.run("\t")
    #expect(t.cur == (19, 0))
    t.run(ESC + "[H" + ESC + "[5G" + ESC + "H" + ESC + "[H\t")
    #expect(t.cur == (4, 0))
    t.run(ESC + "[3g\r\t")
    #expect(t.cur == (19, 0))
    t.run(ESC + "[Z")
    #expect(t.cur == (0, 0))
}

@Test func backspaceAndCarriageReturn() {
    let t = makeTerminal().run("abc\u{08}x")
    #expect(t.line(0) == "abx")
    t.run("\rz")
    #expect(t.line(0) == "zbx")
}

@Test func repeatLastCharacter() {
    let t = makeTerminal().run("a" + ESC + "[3b")
    #expect(t.line(0) == "aaaa")
}

@Test func reverseIndexAtTopScrollsDown() {
    let t = makeTerminal(cols: 1, rows: 3).run("a\r\nb" + ESC + "[H" + ESC + "M")
    #expect(t.text() == ["", "a", "b"])
}

@Test func nextLineAndIndex() {
    let t = makeTerminal().run("ab" + ESC + "E" + "c" + ESC + "D" + "d")
    #expect(t.text() == ["ab", "c", " d"])
}

@Test func decAlignmentPattern() {
    let t = makeTerminal(cols: 3, rows: 2).run(ESC + "#8")
    #expect(t.text() == ["EEE", "EEE"])
}

@Test func wideCharacterOccupiesTwoCells() {
    let t = makeTerminal().run("漢a")
    #expect(t.cell(0, 0).attrs.contains(.wide))
    #expect(t.cell(1, 0).attrs.contains(.wideSpacer))
    #expect(t.cell(2, 0).scalar == "a")
    #expect(t.line(0) == "漢a")
    #expect(t.cur == (3, 0))
}

@Test func wideCharacterWrapsWhenItDoesNotFit() {
    let t = makeTerminal(cols: 4).run("abc漢")
    #expect(t.text() == ["abc", "漢", ""])
}

@Test func overwritingHalfOfWideClearsIt() {
    let t = makeTerminal().run("漢" + ESC + "[2Gb")
    #expect(t.line(0) == " b")
    #expect(!t.cell(0, 0).attrs.contains(.wide))
}

@Test func combiningMarkAttachesToPreviousCell() {
    let t = makeTerminal().run("e\u{0301}x")
    #expect(t.cur == (2, 0))
    #expect(t.cell(0, 0).graphemeIndex != nil)
    #expect(t.line(0) == "e\u{0301}x")
}

@Test func variationSelectorMakesEmojiWide() {
    let t = makeTerminal().run("\u{2764}\u{FE0F}x")
    #expect(t.cell(0, 0).attrs.contains(.wide))
    #expect(t.cell(2, 0).scalar == "x")
}

@Test func decSpecialGraphicsCharset() {
    let t = makeTerminal().run(ESC + "(0lqk" + ESC + "(Bx")
    #expect(t.line(0) == "┌─┐x")
    let u = makeTerminal().run(ESC + ")0\u{0E}q\u{0F}q")
    #expect(u.line(0) == "─q")
}

@Test func insertModeShiftsExistingText() {
    let t = makeTerminal(cols: 5).run("abc" + ESC + "[H" + ESC + "[4hX" + ESC + "[4l")
    #expect(t.line(0) == "Xabc")
}

@Test func bellProducesEvent() {
    let t = makeTerminal().run("\u{07}")
    #expect(t.events == [.bell])
}

@Test func generationChangesOnOutput() {
    let t = makeTerminal()
    let g = t.generation
    t.run("a")
    #expect(t.generation != g)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalBasics 2>&1 | tail -5`
Expected: compile error, `Terminal` not found.

- [ ] **Step 3: Write Terminal.swift**

```swift
import Foundation

public enum TerminalEvent: Equatable {
    case titleChanged(String)
    case bell
    case cwdChanged(String)
    case clipboardWrite(String)
    case notification(title: String, body: String)
    case colorsChanged
}

public enum MouseMode: Equatable { case none, x10, normal, button, any }
public enum CursorShape: Equatable { case block, underline, bar }

public struct TerminalModes: Equatable {
    public var cursorKeysApp = false     // DECCKM ?1
    public var keypadApp = false         // DECKPAM / DECKPNM
    public var originMode = false        // DECOM ?6
    public var autoWrap = true           // DECAWM ?7
    public var cursorBlink = true        // ?12
    public var showCursor = true         // DECTCEM ?25
    public var mouse: MouseMode = .none  // ?9 ?1000 ?1002 ?1003
    public var mouseSGR = false          // ?1006
    public var focusEvents = false       // ?1004
    public var altScreen = false         // ?1047 ?1049
    public var bracketedPaste = false    // ?2004
    public var syncOutput = false        // ?2026
    public var insertMode = false        // IRM 4
    public var lineFeedNewLine = false   // LNM 20
    public init() {}
}

struct SavedCursor {
    var cursor: Cursor
    var pen: Pen
    var charsets: [Charset]
    var activeCharset: Int
    var originMode: Bool
    var pendingWrap: Bool
}

@inline(__always) func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

/// The terminal model: parses bytes into screen state. Not thread-safe; `TerminalSession` serialises access.
public final class Terminal: TerminalActions {
    public static let version = "0.1.0"

    public private(set) var cols: Int
    public private(set) var rows: Int
    public var screen: Screen
    var inactiveScreen: Screen
    public var scrollback: Scrollback
    public var pen = Pen()
    public var modes = TerminalModes()
    public var palette: Palette
    let initialPalette: Palette
    public private(set) var title = ""
    public private(set) var cwd: String?
    public private(set) var cursorShape: CursorShape = .block
    /// Bytes the terminal wants written back to the application (DA, CPR, ...). Drained by the session.
    public var responses: [UInt8] = []
    public var events: [TerminalEvent] = []
    public private(set) var graphemes: [String] = []
    private var graphemeIndex: [String: Int] = [:]
    public private(set) var hyperlinks: [String] = []
    private var hyperlinkIndex: [String: Int] = [:]
    /// Number of scrollback lines the viewport is scrolled up by. 0 = live view.
    public internal(set) var viewportOffset = 0
    /// Increments on every visible change. Renderers compare it to decide whether to redraw.
    public private(set) var generation: UInt64 = 0
    /// Text area size in pixels, set by the view, reported by XTWINOPS 14/16.
    public var pixelSize: (width: Int, height: Int) = (0, 0)

    private var parser: VTParser!
    var charsets: [Charset] = [.ascii, .ascii]
    var activeCharset = 0
    var savedCursor: SavedCursor?
    var savedCursorOther: SavedCursor?
    private var lastPrinted: Unicode.Scalar?
    var savedModes: [Int: Bool] = [:]
    private var dcsData: [UInt8] = []
    private var dcsFinal: UInt8 = 0
    private var dcsIntermediates: [UInt8] = []

    public init(cols: Int, rows: Int, scrollbackLimit: Int = 10_000, palette: Palette = .xtermDefault()) {
        self.cols = max(cols, 2)
        self.rows = max(rows, 1)
        screen = Screen(cols: self.cols, rows: self.rows)
        inactiveScreen = Screen(cols: self.cols, rows: self.rows)
        scrollback = Scrollback(capacity: scrollbackLimit)
        self.palette = palette
        initialPalette = palette
        parser = VTParser(actions: self)
    }

    // MARK: - Public API

    public var cursor: Cursor { screen.cursor }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) { parser.feed(bytes) }
    public func feed(_ bytes: [UInt8]) { parser.feed(bytes) }
    public func feed(_ s: String) { feed(Array(s.utf8)) }

    public func clusterText(of cell: Cell) -> String {
        if let i = cell.graphemeIndex { return graphemes[i] }
        if let s = cell.scalar { return String(s) }
        return ""
    }

    /// Visible text of row `y` with trailing blanks trimmed. For tests and debugging.
    public func line(_ y: Int) -> String {
        var s = ""
        for c in screen.rows[y].cells where !c.attrs.contains(.wideSpacer) {
            s += c.content == 0 ? " " : clusterText(of: c)
        }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    public func text() -> [String] { (0..<rows).map(line) }

    public func clearDirty() {
        for y in 0..<rows { screen.rows[y].dirty = false }
    }

    func touch() { generation &+= 1 }

    func setCell(_ x: Int, _ y: Int, _ c: Cell) {
        screen.rows[y].cells[x] = c
        screen.rows[y].dirty = true
        touch()
    }

    /// Erase fill: current background, nothing else (BCE).
    var blank: Cell {
        var c = Cell()
        c.bg = pen.bg
        return c
    }

    func internGrapheme(_ s: String) -> Int {
        if let i = graphemeIndex[s] { return i }
        graphemes.append(s)
        graphemeIndex[s] = graphemes.count - 1
        return graphemes.count - 1
    }

    func internHyperlink(_ uri: String) -> Int {
        if let i = hyperlinkIndex[uri] { return i + 1 }
        guard hyperlinks.count < 65535 else { return 0 }
        hyperlinks.append(uri)
        hyperlinkIndex[uri] = hyperlinks.count - 1
        return hyperlinks.count
    }

    // MARK: - Printing

    public func print(_ raw: Unicode.Scalar) {
        put(charsets[activeCharset].map(raw))
    }

    private func put(_ s: Unicode.Scalar) {
        let width = CharWidth.width(s)
        if width == 0 { appendZeroWidth(s); return }
        if screen.pendingWrap {
            if modes.autoWrap { wrapToNextLine() } else { screen.pendingWrap = false }
        }
        var x = screen.cursor.x
        if width == 2 && x == cols - 1 {
            setCell(x, screen.cursor.y, blank)
            guard modes.autoWrap else { return }
            wrapToNextLine()
            x = 0
        }
        let y = screen.cursor.y
        if modes.insertMode { insertBlanks(count: width, at: x, row: y) }
        clearWideRemnants(x: x, y: y)
        if width == 2 { clearWideRemnants(x: x + 1, y: y) }
        var cell = pen.makeCell()
        cell.content = s.value
        if width == 2 {
            cell.attrs.insert(.wide)
            setCell(x, y, cell)
            var spacer = pen.makeCell()
            spacer.attrs.insert(.wideSpacer)
            setCell(x + 1, y, spacer)
        } else {
            setCell(x, y, cell)
        }
        lastPrinted = s
        let next = x + width
        if next >= cols {
            screen.cursor.x = cols - 1
            screen.pendingWrap = true
        } else {
            screen.cursor.x = next
        }
    }

    private func appendZeroWidth(_ s: Unicode.Scalar) {
        var x = screen.cursor.x
        let y = screen.cursor.y
        if !screen.pendingWrap { x -= 1 }
        guard x >= 0 else { return }
        if screen.rows[y].cells[x].attrs.contains(.wideSpacer) { x -= 1 }
        guard x >= 0 else { return }
        var cell = screen.rows[y].cells[x]
        guard cell.content != 0 else { return }
        var text = clusterText(of: cell)
        if s.value == 0xFE0F, !cell.attrs.contains(.wide), x + 1 < cols {
            cell.attrs.insert(.wide)
            var spacer = pen.makeCell()
            spacer.attrs.insert(.wideSpacer)
            spacer.bg = cell.bg
            setCell(x + 1, y, spacer)
            if screen.cursor.x == x + 1 {
                if x + 2 >= cols { screen.cursor.x = cols - 1; screen.pendingWrap = true } else { screen.cursor.x = x + 2 }
            }
        }
        text.unicodeScalars.append(s)
        cell.content = Cell.graphemeFlag | UInt32(internGrapheme(text))
        setCell(x, y, cell)
    }

    /// If the cell at (x, y) is half of a wide glyph, blank both halves so no orphan half remains.
    private func clearWideRemnants(x: Int, y: Int) {
        let c = screen.rows[y].cells[x]
        if c.attrs.contains(.wideSpacer), x > 0 {
            var b = Cell(); b.bg = screen.rows[y].cells[x - 1].bg
            setCell(x - 1, y, b)
        } else if c.attrs.contains(.wide), x + 1 < cols {
            var b = Cell(); b.bg = c.bg
            setCell(x + 1, y, b)
        }
    }

    private func wrapToNextLine() {
        screen.rows[screen.cursor.y].wrapped = true
        screen.cursor.x = 0
        screen.pendingWrap = false
        lineFeed()
    }

    // MARK: - Cursor and scrolling primitives

    func setCursor(x: Int, y: Int) {
        screen.cursor.x = clamp(x, 0, cols - 1)
        screen.cursor.y = clamp(y, 0, rows - 1)
        screen.pendingWrap = false
        touch()
    }

    func setCursorAbsolute(row: Int, col: Int?) {
        var y = row
        if modes.originMode { y = clamp(y + screen.scrollTop, screen.scrollTop, screen.scrollBottom) }
        setCursor(x: col ?? screen.cursor.x, y: y)
    }

    private func cursorUp(_ n: Int) {
        let top = screen.cursor.y >= screen.scrollTop ? screen.scrollTop : 0
        setCursor(x: screen.cursor.x, y: max(top, screen.cursor.y - n))
    }

    private func cursorDown(_ n: Int) {
        let bottom = screen.cursor.y <= screen.scrollBottom ? screen.scrollBottom : rows - 1
        setCursor(x: screen.cursor.x, y: min(bottom, screen.cursor.y + n))
    }

    func lineFeed() {
        let y = screen.cursor.y
        if y == screen.scrollBottom { scrollUp(1, top: screen.scrollTop, bottom: screen.scrollBottom, saveToScrollback: true) }
        else if y < rows - 1 { screen.cursor.y = y + 1 }
        screen.pendingWrap = false
        touch()
    }

    private func reverseIndex() {
        screen.pendingWrap = false
        if screen.cursor.y == screen.scrollTop { scrollDown(1, top: screen.scrollTop, bottom: screen.scrollBottom) }
        else if screen.cursor.y > 0 { screen.cursor.y -= 1 }
        touch()
    }

    /// Removes `n` rows at `top`, inserts blank rows at `bottom`. Rows leaving from row 0 of the primary screen go to scrollback.
    func scrollUp(_ n: Int, top: Int, bottom: Int, saveToScrollback: Bool) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        let save = saveToScrollback && top == 0 && !modes.altScreen
        for _ in 0..<count {
            var removed = screen.rows.remove(at: top)
            if save {
                removed.dirty = true
                scrollback.push(removed)
                if viewportOffset > 0 { viewportOffset = min(viewportOffset + 1, scrollback.count) }
            }
            screen.rows.insert(Row(cols: cols, fill: blank), at: bottom)
        }
        for y in top...bottom { screen.rows[y].dirty = true }
        touch()
    }

    func scrollDown(_ n: Int, top: Int, bottom: Int) {
        let count = min(n, bottom - top + 1)
        guard count > 0 else { return }
        for _ in 0..<count {
            screen.rows.remove(at: bottom)
            screen.rows.insert(Row(cols: cols, fill: blank), at: top)
        }
        for y in top...bottom { screen.rows[y].dirty = true }
        touch()
    }

    private func tabForward(_ n: Int) {
        var x = screen.cursor.x
        for _ in 0..<n {
            var nx = x + 1
            while nx < cols - 1 && !screen.tabStops[nx] { nx += 1 }
            x = min(nx, cols - 1)
        }
        screen.cursor.x = x
        screen.pendingWrap = false
        touch()
    }

    private func tabBackward(_ n: Int) {
        var x = screen.cursor.x
        for _ in 0..<n {
            var nx = x - 1
            while nx > 0 && !screen.tabStops[nx] { nx -= 1 }
            x = max(nx, 0)
        }
        screen.cursor.x = x
        screen.pendingWrap = false
        touch()
    }

    // MARK: - Erase and edit

    private func clearRow(_ y: Int) {
        screen.rows[y] = Row(cols: cols, fill: blank)
        touch()
    }

    private func eraseInRow(_ y: Int, from a: Int, to b: Int) {
        guard a <= b else { return }
        if a > 0, screen.rows[y].cells[a].attrs.contains(.wideSpacer) { screen.rows[y].cells[a - 1] = blank }
        if b + 1 < cols, screen.rows[y].cells[b].attrs.contains(.wide) { screen.rows[y].cells[b + 1] = blank }
        let fill = blank
        for x in a...b { screen.rows[y].cells[x] = fill }
        screen.rows[y].dirty = true
        touch()
    }

    private func eraseDisplay(_ mode: Int) {
        let c = screen.cursor
        switch mode {
        case 0:
            eraseInRow(c.y, from: c.x, to: cols - 1)
            if c.y + 1 < rows { for y in (c.y + 1)..<rows { clearRow(y) } }
        case 1:
            eraseInRow(c.y, from: 0, to: c.x)
            for y in 0..<c.y { clearRow(y) }
        case 2:
            for y in 0..<rows { clearRow(y) }
        case 3:
            scrollback.removeAll()
            viewportOffset = 0
            touch()
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        let c = screen.cursor
        switch mode {
        case 0: eraseInRow(c.y, from: c.x, to: cols - 1)
        case 1: eraseInRow(c.y, from: 0, to: c.x)
        case 2: eraseInRow(c.y, from: 0, to: cols - 1)
        default: break
        }
    }

    func insertBlanks(count: Int, at x: Int, row y: Int) {
        let n = min(count, cols - x)
        guard n > 0 else { return }
        clearWideRemnants(x: x, y: y)
        var cells = screen.rows[y].cells
        cells.removeSubrange((cols - n)..<cols)
        cells.insert(contentsOf: Array(repeating: blank, count: n), at: x)
        if cells[cols - 1].attrs.contains(.wide) { cells[cols - 1] = blank }
        screen.rows[y].cells = cells
        screen.rows[y].dirty = true
        touch()
    }

    private func deleteChars(_ count: Int) {
        let x = screen.cursor.x, y = screen.cursor.y
        let n = min(count, cols - x)
        guard n > 0 else { return }
        clearWideRemnants(x: x, y: y)
        if x + n < cols { clearWideRemnants(x: x + n, y: y) }
        var cells = screen.rows[y].cells
        cells.removeSubrange(x..<(x + n))
        cells.append(contentsOf: Array(repeating: blank, count: n))
        screen.rows[y].cells = cells
        screen.rows[y].dirty = true
        screen.pendingWrap = false
        touch()
    }

    private func eraseChars(_ count: Int) {
        let x = screen.cursor.x
        eraseInRow(screen.cursor.y, from: x, to: min(x + count, cols) - 1)
        screen.pendingWrap = false
    }

    private func insertLines(_ n: Int) {
        let y = screen.cursor.y
        guard y >= screen.scrollTop, y <= screen.scrollBottom else { return }
        scrollDown(n, top: y, bottom: screen.scrollBottom)
        screen.cursor.x = 0
        screen.pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        let y = screen.cursor.y
        guard y >= screen.scrollTop, y <= screen.scrollBottom else { return }
        scrollUp(n, top: y, bottom: screen.scrollBottom, saveToScrollback: false)
        screen.cursor.x = 0
        screen.pendingWrap = false
    }

    private func setScrollRegion(top: Int, bottom: Int) {
        let t = max(1, top), b = min(rows, bottom)
        guard t < b else { return }
        screen.scrollTop = t - 1
        screen.scrollBottom = b - 1
        setCursorAbsolute(row: 0, col: 0)
    }

    func saveCursor() {
        savedCursor = SavedCursor(cursor: screen.cursor, pen: pen, charsets: charsets, activeCharset: activeCharset,
                                  originMode: modes.originMode, pendingWrap: screen.pendingWrap)
    }

    func restoreCursor() {
        guard let s = savedCursor else {
            setCursor(x: 0, y: 0)
            pen = Pen()
            return
        }
        screen.cursor = Cursor(x: min(s.cursor.x, cols - 1), y: min(s.cursor.y, rows - 1))
        pen = s.pen
        charsets = s.charsets
        activeCharset = s.activeCharset
        modes.originMode = s.originMode
        screen.pendingWrap = s.pendingWrap
        touch()
    }

    func reset() {
        screen = Screen(cols: cols, rows: rows)
        inactiveScreen = Screen(cols: cols, rows: rows)
        modes = TerminalModes()
        pen = Pen()
        charsets = [.ascii, .ascii]
        activeCharset = 0
        savedCursor = nil
        savedCursorOther = nil
        savedModes = [:]
        cursorShape = .block
        palette = initialPalette
        viewportOffset = 0
        touch()
    }

    // MARK: - TerminalActions

    public func execute(_ byte: UInt8) {
        switch byte {
        case 0x07: events.append(.bell)
        case 0x08:
            if screen.cursor.x > 0 { screen.cursor.x -= 1 }
            screen.pendingWrap = false
        case 0x09: tabForward(1)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
            if modes.lineFeedNewLine { screen.cursor.x = 0 }
        case 0x0D:
            screen.cursor.x = 0
            screen.pendingWrap = false
        case 0x0E: activeCharset = 1
        case 0x0F: activeCharset = 0
        default: break
        }
        touch()
    }

    public func csi(_ p: CSIParams, intermediates: [UInt8], final: UInt8) {
        defer { touch() }
        if !intermediates.isEmpty {
            csiWithIntermediates(p, intermediates: intermediates, final: final)
            return
        }
        switch final {
        case 0x40: insertBlanks(count: p.get(0, 1), at: screen.cursor.x, row: screen.cursor.y)   // ICH
        case 0x41: cursorUp(p.get(0, 1))                                                       // CUU
        case 0x42, 0x65: cursorDown(p.get(0, 1))                                               // CUD, VPR
        case 0x43, 0x61: setCursor(x: screen.cursor.x + p.get(0, 1), y: screen.cursor.y)       // CUF, HPR
        case 0x44: setCursor(x: screen.cursor.x - p.get(0, 1), y: screen.cursor.y)             // CUB
        case 0x45: cursorDown(p.get(0, 1)); screen.cursor.x = 0                                // CNL
        case 0x46: cursorUp(p.get(0, 1)); screen.cursor.x = 0                                  // CPL
        case 0x47, 0x60: setCursor(x: p.get(0, 1) - 1, y: screen.cursor.y)                     // CHA, HPA
        case 0x48, 0x66: setCursorAbsolute(row: p.get(0, 1) - 1, col: p.get(1, 1) - 1)         // CUP, HVP
        case 0x49: tabForward(p.get(0, 1))                                                     // CHT
        case 0x4A: eraseDisplay(p.get(0))                                                      // ED
        case 0x4B: eraseLine(p.get(0))                                                         // EL
        case 0x4C: insertLines(p.get(0, 1))                                                    // IL
        case 0x4D: deleteLines(p.get(0, 1))                                                    // DL
        case 0x50: deleteChars(p.get(0, 1))                                                    // DCH
        case 0x53: scrollUp(p.get(0, 1), top: screen.scrollTop, bottom: screen.scrollBottom, saveToScrollback: true)  // SU
        case 0x54: scrollDown(p.get(0, 1), top: screen.scrollTop, bottom: screen.scrollBottom) // SD
        case 0x58: eraseChars(p.get(0, 1))                                                     // ECH
        case 0x5A: tabBackward(p.get(0, 1))                                                    // CBT
        case 0x62:                                                                             // REP
            if let s = lastPrinted { for _ in 0..<min(p.get(0, 1), cols) { put(s) } }
        case 0x64: setCursorAbsolute(row: p.get(0, 1) - 1, col: nil)                           // VPA
        case 0x67:                                                                             // TBC
            if p.get(0) == 3 { screen.tabStops = Array(repeating: false, count: cols) }
            else if p.get(0) == 0 { screen.tabStops[screen.cursor.x] = false }
        case 0x72: setScrollRegion(top: p.get(0, 1), bottom: p.get(1, rows))                   // DECSTBM
        case 0x73: saveCursor()                                                                // SCOSC
        case 0x75: restoreCursor()                                                             // SCORC
        default: csiExtended(p, final: final)
        }
    }

    public func esc(intermediates: [UInt8], final: UInt8) {
        defer { touch() }
        if let i = intermediates.first {
            switch (i, final) {
            case (0x28, _): charsets[0] = final == 0x30 ? .decSpecial : .ascii   // ESC ( x
            case (0x29, _): charsets[1] = final == 0x30 ? .decSpecial : .ascii   // ESC ) x
            case (0x23, 0x38):                                                   // DECALN
                var e = Cell(); e.content = 0x45
                for y in 0..<rows { screen.rows[y] = Row(cols: cols, fill: e) }
                screen.scrollTop = 0; screen.scrollBottom = rows - 1
                setCursor(x: 0, y: 0)
            default: break
            }
            return
        }
        switch final {
        case 0x37: saveCursor()                                  // ESC 7
        case 0x38: restoreCursor()                               // ESC 8
        case 0x44: lineFeed()                                    // IND
        case 0x45: lineFeed(); screen.cursor.x = 0               // NEL
        case 0x48: screen.tabStops[screen.cursor.x] = true       // HTS
        case 0x4D: reverseIndex()                                // RI
        case 0x63: reset()                                       // RIS
        case 0x3D: modes.keypadApp = true                        // DECKPAM
        case 0x3E: modes.keypadApp = false                       // DECKPNM
        default: break
        }
    }

    // The following are completed in Task 6. Keep these stubs until then.
    func csiWithIntermediates(_ p: CSIParams, intermediates: [UInt8], final: UInt8) {}
    func csiExtended(_ p: CSIParams, final: UInt8) {}
    public func osc(_ data: [UInt8]) {}
    public func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8) {
        dcsData.removeAll(keepingCapacity: true); dcsFinal = final; dcsIntermediates = intermediates
    }
    public func dcsPut(_ byte: UInt8) { if dcsData.count < 4096 { dcsData.append(byte) } }
    public func dcsUnhook() {}

    func respond(_ s: String) { responses += Array(s.utf8) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TerminalBasics 2>&1 | tail -8`
Expected: all 31 tests pass. Two tests worth double-checking if they fail:
- `insertModeShiftsExistingText` needs `csiExtended` to handle `h`/`l` — it does not yet exist, so temporarily this test may fail; that is acceptable ONLY for this one test until Task 6 (note it in the commit message). All others must pass.
- `pendingWrapClearedByCursorMoves`: LF must keep column and clear `pendingWrap` (`lineFeed()` sets it false).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): terminal printing, cursor, erase, edit and scrolling"
```

---

### Task 6: Terminal — SGR, modes, alternate screen, OSC, DCS, responses

**Files:**
- Modify: `Sources/NyxCore/Terminal/Terminal.swift` (replace the four stubs at the bottom; add the methods below)
- Test: `Tests/NyxCoreTests/TerminalModesTests.swift`

**Interfaces:**
- Consumes: everything from Task 5.
- Produces: full `csiWithIntermediates`, `csiExtended`, `osc`, `dcsUnhook`; `func privateMode(_ m: Int) -> Bool?`; `func setPrivateMode(_ m: Int, _ on: Bool)`; `func switchScreen(alt: Bool, clear: Bool, saveCursor: Bool)`.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/TerminalModesTests.swift`:
```swift
import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

@Test func sgrBasicAttributes() {
    let t = makeTerminal().run(ESC + "[1;3;4;7;9;31;42mX")
    let c = t.cell(0, 0)
    #expect(c.attrs.contains(.bold) && c.attrs.contains(.italic) && c.attrs.contains(.inverse) && c.attrs.contains(.strike))
    #expect(c.underline == .single)
    #expect(c.fg == .indexed(1))
    #expect(c.bg == .indexed(2))
    t.run(ESC + "[0mY")
    #expect(t.cell(1, 0) == { var e = Cell(); e.content = 0x59; return e }())
}

@Test func sgrResetSubsets() {
    let t = makeTerminal().run(ESC + "[1;2;4;5;8m" + ESC + "[22;24;25;28mX")
    let c = t.cell(0, 0)
    #expect(c.attrs == [])
    #expect(c.underline == .none)
}

@Test func sgrExtendedColors() {
    let t = makeTerminal().run(ESC + "[38;2;10;20;30m" + ESC + "[48;5;100mA")
    #expect(t.cell(0, 0).fg == .rgb(10, 20, 30))
    #expect(t.cell(0, 0).bg == .indexed(100))
    t.run(ESC + "[38:5:7m" + ESC + "[48:2::1:2:3m" + ESC + "[58:2:4:5:6mB")
    #expect(t.cell(1, 0).fg == .indexed(7))
    #expect(t.cell(1, 0).bg == .rgb(1, 2, 3))
    #expect(t.cell(1, 0).ul == .rgb(4, 5, 6))
    t.run(ESC + "[39;49;59mC")
    #expect(t.cell(2, 0).fg == .default && t.cell(2, 0).bg == .default && t.cell(2, 0).ul == .default)
}

@Test func sgrBrightAndUnderlineStyles() {
    let t = makeTerminal().run(ESC + "[91;104mA" + ESC + "[4:3mB" + ESC + "[21mC" + ESC + "[4:0mD")
    #expect(t.cell(0, 0).fg == .indexed(9) && t.cell(0, 0).bg == .indexed(12))
    #expect(t.cell(1, 0).underline == .curly)
    #expect(t.cell(2, 0).underline == .double)
    #expect(t.cell(3, 0).underline == .none)
}

@Test func sgrEmptyIsReset() {
    let t = makeTerminal().run(ESC + "[1m" + ESC + "[mX")
    #expect(t.cell(0, 0).attrs == [])
}

@Test func privateModesToggle() {
    let t = makeTerminal().run(ESC + "[?1h" + ESC + "[?7l" + ESC + "[?25l" + ESC + "[?1002h" + ESC + "[?1006h" + ESC + "[?2004h" + ESC + "[?1004h" + ESC + "[?2026h")
    #expect(t.modes.cursorKeysApp && !t.modes.autoWrap && !t.modes.showCursor)
    #expect(t.modes.mouse == .button && t.modes.mouseSGR && t.modes.bracketedPaste && t.modes.focusEvents && t.modes.syncOutput)
    t.run(ESC + "[?1l" + ESC + "[?7h" + ESC + "[?25h" + ESC + "[?1002l")
    #expect(!t.modes.cursorKeysApp && t.modes.autoWrap && t.modes.showCursor && t.modes.mouse == .none)
}

@Test func ansiModesToggle() {
    let t = makeTerminal().run(ESC + "[4h" + ESC + "[20h")
    #expect(t.modes.insertMode && t.modes.lineFeedNewLine)
    t.run("a\nb")
    #expect(t.line(1) == "b")
}

@Test func autoWrapOffOverwritesLastColumn() {
    let t = makeTerminal(cols: 3).run(ESC + "[?7l" + "abcdef")
    #expect(t.text() == ["abf", "", ""])
}

@Test func originModeConfinesCursor() {
    let t = makeTerminal(rows: 5).run(ESC + "[2;4r" + ESC + "[?6h" + ESC + "[Hx")
    #expect(t.cell(0, 1).scalar == "x")
    t.run(ESC + "[9;1Hy")
    #expect(t.cell(0, 3).scalar == "y")
    t.run(ESC + "[6n")
    #expect(t.responseText == ESC + "[3;2R")
}

@Test func alternateScreen1049SavesAndRestores() {
    let t = makeTerminal().run("primary" + ESC + "[?1049h")
    #expect(t.modes.altScreen)
    #expect(t.text() == ["", "", ""])
    t.run("alt")
    #expect(t.line(0) == "alt")
    t.run(ESC + "[?1049l")
    #expect(!t.modes.altScreen)
    #expect(t.line(0) == "primary")
    #expect(t.cur == (7, 0))
}

@Test func alternateScreenHasNoScrollback() {
    let t = makeTerminal(rows: 2).run(ESC + "[?1049h" + "a\r\nb\r\nc")
    #expect(t.scrollback.count == 0)
}

@Test func mode1047And1048() {
    let t = makeTerminal().run("p" + ESC + "[?1048h" + ESC + "[?1047h" + "x" + ESC + "[?1047l" + ESC + "[?1048l")
    #expect(t.line(0) == "p")
    #expect(t.cur == (1, 0))
}

@Test func saveRestoreCursorWithAttributes() {
    let t = makeTerminal().run(ESC + "[2;2H" + ESC + "[1m" + ESC + "7" + ESC + "[H" + ESC + "[0m" + ESC + "8X")
    #expect(t.cell(1, 1).attrs.contains(.bold))
}

@Test func deviceAttributesAndStatus() {
    let t = makeTerminal().run(ESC + "[c")
    #expect(t.responseText == ESC + "[?62;22c")
    t.responses = []
    t.run(ESC + "[>c")
    #expect(t.responseText == ESC + "[>1;10;0c")
    t.responses = []
    t.run(ESC + "[5n")
    #expect(t.responseText == ESC + "[0n")
    t.responses = []
    t.run(ESC + "[2;3H" + ESC + "[6n")
    #expect(t.responseText == ESC + "[2;3R")
}

@Test func requestModeReports() {
    let t = makeTerminal().run(ESC + "[?25$p")
    #expect(t.responseText == ESC + "[?25;1$y")
    t.responses = []
    t.run(ESC + "[?2004$p")
    #expect(t.responseText == ESC + "[?2004;2$y")
    t.responses = []
    t.run(ESC + "[?9999$p")
    #expect(t.responseText == ESC + "[?9999;0$y")
    t.responses = []
    t.run(ESC + "[4$p")
    #expect(t.responseText == ESC + "[4;2$y")
}

@Test func saveAndRestorePrivateModes() {
    let t = makeTerminal().run(ESC + "[?1s" + ESC + "[?1h" + ESC + "[?1r")
    #expect(!t.modes.cursorKeysApp)
}

@Test func cursorShapeSequence() {
    let t = makeTerminal().run(ESC + "[6 q")
    #expect(t.cursorShape == .bar && !t.modes.cursorBlink)
    t.run(ESC + "[3 q")
    #expect(t.cursorShape == .underline && t.modes.cursorBlink)
    t.run(ESC + "[0 q")
    #expect(t.cursorShape == .block && t.modes.cursorBlink)
}

@Test func windowOpsReportSizes() {
    let t = makeTerminal(cols: 80, rows: 24)
    t.pixelSize = (800, 480)
    t.run(ESC + "[18t" + ESC + "[14t" + ESC + "[16t")
    #expect(t.responseText == ESC + "[8;24;80t" + ESC + "[4;480;800t" + ESC + "[6;20;10t")
}

@Test func xtversionResponds() {
    let t = makeTerminal().run(ESC + "[>q")
    #expect(t.responseText == ESC + "P>|Nyx 0.1.0" + ESC + "\\")
}

@Test func oscTitle() {
    let t = makeTerminal().run(ESC + "]0;My Title\u{07}")
    #expect(t.title == "My Title")
    #expect(t.events == [.titleChanged("My Title")])
    t.run(ESC + "]2;Other" + ESC + "\\")
    #expect(t.title == "Other")
}

@Test func oscCwd() {
    let t = makeTerminal().run(ESC + "]7;file://host/Users/nik/my%20dir\u{07}")
    #expect(t.cwd == "/Users/nik/my dir")
    #expect(t.events == [.cwdChanged("/Users/nik/my dir")])
}

@Test func oscHyperlink() {
    let t = makeTerminal().run(ESC + "]8;;https://example.com\u{07}link" + ESC + "]8;;\u{07}plain")
    #expect(t.cell(0, 0).hyperlink == 1)
    #expect(t.cell(4, 0).hyperlink == 0)
    #expect(t.hyperlinks == ["https://example.com"])
    t.run(ESC + "]8;id=x;https://example.com\u{07}again")
    #expect(t.cell(9, 0).hyperlink == 1)
    #expect(t.hyperlinks.count == 1)
}

@Test func oscClipboardWrite() {
    let t = makeTerminal().run(ESC + "]52;c;aGVsbG8=\u{07}")
    #expect(t.events == [.clipboardWrite("hello")])
    t.events = []
    t.run(ESC + "]52;c;?\u{07}")
    #expect(t.events.isEmpty)
}

@Test func oscPaletteSetAndQuery() {
    let t = makeTerminal().run(ESC + "]4;1;#ff0000\u{07}")
    #expect(t.palette.colors[1] == RGB(255, 0, 0))
    #expect(t.events == [.colorsChanged])
    t.run(ESC + "]4;1;?\u{07}")
    #expect(t.responseText == ESC + "]4;1;rgb:ffff/0000/0000" + ESC + "\\")
    t.run(ESC + "]104;1\u{07}")
    #expect(t.palette.colors[1] == RGB(hex: 0xCD0000))
}

@Test func oscForegroundBackgroundQueries() {
    let t = makeTerminal().run(ESC + "]10;?\u{07}" + ESC + "]11;?\u{07}")
    #expect(t.responseText == ESC + "]10;rgb:e5e5/e5e5/e5e5" + ESC + "\\" + ESC + "]11;rgb:0000/0000/0000" + ESC + "\\")
    t.run(ESC + "]11;#102030\u{07}")
    #expect(t.palette.background == RGB(0x10, 0x20, 0x30))
    t.run(ESC + "]111\u{07}")
    #expect(t.palette.background == RGB(0, 0, 0))
}

@Test func oscNotifications() {
    let t = makeTerminal().run(ESC + "]9;done\u{07}" + ESC + "]777;notify;Title;Body;more\u{07}")
    #expect(t.events == [.notification(title: "", body: "done"), .notification(title: "Title", body: "Body;more")])
}

@Test func oscPromptMarks() {
    let t = makeTerminal().run(ESC + "]133;A\u{07}$ " + ESC + "]133;B\u{07}ls\r\n" + ESC + "]133;C\u{07}out\r\n" + ESC + "]133;D;0\u{07}")
    #expect(t.screen.rows[0].promptMark == 2)   // B overwrote A on the same row
    #expect(t.screen.rows[1].promptMark == 3)
    #expect(t.screen.rows[2].promptMark == 4)
}

@Test func decrqssReportsSgrAndMargins() {
    let t = makeTerminal(rows: 10).run(ESC + "[1;31m" + ESC + "[2;5r" + ESC + "P$qm" + ESC + "\\" + ESC + "P$qr" + ESC + "\\" + ESC + "P$qz" + ESC + "\\")
    #expect(t.responseText == ESC + "P1$r0;1;31m" + ESC + "\\" + ESC + "P1$r2;5r" + ESC + "\\" + ESC + "P0$r" + ESC + "\\")
}

@Test func fullResetRestoresDefaults() {
    let t = makeTerminal().run(ESC + "[?1049h" + ESC + "[1m" + ESC + "[?25l" + "x" + ESC + "c")
    #expect(!t.modes.altScreen && t.modes.showCursor && t.pen == Pen())
    #expect(t.text() == ["", "", ""])
}

@Test func mouseModeSwitchesAreExclusive() {
    let t = makeTerminal().run(ESC + "[?1000h" + ESC + "[?1003h")
    #expect(t.modes.mouse == .any)
    t.run(ESC + "[?1003l")
    #expect(t.modes.mouse == .none)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalModes 2>&1 | grep -c "✘"`
Expected: a non-zero number of failures (stubs do nothing).

- [ ] **Step 3: Replace the stubs in Terminal.swift**

Delete the block starting with `// The following are completed in Task 6.` (keeping `dcsHook`, `dcsPut`, `respond`) and add:

```swift
    // MARK: - CSI with intermediates / private markers

    func csiWithIntermediates(_ p: CSIParams, intermediates: [UInt8], final: UInt8) {
        switch intermediates {
        case [0x3F]:                                   // ?
            switch final {
            case 0x68: for i in 0..<p.count { setPrivateMode(p.get(i), true) }
            case 0x6C: for i in 0..<p.count { setPrivateMode(p.get(i), false) }
            case 0x73: for i in 0..<p.count { if let v = privateMode(p.get(i)) { savedModes[p.get(i)] = v } }
            case 0x72: for i in 0..<p.count { if let v = savedModes[p.get(i)] { setPrivateMode(p.get(i), v) } }
            case 0x4A: eraseDisplay(p.get(0))
            case 0x4B: eraseLine(p.get(0))
            default: break
            }
        case [0x3F, 0x24]:                             // ? $ p  DECRQM (private)
            if final == 0x70 { requestMode(p.get(0), isPrivate: true) }
        case [0x24]:                                   // $ p  DECRQM (ANSI)
            if final == 0x70 { requestMode(p.get(0), isPrivate: false) }
        case [0x20]:                                   // SP q  DECSCUSR
            if final == 0x71 { setCursorShape(p.get(0)) }
        case [0x3E]:                                   // >
            if final == 0x63 { respond("\u{1B}[>1;10;0c") }                                  // DA2
            else if final == 0x71 { respond("\u{1B}P>|Nyx \(Terminal.version)\u{1B}\\") }   // XTVERSION
        case [0x3D]:                                   // =
            if final == 0x63 { respond("\u{1B}P!|00000000\u{1B}\\") }                        // DA3
        default: break
        }
    }

    func csiExtended(_ p: CSIParams, final: UInt8) {
        switch final {
        case 0x63: respond("\u{1B}[?62;22c")                                   // DA1
        case 0x68: for i in 0..<p.count { setMode(p.get(i), true) }            // SM
        case 0x6C: for i in 0..<p.count { setMode(p.get(i), false) }           // RM
        case 0x6D: applySGR(p)                                                 // SGR
        case 0x6E: deviceStatus(p.get(0))                                      // DSR
        case 0x74: windowOps(p)                                                // XTWINOPS
        default: break
        }
    }

    // MARK: - Modes

    private func setMode(_ m: Int, _ on: Bool) {
        switch m {
        case 4: modes.insertMode = on
        case 20: modes.lineFeedNewLine = on
        default: break
        }
    }

    func setPrivateMode(_ m: Int, _ on: Bool) {
        switch m {
        case 1: modes.cursorKeysApp = on
        case 3: eraseDisplay(2); setCursorAbsolute(row: 0, col: 0)
        case 6: modes.originMode = on; setCursorAbsolute(row: 0, col: 0)
        case 7: modes.autoWrap = on
        case 9: modes.mouse = on ? .x10 : .none
        case 12: modes.cursorBlink = on
        case 25: modes.showCursor = on
        case 1000: modes.mouse = on ? .normal : .none
        case 1002: modes.mouse = on ? .button : .none
        case 1003: modes.mouse = on ? .any : .none
        case 1004: modes.focusEvents = on
        case 1006: modes.mouseSGR = on
        case 1047: switchScreen(alt: on, clear: on, saveCursor: false)
        case 1048: if on { saveCursor() } else { restoreCursor() }
        case 1049: switchScreen(alt: on, clear: on, saveCursor: true)
        case 2004: modes.bracketedPaste = on
        case 2026: modes.syncOutput = on
        default: break
        }
    }

    func privateMode(_ m: Int) -> Bool? {
        switch m {
        case 1: return modes.cursorKeysApp
        case 6: return modes.originMode
        case 7: return modes.autoWrap
        case 9: return modes.mouse == .x10
        case 12: return modes.cursorBlink
        case 25: return modes.showCursor
        case 1000: return modes.mouse == .normal
        case 1002: return modes.mouse == .button
        case 1003: return modes.mouse == .any
        case 1004: return modes.focusEvents
        case 1006: return modes.mouseSGR
        case 1047, 1049: return modes.altScreen
        case 2004: return modes.bracketedPaste
        case 2026: return modes.syncOutput
        default: return nil
        }
    }

    private func requestMode(_ m: Int, isPrivate: Bool) {
        let state: Int
        if isPrivate {
            state = privateMode(m).map { $0 ? 1 : 2 } ?? 0
        } else {
            switch m {
            case 4: state = modes.insertMode ? 1 : 2
            case 20: state = modes.lineFeedNewLine ? 1 : 2
            default: state = 0
            }
        }
        respond("\u{1B}[\(isPrivate ? "?" : "")\(m);\(state)$y")
    }

    func switchScreen(alt: Bool, clear: Bool, saveCursor save: Bool) {
        guard alt != modes.altScreen else { return }
        if alt {
            if save { saveCursor() }
            let cursor = screen.cursor
            swap(&screen, &inactiveScreen)
            swap(&savedCursor, &savedCursorOther)
            modes.altScreen = true
            if clear { for y in 0..<rows { screen.rows[y] = Row(cols: cols, fill: blank) } }
            screen.cursor = cursor
            screen.pendingWrap = false
            screen.scrollTop = 0
            screen.scrollBottom = rows - 1
        } else {
            swap(&screen, &inactiveScreen)
            swap(&savedCursor, &savedCursorOther)
            modes.altScreen = false
            if save { restoreCursor() }
        }
        viewportOffset = 0
        for y in 0..<rows { screen.rows[y].dirty = true }
        touch()
    }

    private func setCursorShape(_ n: Int) {
        switch n {
        case 0, 1, 2: cursorShape = .block
        case 3, 4: cursorShape = .underline
        case 5, 6: cursorShape = .bar
        default: return
        }
        modes.cursorBlink = n == 0 || n % 2 == 1
    }

    // MARK: - SGR

    private func applySGR(_ p: CSIParams) {
        if p.count == 0 { resetPen(); return }
        let items = p.items
        var i = 0
        while i < items.count {
            let sub = items[i]
            let code = sub[0]
            switch code {
            case 0: resetPen()
            case 1: pen.attrs.insert(.bold)
            case 2: pen.attrs.insert(.dim)
            case 3: pen.attrs.insert(.italic)
            case 4:
                let style = sub.count > 1 ? sub[1] : 1
                pen.underline = UnderlineStyle(rawValue: UInt16(clamp(style, 0, 5))) ?? .single
            case 5, 6: pen.attrs.insert(.blink)
            case 7: pen.attrs.insert(.inverse)
            case 8: pen.attrs.insert(.hidden)
            case 9: pen.attrs.insert(.strike)
            case 21: pen.underline = .double
            case 22: pen.attrs.remove([.bold, .dim])
            case 23: pen.attrs.remove(.italic)
            case 24: pen.underline = .none
            case 25: pen.attrs.remove(.blink)
            case 27: pen.attrs.remove(.inverse)
            case 28: pen.attrs.remove(.hidden)
            case 29: pen.attrs.remove(.strike)
            case 30...37: pen.fg = .indexed(UInt8(code - 30))
            case 38, 48, 58:
                var color: Color?
                if sub.count > 1 {
                    if sub[1] == 5, sub.count > 2 {
                        color = .indexed(UInt8(clamp(sub[2], 0, 255)))
                    } else if sub[1] == 2, sub.count >= 5 {
                        let o = sub.count >= 6 ? 3 : 2
                        color = .rgb(u8(sub[o]), u8(sub[o + 1]), u8(sub[o + 2]))
                    }
                } else if i + 1 < items.count {
                    let mode = items[i + 1][0]
                    if mode == 5, i + 2 < items.count {
                        color = .indexed(u8(items[i + 2][0])); i += 2
                    } else if mode == 2, i + 4 < items.count {
                        color = .rgb(u8(items[i + 2][0]), u8(items[i + 3][0]), u8(items[i + 4][0])); i += 4
                    }
                }
                if let c = color {
                    switch code {
                    case 38: pen.fg = c
                    case 48: pen.bg = c
                    default: pen.ul = c
                    }
                }
            case 39: pen.fg = .default
            case 40...47: pen.bg = .indexed(UInt8(code - 40))
            case 49: pen.bg = .default
            case 59: pen.ul = .default
            case 90...97: pen.fg = .indexed(UInt8(code - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            i += 1
        }
    }

    private func resetPen() {
        let link = pen.hyperlink
        pen = Pen()
        pen.hyperlink = link
    }

    private func u8(_ v: Int) -> UInt8 { UInt8(clamp(v, 0, 255)) }

    private func sgrString() -> String {
        var parts = ["0"]
        if pen.attrs.contains(.bold) { parts.append("1") }
        if pen.attrs.contains(.dim) { parts.append("2") }
        if pen.attrs.contains(.italic) { parts.append("3") }
        if pen.underline != .none { parts.append("4:\(pen.underline.rawValue)") }
        if pen.attrs.contains(.blink) { parts.append("5") }
        if pen.attrs.contains(.inverse) { parts.append("7") }
        if pen.attrs.contains(.hidden) { parts.append("8") }
        if pen.attrs.contains(.strike) { parts.append("9") }
        func color(_ c: Color, base: Int, ext: Int) -> String? {
            switch c.kind {
            case .default: return nil
            case .indexed:
                let i = Int(c.index)
                if i < 8 { return "\(base + i)" }
                if i < 16 { return "\(base + 60 + i - 8)" }
                return "\(ext):5:\(i)"
            case .rgb: return "\(ext):2::\(c.r):\(c.g):\(c.b)"
            }
        }
        if let f = color(pen.fg, base: 30, ext: 38) { parts.append(f) }
        if let b = color(pen.bg, base: 40, ext: 48) { parts.append(b) }
        if pen.ul.kind != .default, let u = color(pen.ul, base: 0, ext: 58) { parts.append(u) }
        return parts.joined(separator: ";")
    }

    // MARK: - Reports

    private func deviceStatus(_ n: Int) {
        switch n {
        case 5: respond("\u{1B}[0n")
        case 6:
            let y = modes.originMode ? screen.cursor.y - screen.scrollTop : screen.cursor.y
            respond("\u{1B}[\(y + 1);\(screen.cursor.x + 1)R")
        default: break
        }
    }

    private func windowOps(_ p: CSIParams) {
        switch p.get(0) {
        case 14: respond("\u{1B}[4;\(pixelSize.height);\(pixelSize.width)t")
        case 16: respond("\u{1B}[6;\(pixelSize.height / rows);\(pixelSize.width / cols)t")
        case 18: respond("\u{1B}[8;\(rows);\(cols)t")
        default: break
        }
    }

    // MARK: - OSC

    public func osc(_ data: [UInt8]) {
        defer { touch() }
        let s = String(decoding: data, as: UTF8.self)
        let code: Int
        let rest: String
        if let semi = s.firstIndex(of: ";") {
            guard let c = Int(s[..<semi]) else { return }
            code = c
            rest = String(s[s.index(after: semi)...])
        } else {
            guard let c = Int(s) else { return }
            code = c
            rest = ""
        }
        switch code {
        case 0, 2:
            title = rest
            events.append(.titleChanged(rest))
        case 4:
            handlePaletteOSC(rest)
        case 7:
            if let url = URL(string: rest), url.scheme == "file" {
                let path = url.path
                cwd = path
                events.append(.cwdChanged(path))
            }
        case 8:
            let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let uri = parts.count > 1 ? String(parts[1]) : ""
            pen.hyperlink = uri.isEmpty ? 0 : UInt16(internHyperlink(uri))
        case 9:
            events.append(.notification(title: "", body: rest))
        case 777:
            let parts = rest.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3, parts[0] == "notify" {
                events.append(.notification(title: String(parts[1]), body: String(parts[2])))
            }
        case 10, 11, 12:
            if rest == "?" {
                let c = code == 10 ? palette.foreground : code == 11 ? palette.background : palette.cursor
                respond("\u{1B}]\(code);\(c.xtermSpec)\u{1B}\\")
            } else if let c = RGB(spec: rest) {
                switch code {
                case 10: palette.foreground = c
                case 11: palette.background = c
                default: palette.cursor = c
                }
                events.append(.colorsChanged)
            }
        case 52:
            let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[1] != "?", let d = Data(base64Encoded: String(parts[1])),
               let text = String(data: d, encoding: .utf8) {
                events.append(.clipboardWrite(text))
            }
        case 104:
            if rest.isEmpty {
                palette.colors = initialPalette.colors
            } else {
                for part in rest.split(separator: ";") {
                    if let i = Int(part), (0..<256).contains(i) { palette.colors[i] = initialPalette.colors[i] }
                }
            }
            events.append(.colorsChanged)
        case 110: palette.foreground = initialPalette.foreground; events.append(.colorsChanged)
        case 111: palette.background = initialPalette.background; events.append(.colorsChanged)
        case 112: palette.cursor = initialPalette.cursor; events.append(.colorsChanged)
        case 133:
            let mark: UInt8
            switch rest.first {
            case "A": mark = 1
            case "B": mark = 2
            case "C": mark = 3
            case "D": mark = 4
            default: return
            }
            screen.rows[screen.cursor.y].promptMark = mark
        default:
            break
        }
    }

    private func handlePaletteOSC(_ rest: String) {
        let parts = rest.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i + 1 < parts.count {
            defer { i += 2 }
            guard let idx = Int(parts[i]), (0..<256).contains(idx) else { continue }
            if parts[i + 1] == "?" {
                respond("\u{1B}]4;\(idx);\(palette.colors[idx].xtermSpec)\u{1B}\\")
            } else if let c = RGB(spec: parts[i + 1]) {
                palette.colors[idx] = c
                events.append(.colorsChanged)
            }
        }
    }

    // MARK: - DCS

    public func dcsUnhook() {
        guard dcsIntermediates == [0x24], dcsFinal == 0x71 else { return }   // DECRQSS
        switch String(decoding: dcsData, as: UTF8.self) {
        case "m": respond("\u{1B}P1$r\(sgrString())m\u{1B}\\")
        case "r": respond("\u{1B}P1$r\(screen.scrollTop + 1);\(screen.scrollBottom + 1)r\u{1B}\\")
        case " q":
            let n: Int
            switch cursorShape {
            case .block: n = modes.cursorBlink ? 1 : 2
            case .underline: n = modes.cursorBlink ? 3 : 4
            case .bar: n = modes.cursorBlink ? 5 : 6
            }
            respond("\u{1B}P1$r\(n) q\u{1B}\\")
        default: respond("\u{1B}P0$r\u{1B}\\")
        }
    }
```

- [ ] **Step 4: Run all terminal tests**

Run: `swift test --filter Terminal 2>&1 | tail -8`
Expected: every test in `TerminalBasics` and `TerminalModes` passes (including `insertModeShiftsExistingText` from Task 5). If `oscCwd` fails, `URL.path` percent-decodes; verify the test string uses `%20`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): SGR, modes, alternate screen, OSC/DCS and terminal reports"
```

---

### Task 7: Resize with reflow, viewport access

**Files:**
- Create: `Sources/NyxCore/Terminal/Terminal+Resize.swift`
- Test: `Tests/NyxCoreTests/TerminalResizeTests.swift`

**Interfaces:**
- Produces on `Terminal`: `func resize(cols: Int, rows: Int)`, `func viewportRow(_ i: Int) -> Row` (0 = top of the visible viewport, accounting for `viewportOffset`), `func scrollViewport(by lines: Int)` (positive = towards older lines), `func scrollViewportToBottom()`.
- Requires making `cols`/`rows` settable inside the module: change their declarations in `Terminal.swift` to `public internal(set) var cols: Int` and `public internal(set) var rows: Int`.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/TerminalResizeTests.swift`:
```swift
import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

@Test func widenRejoinsWrappedLine() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdefghijklmno")
    #expect(t.text() == ["abcdefghij", "klmno", ""])
    t.resize(cols: 20, rows: 3)
    #expect(t.text() == ["abcdefghijklmno", "", ""])
    #expect(!t.screen.rows[0].wrapped)
    #expect(t.cur == (15, 0))
}

@Test func narrowRewrapsAndTracksCursor() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdefghijklmno")
    t.resize(cols: 5, rows: 3)
    #expect(t.text() == ["abcde", "fghij", "klmno"])
    #expect(t.screen.rows[0].wrapped && t.screen.rows[1].wrapped && !t.screen.rows[2].wrapped)
    #expect(t.cur == (4, 2))
    #expect(t.screen.pendingWrap)
    t.run("p")
    #expect(t.text() == ["fghij", "klmno", "p"])
}

@Test func cursorInsideLineFollowsReflow() {
    let t = makeTerminal(cols: 10, rows: 3).run("abcdefghijkl" + ESC + "[1;8H")
    t.resize(cols: 5, rows: 3)
    #expect(t.cur == (2, 1))   // 'h' is index 7 -> row 1, col 2
}

@Test func shrinkHeightPushesTopRowsToScrollback() {
    let t = makeTerminal(cols: 5, rows: 5).run("a\r\nb\r\nc\r\nd\r\ne")
    t.resize(cols: 5, rows: 3)
    #expect(t.text() == ["c", "d", "e"])
    #expect(t.scrollback.count == 2)
    #expect(t.scrollbackLine(0) == "a")
    #expect(t.cur == (1, 2))
}

@Test func growHeightPullsRowsBackFromScrollback() {
    let t = makeTerminal(cols: 5, rows: 3).run("a\r\nb\r\nc\r\nd\r\ne")
    #expect(t.scrollback.count == 2)
    t.resize(cols: 5, rows: 5)
    #expect(t.text() == ["a", "b", "c", "d", "e"])
    #expect(t.scrollback.count == 0)
    #expect(t.cur == (1, 4))
}

@Test func blankRowsBelowCursorAreNotPreserved() {
    let t = makeTerminal(cols: 5, rows: 5).run("a\r\nb")
    t.resize(cols: 5, rows: 2)
    #expect(t.text() == ["a", "b"])
    #expect(t.scrollback.count == 0)
}

@Test func wideCharacterMovesWholeToNextRow() {
    let t = makeTerminal(cols: 4, rows: 3).run("ab漢")
    t.resize(cols: 3, rows: 3)
    #expect(t.text() == ["ab", "漢", ""])
    #expect(t.cell(0, 1).attrs.contains(.wide) && t.cell(1, 1).attrs.contains(.wideSpacer))
}

@Test func alternateScreenDoesNotReflow() {
    let t = makeTerminal(cols: 10, rows: 3).run("primary-line-long" + ESC + "[?1049h" + "abcdefghijklmno")
    t.resize(cols: 20, rows: 3)
    #expect(t.text() == ["abcdefghij", "klmno", ""])
    t.run(ESC + "[?1049l")
    #expect(t.line(0) == "primary-line-long")
}

@Test func resizeResetsMarginsAndTabs() {
    let t = makeTerminal(cols: 10, rows: 5).run(ESC + "[2;3r")
    t.resize(cols: 20, rows: 6)
    #expect(t.screen.scrollTop == 0 && t.screen.scrollBottom == 5)
    #expect(t.screen.tabStops.count == 20 && t.screen.tabStops[16])
}

@Test func viewportScrollingShowsScrollback() {
    let t = makeTerminal(cols: 5, rows: 2).run("a\r\nb\r\nc\r\nd")
    #expect(t.scrollback.count == 2)
    #expect(t.viewportRow(0).cells[0].scalar == "c")
    t.scrollViewport(by: 1)
    #expect(t.viewportOffset == 1)
    #expect(t.viewportRow(0).cells[0].scalar == "b")
    #expect(t.viewportRow(1).cells[0].scalar == "c")
    t.scrollViewport(by: 10)
    #expect(t.viewportOffset == 2)
    #expect(t.viewportRow(0).cells[0].scalar == "a")
    t.run("\r\ne")                       // new output keeps the view anchored
    #expect(t.viewportOffset == 3)
    #expect(t.viewportRow(0).cells[0].scalar == "a")
    t.scrollViewportToBottom()
    #expect(t.viewportOffset == 0)
    #expect(t.viewportRow(1).cells[0].scalar == "e")
    t.scrollViewport(by: -5)
    #expect(t.viewportOffset == 0)
}

@Test func resizeClampsViewportOffset() {
    let t = makeTerminal(cols: 5, rows: 2).run("a\r\nb\r\nc\r\nd")
    t.scrollViewport(by: 2)
    t.resize(cols: 5, rows: 4)
    #expect(t.viewportOffset == 0)
    #expect(t.scrollback.count == 0)
}

@Test func noOpResizeKeepsState() {
    let t = makeTerminal(cols: 10, rows: 3).run("abc")
    let g = t.generation
    t.resize(cols: 10, rows: 3)
    #expect(t.generation == g)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalResize 2>&1 | tail -5`
Expected: compile error, `resize` not found.

- [ ] **Step 3: Write Terminal+Resize.swift**

```swift
extension Terminal {
    // MARK: - Viewport

    /// Row `i` of the visible viewport (0 = top), taking `viewportOffset` into account.
    public func viewportRow(_ i: Int) -> Row {
        let start = scrollback.count - viewportOffset
        let abs = start + i
        return abs < scrollback.count ? scrollback[abs] : screen.rows[abs - scrollback.count]
    }

    /// Positive `lines` scroll towards older content. Clamped to the scrollback size.
    public func scrollViewport(by lines: Int) {
        let v = clamp(viewportOffset + lines, 0, modes.altScreen ? 0 : scrollback.count)
        if v != viewportOffset { viewportOffset = v; touch() }
    }

    public func scrollViewportToBottom() {
        if viewportOffset != 0 { viewportOffset = 0; touch() }
    }

    // MARK: - Resize

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(2, newCols), newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }
        var primary = modes.altScreen ? inactiveScreen : screen
        var alt = modes.altScreen ? screen : inactiveScreen
        reflowPrimary(&primary, newCols: newCols, newRows: newRows)
        simpleResize(&alt, newCols: newCols, newRows: newRows)
        if modes.altScreen { screen = alt; inactiveScreen = primary } else { screen = primary; inactiveScreen = alt }
        cols = newCols
        rows = newRows
        savedCursor = savedCursor.map { clampSaved($0) }
        savedCursorOther = savedCursorOther.map { clampSaved($0) }
        viewportOffset = min(viewportOffset, scrollback.count)
        touch()
    }

    private func clampSaved(_ s: SavedCursor) -> SavedCursor {
        var c = s
        c.cursor = Cursor(x: min(s.cursor.x, cols - 1), y: min(s.cursor.y, rows - 1))
        return c
    }

    /// Alternate screen: truncate or pad, no reflow (full-screen apps redraw themselves).
    private func simpleResize(_ s: inout Screen, newCols: Int, newRows: Int) {
        for y in 0..<s.rows.count {
            var cells = s.rows[y].cells
            if cells.count > newCols {
                cells.removeSubrange(newCols...)
                if cells[newCols - 1].attrs.contains(.wide) { cells[newCols - 1] = Cell() }
            } else if cells.count < newCols {
                cells.append(contentsOf: Array(repeating: Cell(), count: newCols - cells.count))
            }
            s.rows[y].cells = cells
            s.rows[y].dirty = true
        }
        if s.rows.count > newRows { s.rows.removeSubrange(newRows...) }
        while s.rows.count < newRows { s.rows.append(Row(cols: newCols)) }
        s.cursor = Cursor(x: min(s.cursor.x, newCols - 1), y: min(s.cursor.y, newRows - 1))
        s.pendingWrap = false
        s.scrollTop = 0
        s.scrollBottom = newRows - 1
        s.tabStops = Screen.defaultTabStops(cols: newCols)
    }

    /// Primary screen: rejoin soft-wrapped rows into logical lines, re-wrap at the new width, redistribute between scrollback and screen.
    private func reflowPrimary(_ s: inout Screen, newCols: Int, newRows: Int) {
        // 1. Physical rows: scrollback + screen rows up to the last used one.
        var lastUsed = s.cursor.y
        for y in stride(from: s.rows.count - 1, to: lastUsed, by: -1) where !s.rows[y].isBlank {
            lastUsed = y
            break
        }
        var physical: [Row] = []
        physical.reserveCapacity(scrollback.count + lastUsed + 1)
        for i in 0..<scrollback.count { physical.append(scrollback[i]) }
        for y in 0...lastUsed { physical.append(s.rows[y]) }
        let cursorPhysical = scrollback.count + s.cursor.y

        // 2. Logical lines.
        struct Line { var cells: [Cell]; var mark: UInt8 }
        var lines: [Line] = []
        var current: [Cell] = []
        var currentMark: UInt8 = 0
        var cursorLine = 0
        var cursorOffset = 0
        for (i, row) in physical.enumerated() {
            if current.isEmpty { currentMark = row.promptMark }
            if i == cursorPhysical {
                cursorLine = lines.count
                cursorOffset = current.count + s.cursor.x
            }
            current.append(contentsOf: row.cells)
            if !row.wrapped || i == physical.count - 1 {
                var keep = current.count
                while keep > 0 && current[keep - 1].content == 0 && current[keep - 1].bg == .default { keep -= 1 }
                if lines.count == cursorLine && i >= cursorPhysical { keep = max(keep, cursorOffset) }
                current.removeSubrange(keep...)
                lines.append(Line(cells: current, mark: currentMark))
                current = []
            }
        }

        // 3. Re-wrap.
        var out: [Row] = []
        var newCursor = Cursor()
        var pendingWrap = false
        for (li, line) in lines.enumerated() {
            var row = Row(cols: newCols)
            row.promptMark = line.mark
            var x = 0
            var placedCursor = false
            var index = 0
            while index < line.cells.count {
                let c = line.cells[index]
                if c.attrs.contains(.wideSpacer) { index += 1; continue }
                let w = c.attrs.contains(.wide) ? 2 : 1
                if x + w > newCols {
                    row.wrapped = true
                    out.append(row)
                    row = Row(cols: newCols)
                    x = 0
                }
                if li == cursorLine && index == cursorOffset {
                    newCursor = Cursor(x: x, y: out.count)
                    placedCursor = true
                }
                row.cells[x] = c
                if w == 2 {
                    var sp = Cell(); sp.bg = c.bg; sp.attrs.insert(.wideSpacer)
                    row.cells[x + 1] = sp
                }
                x += w
                index += 1
            }
            if li == cursorLine && !placedCursor {
                var cx = x + max(0, cursorOffset - line.cells.count)
                if cx >= newCols { cx = newCols - 1; pendingWrap = true }
                newCursor = Cursor(x: cx, y: out.count)
            }
            out.append(row)
        }

        // 4. Split between scrollback and screen.
        var first = max(0, out.count - newRows)
        if newCursor.y < first { first = newCursor.y }
        scrollback.removeAll()
        for i in 0..<first { scrollback.push(out[i]) }
        var rows = Array(out[first..<min(out.count, first + newRows)])
        while rows.count < newRows { rows.append(Row(cols: newCols)) }
        for i in 0..<rows.count { rows[i].dirty = true }
        s.rows = rows
        s.cursor = Cursor(x: newCursor.x, y: newCursor.y - first)
        s.pendingWrap = pendingWrap
        s.scrollTop = 0
        s.scrollBottom = newRows - 1
        s.tabStops = Screen.defaultTabStops(cols: newCols)
    }
}
```

Also change in `Terminal.swift`: `public private(set) var cols: Int` → `public internal(set) var cols: Int`, same for `rows`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TerminalResize 2>&1 | tail -8`
Expected: 12 pass. Likely trouble spots:
- `narrowRewrapsAndTracksCursor`: cursor was at offset 15 == cells.count, so the "not placed" branch runs with `cx = x = 5 >= 5` → `(4, row 2)` + `pendingWrap`. Then printing `p` wraps to a new row, scrolling the first row out.
- `viewportScrollingShowsScrollback`: `scrollUp` bumps `viewportOffset` when it is non-zero (Task 5 code).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): resize with reflow and viewport scrolling"
```

---

### Task 8: Key encoder

**Files:**
- Create: `Sources/NyxCore/Keys/KeyEncoder.swift`
- Test: `Tests/NyxCoreTests/KeyEncoderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct KeyModifiers: OptionSet { shift = 1, alt = 2, ctrl = 4, cmd = 8 }
  public enum Key: Equatable { case char(Unicode.Scalar), up, down, left, right, home, end, pageUp, pageDown, insert, delete, backspace, tab, enter, escape, f(Int) }
  public struct KeyEvent { key: Key; modifiers: KeyModifiers; text: String? }   // text = what macOS composed (e.g. "ø" for ⌥o)
  public struct KeyEncoderOptions { cursorKeysApp: Bool; keypadApp: Bool; optionAsMeta: Bool }
  public enum KeyEncoder { static func encode(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? }   // nil = not a terminal key (e.g. ⌘ shortcuts)
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/KeyEncoderTests.swift`:
```swift
import Testing
@testable import NyxCore

private func enc(_ key: Key, _ mods: KeyModifiers = [], text: String? = nil, app: Bool = false, meta: Bool = false) -> String? {
    KeyEncoder.encode(KeyEvent(key: key, modifiers: mods, text: text),
                      options: KeyEncoderOptions(cursorKeysApp: app, keypadApp: false, optionAsMeta: meta))
        .map { String(decoding: $0, as: UTF8.self) }
}
private let ESC = "\u{1B}"

@Test func plainCharactersUseComposedText() {
    #expect(enc(.char("a"), text: "a") == "a")
    #expect(enc(.char("o"), [.alt], text: "ø") == "ø")
    #expect(enc(.char("я"), text: "я") == "я")
    #expect(enc(.char("a"), [.shift], text: "A") == "A")
}

@Test func optionAsMetaSendsEscapePrefix() {
    #expect(enc(.char("o"), [.alt], text: "ø", meta: true) == ESC + "o")
    #expect(enc(.char("b"), [.alt], text: "∫", meta: true) == ESC + "b")
}

@Test func controlCharacters() {
    #expect(enc(.char("c"), [.ctrl]) == "\u{03}")
    #expect(enc(.char("a"), [.ctrl, .shift]) == "\u{01}")
    #expect(enc(.char(" "), [.ctrl]) == "\u{00}")
    #expect(enc(.char("["), [.ctrl]) == "\u{1B}")
    #expect(enc(.char("\\"), [.ctrl]) == "\u{1C}")
    #expect(enc(.char("]"), [.ctrl]) == "\u{1D}")
    #expect(enc(.char("/"), [.ctrl]) == "\u{1F}")
    #expect(enc(.char("c"), [.ctrl, .alt]) == ESC + "\u{03}")
}

@Test func arrowsNormalAndApplication() {
    #expect(enc(.up) == ESC + "[A")
    #expect(enc(.down, app: true) == ESC + "OB")
    #expect(enc(.right, [.shift]) == ESC + "[1;2C")
    #expect(enc(.left, [.alt, .ctrl], app: true) == ESC + "[1;7D")
    #expect(enc(.home) == ESC + "[H")
    #expect(enc(.end, app: true) == ESC + "OF")
    #expect(enc(.home, [.ctrl]) == ESC + "[1;5H")
}

@Test func editingKeys() {
    #expect(enc(.insert) == ESC + "[2~")
    #expect(enc(.delete) == ESC + "[3~")
    #expect(enc(.pageUp) == ESC + "[5~")
    #expect(enc(.pageDown, [.shift]) == ESC + "[6;2~")
    #expect(enc(.backspace) == "\u{7F}")
    #expect(enc(.backspace, [.ctrl]) == "\u{08}")
    #expect(enc(.backspace, [.alt]) == ESC + "\u{7F}")
    #expect(enc(.tab) == "\t")
    #expect(enc(.tab, [.shift]) == ESC + "[Z")
    #expect(enc(.enter) == "\r")
    #expect(enc(.enter, [.alt]) == ESC + "\r")
    #expect(enc(.escape) == ESC)
    #expect(enc(.escape, [.alt]) == ESC + ESC)
}

@Test func functionKeys() {
    #expect(enc(.f(1)) == ESC + "OP")
    #expect(enc(.f(4)) == ESC + "OS")
    #expect(enc(.f(1), [.shift]) == ESC + "[1;2P")
    #expect(enc(.f(5)) == ESC + "[15~")
    #expect(enc(.f(12)) == ESC + "[24~")
    #expect(enc(.f(12), [.ctrl]) == ESC + "[24;5~")
}

@Test func commandKeysAreNotTerminalInput() {
    #expect(enc(.char("c"), [.cmd], text: "c") == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeyEncoder 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Write KeyEncoder.swift**

```swift
public struct KeyModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt   = KeyModifiers(rawValue: 2)
    public static let ctrl  = KeyModifiers(rawValue: 4)
    public static let cmd   = KeyModifiers(rawValue: 8)
}

public enum Key: Equatable {
    case char(Unicode.Scalar)
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    case backspace, tab, enter, escape
    case f(Int)
}

public struct KeyEvent: Equatable {
    public var key: Key
    public var modifiers: KeyModifiers
    /// The text macOS composed for this key (dead keys, Option-symbols, IME). Used for plain character input.
    public var text: String?
    public init(key: Key, modifiers: KeyModifiers, text: String?) {
        self.key = key; self.modifiers = modifiers; self.text = text
    }
}

public struct KeyEncoderOptions: Equatable {
    public var cursorKeysApp: Bool
    public var keypadApp: Bool
    public var optionAsMeta: Bool
    public init(cursorKeysApp: Bool, keypadApp: Bool, optionAsMeta: Bool) {
        self.cursorKeysApp = cursorKeysApp; self.keypadApp = keypadApp; self.optionAsMeta = optionAsMeta
    }
}

/// xterm-compatible key encoding.
public enum KeyEncoder {
    public static func encode(_ e: KeyEvent, options: KeyEncoderOptions) -> [UInt8]? {
        let m = e.modifiers
        if m.contains(.cmd) { return nil }
        let param = 1 + (m.contains(.shift) ? 1 : 0) + (m.contains(.alt) ? 2 : 0) + (m.contains(.ctrl) ? 4 : 0)
        let esc: UInt8 = 0x1B

        func cursor(_ final: String) -> [UInt8] {
            if param == 1 { return Array((options.cursorKeysApp ? "\u{1B}O" : "\u{1B}[").utf8) + Array(final.utf8) }
            return Array("\u{1B}[1;\(param)".utf8) + Array(final.utf8)
        }
        func tilde(_ code: Int) -> [UInt8] {
            param == 1 ? Array("\u{1B}[\(code)~".utf8) : Array("\u{1B}[\(code);\(param)~".utf8)
        }
        func withAlt(_ bytes: [UInt8]) -> [UInt8] { m.contains(.alt) ? [esc] + bytes : bytes }

        switch e.key {
        case .up: return cursor("A")
        case .down: return cursor("B")
        case .right: return cursor("C")
        case .left: return cursor("D")
        case .home: return cursor("H")
        case .end: return cursor("F")
        case .insert: return tilde(2)
        case .delete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .backspace: return withAlt([m.contains(.ctrl) ? 0x08 : 0x7F])
        case .tab: return m.contains(.shift) ? Array("\u{1B}[Z".utf8) : withAlt([0x09])
        case .enter: return withAlt([0x0D])
        case .escape: return withAlt([esc])
        case .f(let n):
            switch n {
            case 1...4:
                let final = ["P", "Q", "R", "S"][n - 1]
                return param == 1 ? Array("\u{1B}O\(final)".utf8) : Array("\u{1B}[1;\(param)\(final)".utf8)
            case 5: return tilde(15)
            case 6: return tilde(17)
            case 7: return tilde(18)
            case 8: return tilde(19)
            case 9: return tilde(20)
            case 10: return tilde(21)
            case 11: return tilde(23)
            case 12: return tilde(24)
            default: return nil
            }
        case .char(let s):
            if m.contains(.ctrl) {
                let v = s.value
                var byte: UInt8?
                switch v {
                case 0x61...0x7A: byte = UInt8(v - 0x60)          // a-z
                case 0x41...0x5A: byte = UInt8(v - 0x40)          // A-Z
                case 0x40, 0x20: byte = 0x00                      // @ space
                case 0x5B...0x5F: byte = UInt8(v - 0x40)          // [ \ ] ^ _
                case 0x2F: byte = 0x1F                            // /
                case 0x3F: byte = 0x7F                            // ?
                default: byte = nil
                }
                if let b = byte { return withAlt([b]) }
                return withAlt(Array(String(s).utf8))
            }
            if m.contains(.alt) && options.optionAsMeta {
                return [esc] + Array(String(s).utf8)
            }
            if let t = e.text, !t.isEmpty { return Array(t.utf8) }
            return Array(String(s).utf8)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeyEncoder 2>&1 | tail -5`
Expected: 7 pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(core): xterm key encoder"
```

---

### Task 9: TerminalSession (PTY + reader thread)

**Files:**
- Create: `Sources/NyxCore/Session/TerminalSession.swift`
- Test: `Tests/NyxCoreTests/TerminalSessionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SessionConfig { shellPath: String; argv: [String]; environment: [String: String]; cwd: String?; cols, rows: Int; scrollbackLimit: Int; palette: Palette; static func loginShell(cols:rows:palette:) -> SessionConfig }
  public final class TerminalSession {
      init(config: SessionConfig) throws
      func withTerminal<T>(_ body: (Terminal) throws -> T) rethrows -> T       // serialised access
      func send(_ bytes: [UInt8])                                              // async write to the child
      func resize(cols: Int, rows: Int)
      func terminate()
      var onUpdate: (() -> Void)?            // reader thread, after each chunk
      var onEvent: ((TerminalEvent) -> Void)? // reader thread
      var onExit: ((Int32) -> Void)?         // reader thread, once
      var exitCode: Int32?
      var pid: pid_t
  }
  ```
  Callbacks run on the reader thread. The app hops to the main queue itself.

- [ ] **Step 1: Write the failing tests**

`Tests/NyxCoreTests/TerminalSessionTests.swift`:
```swift
import Testing
import Foundation
@testable import NyxCore

private func config(_ script: String, cols: Int = 40, rows: Int = 5) -> SessionConfig {
    SessionConfig(shellPath: "/bin/sh", argv: ["sh", "-c", script], environment: ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color"],
                  cwd: nil, cols: cols, rows: rows, scrollbackLimit: 100, palette: .xtermDefault())
}

private func waitForExit(_ s: TerminalSession, timeout: TimeInterval = 5) -> Int32? {
    let sem = DispatchSemaphore(value: 0)
    var code: Int32?
    s.onExit = { code = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + timeout)
    return code
}

@Test func sessionFeedsOutputIntoTerminal() throws {
    let s = try TerminalSession(config: config("printf 'a\\nb'; printf '\\033[1mbold'"))
    let code = waitForExit(s)
    #expect(code == 0)
    s.withTerminal { t in
        #expect(t.text()[0] == "a")
        #expect(t.text()[1] == "bbold")
        #expect(t.cell(1, 1).attrs.contains(.bold))
    }
}

@Test func sessionSendsInputAndAnswersReports() throws {
    let s = try TerminalSession(config: config("printf '\\033[6n'; read -r reply; printf '%s' \"$reply\" | od -c | head -1; read -r line; echo got:$line"))
    // CPR reply is written by the session automatically; then we type a line.
    usleep(300_000)
    s.send(Array("hello\n".utf8))
    let code = waitForExit(s)
    #expect(code == 0)
    let lines = s.withTerminal { $0.text() }
    #expect(lines.contains { $0.contains("033   [   1   ;   1   R") })
    #expect(lines.contains { $0.contains("got:hello") })
}

@Test func sessionResizeReachesChild() throws {
    let s = try TerminalSession(config: config("sleep 0.3; stty size"))
    s.resize(cols: 66, rows: 22)
    _ = waitForExit(s)
    let lines = s.withTerminal { $0.text() }
    #expect(lines.contains("22 66"))
    #expect(s.withTerminal { ($0.cols, $0.rows) } == (66, 22))
}

@Test func sessionDeliversEvents() throws {
    var events: [TerminalEvent] = []
    let lock = NSLock()
    let s = try TerminalSession(config: config("printf '\\033]0;hi\\007'"))
    s.onEvent = { e in lock.lock(); events.append(e); lock.unlock() }
    _ = waitForExit(s)
    lock.lock(); defer { lock.unlock() }
    #expect(events == [.titleChanged("hi")])
}

@Test func sessionReportsExitCode() throws {
    let s = try TerminalSession(config: config("exit 3"))
    #expect(waitForExit(s) == 3)
    #expect(s.exitCode == 3)
}

@Test func terminateEndsSession() throws {
    let s = try TerminalSession(config: config("sleep 30"))
    usleep(100_000)
    s.terminate()
    let code = waitForExit(s)
    #expect(code != nil)
}

@Test func loginShellConfigUsesEnvironment() {
    let c = SessionConfig.loginShell(cols: 80, rows: 24, palette: .xtermDefault())
    #expect(c.argv.first?.hasPrefix("-") == true)
    #expect(c.environment["TERM"] == "xterm-256color")
    #expect(c.environment["COLORTERM"] == "truecolor")
    #expect(c.environment["TERM_PROGRAM"] == "Nyx")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TerminalSession 2>&1 | tail -5`
Expected: compile error.

- [ ] **Step 3: Write TerminalSession.swift**

```swift
import Foundation

public struct SessionConfig {
    public var shellPath: String
    public var argv: [String]
    public var environment: [String: String]
    public var cwd: String?
    public var cols: Int
    public var rows: Int
    public var scrollbackLimit: Int
    public var palette: Palette

    public init(shellPath: String, argv: [String], environment: [String: String], cwd: String?,
                cols: Int, rows: Int, scrollbackLimit: Int = 10_000, palette: Palette) {
        self.shellPath = shellPath; self.argv = argv; self.environment = environment; self.cwd = cwd
        self.cols = cols; self.rows = rows; self.scrollbackLimit = scrollbackLimit; self.palette = palette
    }

    /// The user's login shell with terminal environment variables set.
    public static func loginShell(cols: Int, rows: Int, palette: Palette, cwd: String? = nil) -> SessionConfig {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Nyx"
        env["TERM_PROGRAM_VERSION"] = Terminal.version
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let name = "-" + (shell as NSString).lastPathComponent
        return SessionConfig(shellPath: shell, argv: [name], environment: env, cwd: cwd ?? env["HOME"],
                             cols: cols, rows: rows, palette: palette)
    }
}

/// Owns a PTY, its child process and a `Terminal`. A reader thread parses output; all access to the terminal goes through `withTerminal`.
public final class TerminalSession {
    public var onUpdate: (() -> Void)?
    public var onEvent: ((TerminalEvent) -> Void)?
    public var onExit: ((Int32) -> Void)?
    public private(set) var exitCode: Int32?
    public var pid: pid_t { pty.pid }

    private let terminal: Terminal
    private let pty: PTY
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "nyx.pty.write")
    private var thread: Thread?

    public init(config: SessionConfig) throws {
        terminal = Terminal(cols: config.cols, rows: config.rows, scrollbackLimit: config.scrollbackLimit, palette: config.palette)
        pty = try PTY(path: config.shellPath, argv: config.argv, environment: config.environment,
                      cwd: config.cwd, cols: config.cols, rows: config.rows)
        let t = Thread { [weak self] in self?.readLoop() }
        t.name = "nyx.pty.read"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    deinit { pty.close() }

    public func withTerminal<T>(_ body: (Terminal) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(terminal)
    }

    public func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        writeQueue.async { [pty] in pty.write(bytes) }
    }

    public func resize(cols: Int, rows: Int) {
        withTerminal { $0.resize(cols: cols, rows: rows) }
        pty.resize(cols: cols, rows: rows)
    }

    public func terminate() {
        pty.terminate()
    }

    private func readLoop() {
        let capacity = 65536
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let n = pty.read(into: buffer)
            if n <= 0 { break }
            let bytes = UnsafeBufferPointer(start: buffer.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n)
            var responses: [UInt8] = []
            var events: [TerminalEvent] = []
            lock.lock()
            terminal.feed(bytes)
            if !terminal.responses.isEmpty { responses = terminal.responses; terminal.responses.removeAll(keepingCapacity: true) }
            if !terminal.events.isEmpty { events = terminal.events; terminal.events.removeAll() }
            lock.unlock()
            if !responses.isEmpty { send(responses) }
            for e in events { onEvent?(e) }
            onUpdate?()
        }
        let code = pty.wait()
        exitCode = code
        onExit?(code)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TerminalSession 2>&1 | tail -8`
Expected: 7 pass. `sessionSendsInputAndAnswersReports` depends on `od` output format `0000000  033   [   1   ;   1   R  \n`; if it fails, print `lines` and adjust the expected substring to what macOS `od -c` emits (three spaces between characters).

- [ ] **Step 5: Run the whole core suite and commit**

Run: `swift test 2>&1 | tail -3`
Expected: `Test run with N tests passed`.

```bash
git add -A && git commit -m "feat(core): terminal session with PTY reader thread"
```

---

### Task 10: FontSet and GlyphAtlas (NyxRender)

**Files:**
- Delete: `Sources/NyxRender/Placeholder.swift`, `Tests/NyxRenderTests/Placeholder.swift`
- Create: `Sources/NyxRender/FontSet.swift`, `Sources/NyxRender/GlyphAtlas.swift`
- Test: `Tests/NyxRenderTests/FontSetTests.swift`, `Tests/NyxRenderTests/GlyphAtlasTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct CellMetrics: Equatable { width, height, baseline, underlineY, thickness, strikeY: Int }   // device pixels
  public final class FontSet { init(family: String, pointSize: CGFloat, scale: CGFloat, lineHeight: CGFloat = 1.0); let regular, bold, italic, boldItalic: CTFont; let pointSize, scale: CGFloat; let metrics: CellMetrics; func font(bold: Bool, italic: Bool) -> CTFont }
  public enum GlyphText: Hashable { case scalar(UInt32), cluster(String) }
  public struct GlyphKey: Hashable { text: GlyphText; bold: Bool; italic: Bool }
  public struct Glyph: Equatable { x, y, width, height: Int (atlas rect); left, top: Int (offset from cell origin); isColor: Bool }
  public final class GlyphAtlas { static let size = 2048; let texture: MTLTexture; var fonts: FontSet; var generation: Int; init(device: MTLDevice, fonts: FontSet); func setFonts(_:); func reset(); func glyph(for key: GlyphKey) -> Glyph? }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/NyxRenderTests/FontSetTests.swift`:
```swift
import Testing
@testable import NyxRender

@Test func menloMetricsAreSane() {
    let f = FontSet(family: "Menlo", pointSize: 13, scale: 2)
    let m = f.metrics
    #expect(m.width == 16)                      // Menlo 26px advance is 15.65 → ceil
    #expect(m.height > m.baseline && m.baseline > 0)
    #expect(m.underlineY > m.baseline && m.underlineY + m.thickness <= m.height)
    #expect(m.strikeY > 0 && m.strikeY < m.baseline)
    #expect(m.thickness >= 1)
}

@Test func lineHeightMultiplierGrowsCell() {
    let a = FontSet(family: "Menlo", pointSize: 13, scale: 2)
    let b = FontSet(family: "Menlo", pointSize: 13, scale: 2, lineHeight: 1.5)
    #expect(b.metrics.height > a.metrics.height)
    #expect(b.metrics.baseline > a.metrics.baseline)
}

@Test func unknownFamilyFallsBackToSomething() {
    let f = FontSet(family: "No Such Font 123", pointSize: 12, scale: 1)
    #expect(f.metrics.width > 0)
}
```

`Tests/NyxRenderTests/GlyphAtlasTests.swift`:
```swift
import Testing
import Metal
@testable import NyxRender

private func makeAtlas() throws -> GlyphAtlas {
    let device = try #require(MTLCreateSystemDefaultDevice())
    return GlyphAtlas(device: device, fonts: FontSet(family: "Menlo", pointSize: 13, scale: 2))
}

@Test func rasterizesLatinGlyph() throws {
    let atlas = try makeAtlas()
    let g = try #require(atlas.glyph(for: GlyphKey(text: .scalar(0x41), bold: false, italic: false)))
    #expect(g.width > 0 && g.height > 0)
    #expect(!g.isColor)
    #expect(g.top >= 0 && g.top < atlas.fonts.metrics.baseline)
    #expect(g.left > -3)
}

@Test func spaceHasNoGlyph() throws {
    let atlas = try makeAtlas()
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x20), bold: false, italic: false)) == nil)
}

@Test func cachesGlyphs() throws {
    let atlas = try makeAtlas()
    let k = GlyphKey(text: .scalar(0x42), bold: true, italic: false)
    let a = atlas.glyph(for: k), b = atlas.glyph(for: k)
    #expect(a == b)
}

@Test func emojiIsColorAndWide() throws {
    let atlas = try makeAtlas()
    let g = try #require(atlas.glyph(for: GlyphKey(text: .scalar(0x1F600), bold: false, italic: false)))
    #expect(g.isColor)
    #expect(g.width > atlas.fonts.metrics.width)
}

@Test func cyrillicAndClusterFallback() throws {
    let atlas = try makeAtlas()
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x44F), bold: false, italic: false)) != nil)   // я
    #expect(atlas.glyph(for: GlyphKey(text: .cluster("e\u{0301}"), bold: false, italic: false)) != nil)
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x2500), bold: false, italic: false)) != nil)  // ─
}

@Test func overflowResetsAtlas() throws {
    let atlas = try makeAtlas()
    let g0 = atlas.generation
    for cp in 0x4E00..<0x4E00 + 12000 {     // CJK: far more than one 2048² page holds at this size
        _ = atlas.glyph(for: GlyphKey(text: .scalar(UInt32(cp)), bold: false, italic: false))
    }
    #expect(atlas.generation > g0)
    #expect(atlas.glyph(for: GlyphKey(text: .scalar(0x41), bold: false, italic: false)) != nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NyxRenderTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write FontSet.swift**

```swift
import CoreText
import CoreGraphics
import Foundation

/// Cell geometry in device pixels, derived from the regular font.
public struct CellMetrics: Equatable {
    public var width: Int
    public var height: Int
    public var baseline: Int      // from cell top
    public var underlineY: Int    // from cell top
    public var thickness: Int
    public var strikeY: Int       // from cell top
}

public final class FontSet {
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont
    public let pointSize: CGFloat
    public let scale: CGFloat
    public let metrics: CellMetrics

    public init(family: String, pointSize: CGFloat, scale: CGFloat, lineHeight: CGFloat = 1.0) {
        self.pointSize = pointSize
        self.scale = scale
        let px = pointSize * scale
        var base = CTFontCreateWithName(family as CFString, px, nil)
        if (CTFontCopyFamilyName(base) as String).caseInsensitiveCompare(family) != .orderedSame,
           !(CTFontCopyFullName(base) as String).localizedCaseInsensitiveContains(family) {
            base = CTFontCreateWithName("Menlo" as CFString, px, nil)
        }
        regular = base
        bold = CTFontCreateCopyWithSymbolicTraits(base, px, nil, .boldTrait, .boldTrait) ?? base
        italic = CTFontCreateCopyWithSymbolicTraits(base, px, nil, .italicTrait, .italicTrait) ?? base
        boldItalic = CTFontCreateCopyWithSymbolicTraits(base, px, nil, [.boldTrait, .italicTrait], [.boldTrait, .italicTrait]) ?? base

        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        var glyph: CGGlyph = 0
        var ch: UniChar = 0x4D   // 'M'
        CTFontGetGlyphsForCharacters(base, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let width = max(1, Int(ceil(advance.width)))
        let natural = ascent + descent + leading
        let height = max(1, Int(ceil(natural * lineHeight)))
        let extra = CGFloat(height) - natural
        let baseline = Int(round(ascent + extra / 2))
        let thickness = max(1, Int(round(CTFontGetUnderlineThickness(base))))
        let ulOffset = Int(round(-CTFontGetUnderlinePosition(base)))
        let underlineY = min(height - thickness, baseline + max(1, ulOffset))
        let strikeY = max(1, baseline - Int(round(CTFontGetXHeight(base) / 2)))
        metrics = CellMetrics(width: width, height: height, baseline: baseline,
                              underlineY: underlineY, thickness: thickness, strikeY: strikeY)
    }

    public func font(bold: Bool, italic: Bool) -> CTFont {
        switch (bold, italic) {
        case (false, false): return regular
        case (true, false): return self.bold
        case (false, true): return self.italic
        case (true, true): return boldItalic
        }
    }
}
```

- [ ] **Step 4: Write GlyphAtlas.swift**

```swift
import CoreText
import CoreGraphics
import Metal
import Foundation

public enum GlyphText: Hashable {
    case scalar(UInt32)
    case cluster(String)
}

public struct GlyphKey: Hashable {
    public var text: GlyphText
    public var bold: Bool
    public var italic: Bool
    public init(text: GlyphText, bold: Bool, italic: Bool) { self.text = text; self.bold = bold; self.italic = italic }
}

public struct Glyph: Equatable {
    public var x: Int, y: Int, width: Int, height: Int   // rect in the atlas, pixels
    public var left: Int, top: Int                        // draw offset from the cell's top-left, pixels
    public var isColor: Bool
}

/// Rasterises glyphs with Core Text into one RGBA8 texture using shelf packing. When full, it resets and bumps `generation`.
public final class GlyphAtlas {
    public static let size = 2048
    public let texture: MTLTexture
    public private(set) var fonts: FontSet
    public private(set) var generation = 0

    private var cache: [GlyphKey: Glyph?] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    public init(device: MTLDevice, fonts: FontSet) {
        self.fonts = fonts
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: GlyphAtlas.size, height: GlyphAtlas.size, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        texture = device.makeTexture(descriptor: desc)!
    }

    public func setFonts(_ f: FontSet) {
        fonts = f
        reset()
    }

    public func reset() {
        cache.removeAll(keepingCapacity: true)
        shelfX = 0; shelfY = 0; shelfHeight = 0
        generation += 1
    }

    public func glyph(for key: GlyphKey) -> Glyph? {
        if let cached = cache[key] { return cached }
        let g = rasterize(key)
        cache[key] = g
        return g
    }

    private func rasterize(_ key: GlyphKey) -> Glyph? {
        let text: String
        switch key.text {
        case .scalar(let v):
            guard let s = Unicode.Scalar(v) else { return nil }
            text = String(s)
        case .cluster(let s):
            text = s
        }
        if text.isEmpty || text == " " { return nil }

        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        let font = CTFontCreateForString(fonts.font(bold: key.bold, italic: key.italic), cfText, range)
        let isColor = CTFontGetSymbolicTraits(font).contains(.colorGlyphsTrait)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: white]
        guard let attributed = CFAttributedStringCreate(nil, cfText, attrs as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        if bounds.width <= 0 || bounds.height <= 0 { bounds = CTLineGetBoundsWithOptions(line, []) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let pad = 1
        let minX = Int(floor(bounds.minX)), maxX = Int(ceil(bounds.maxX))
        let minY = Int(floor(bounds.minY)), maxY = Int(ceil(bounds.maxY))
        let w = maxX - minX + 2 * pad
        let h = maxY - minY + 2 * pad
        guard w <= GlyphAtlas.size, h <= GlyphAtlas.size,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldSmoothFonts(false)
        ctx.setShouldAntialias(true)
        ctx.setShouldSubpixelPositionFonts(false)
        ctx.setShouldSubpixelQuantizeFonts(true)
        ctx.textPosition = CGPoint(x: CGFloat(pad - minX), y: CGFloat(pad - minY))
        CTLineDraw(line, ctx)

        guard let (ax, ay) = allocate(w: w, h: h), let data = ctx.data else { return nil }
        let src = data.assumingMemoryBound(to: UInt8.self)
        var flipped = [UInt8](repeating: 0, count: w * h * 4)
        flipped.withUnsafeMutableBytes { dst in
            for row in 0..<h {
                memcpy(dst.baseAddress! + row * w * 4, src + (h - 1 - row) * w * 4, w * 4)
            }
        }
        texture.replace(region: MTLRegionMake2D(ax, ay, w, h), mipmapLevel: 0, withBytes: flipped, bytesPerRow: w * 4)
        return Glyph(x: ax, y: ay, width: w, height: h,
                     left: minX - pad, top: fonts.metrics.baseline - maxY - pad, isColor: isColor)
    }

    private func allocate(w: Int, h: Int) -> (Int, Int)? {
        if shelfX + w > GlyphAtlas.size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        if shelfY + h > GlyphAtlas.size {
            reset()
            if h > GlyphAtlas.size { return nil }
        }
        let pos = (shelfX, shelfY)
        shelfX += w
        shelfHeight = max(shelfHeight, h)
        return pos
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter NyxRenderTests 2>&1 | tail -8`
Expected: 9 pass. If `menloMetricsAreSane` fails on `width == 16`, print the actual advance; if Menlo reports a different advance on this OS, change the expectation to the printed value rounded up (the point is that it is `ceil(advance)`).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(render): font metrics and Core Text glyph atlas"
```

---

### Task 11: Metal renderer

**Files:**
- Create: `Sources/NyxRender/Shaders.swift`, `Sources/NyxRender/Renderer.swift`
- Test: `Tests/NyxRenderTests/RendererTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct RenderFrame { cols, rows: Int; lines: [Row]; graphemes: [String]; palette: Palette; cursor: Cursor?; cursorShape: CursorShape; focused: Bool; preedit: String? }
  public final class Renderer {
      init(device: MTLDevice, fonts: FontSet) throws
      let device: MTLDevice; let queue: MTLCommandQueue; let atlas: GlyphAtlas; var fonts: FontSet
      func setFonts(_ f: FontSet)
      func render(_ frame: RenderFrame, to texture: MTLTexture, commandBuffer: MTLCommandBuffer, padding: Int)
      func draw(_ frame: RenderFrame, in layer: CAMetalLayer, padding: Int)
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Tests/NyxRenderTests/RendererTests.swift`:
```swift
import Testing
import Metal
import NyxCore
@testable import NyxRender

private struct Pixel: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

private func renderToPixels(_ frame: RenderFrame, padding: Int = 0) throws -> (Renderer, (Int, Int) -> Pixel) {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let fonts = FontSet(family: "Menlo", pointSize: 12, scale: 1)
    let r = try Renderer(device: device, fonts: fonts)
    let w = fonts.metrics.width * frame.cols + padding * 2
    let h = fonts.metrics.height * frame.rows + padding * 2
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .managed
    let tex = try #require(device.makeTexture(descriptor: desc))
    let cb = try #require(r.queue.makeCommandBuffer())
    r.render(frame, to: tex, commandBuffer: cb, padding: padding)
    let blit = try #require(cb.makeBlitCommandEncoder())
    blit.synchronize(resource: tex)
    blit.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return (r, { x, y in
        let i = (y * w + x) * 4
        return Pixel(r: bytes[i + 2], g: bytes[i + 1], b: bytes[i])
    })
}

private func frame(cols: Int, rows: Int, _ edit: (inout [Row]) -> Void = { _ in }) -> RenderFrame {
    var lines = Array(repeating: Row(cols: cols), count: rows)
    edit(&lines)
    return RenderFrame(cols: cols, rows: rows, lines: lines, graphemes: [], palette: .xtermDefault(),
                       cursor: nil, cursorShape: .block, focused: true, preedit: nil)
}

@Test func paintsCellBackgrounds() throws {
    let f = frame(cols: 2, rows: 1) { $0[0].cells[0].bg = .rgb(255, 0, 0) }
    let (r, px) = try renderToPixels(f)
    let w = r.fonts.metrics.width
    #expect(px(2, 2) == Pixel(r: 255, g: 0, b: 0))
    #expect(px(w + 2, 2) == Pixel(r: 0, g: 0, b: 0))
}

@Test func paintsGlyphPixels() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].content = 0x4D }   // 'M'
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    var lit = 0
    for y in 0..<m.height { for x in 0..<m.width where px(x, y).r > 100 { lit += 1 } }
    #expect(lit > 10)
}

@Test func inverseSwapsColors() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].attrs.insert(.inverse) }
    let (_, px) = try renderToPixels(f)
    #expect(px(1, 1) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
}

@Test func blockCursorPaintsCursorColor() throws {
    var f = frame(cols: 2, rows: 1)
    f.cursor = Cursor(x: 1, y: 0)
    let (r, px) = try renderToPixels(f)
    #expect(px(r.fonts.metrics.width + 2, 2) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
}

@Test func unfocusedCursorIsHollow() throws {
    var f = frame(cols: 1, rows: 1)
    f.cursor = Cursor(x: 0, y: 0)
    f.focused = false
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    #expect(px(0, 0) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
    #expect(px(m.width / 2, m.height / 2) == Pixel(r: 0, g: 0, b: 0))
}

@Test func paddingOffsetsGrid() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].bg = .rgb(0, 255, 0) }
    let (_, px) = try renderToPixels(f, padding: 4)
    #expect(px(1, 1) == Pixel(r: 0, g: 0, b: 0))
    #expect(px(6, 6) == Pixel(r: 0, g: 255, b: 0))
}

@Test func underlineDrawsAtUnderlineY() throws {
    let f = frame(cols: 1, rows: 1) { $0[0].cells[0].underline = .single }
    let (r, px) = try renderToPixels(f)
    let m = r.fonts.metrics
    #expect(px(m.width / 2, m.underlineY) == Pixel(r: 0xE5, g: 0xE5, b: 0xE5))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter Renderer 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write Shaders.swift**

```swift
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Instance {
        float2 pos;
        float2 size;
        float2 uv0;
        float2 uv1;
        float4 color;
        uint kind;
        uint p0; uint p1; uint p2;
    };

    struct Uniforms {
        float2 viewport;
        float atlasSize;
        float pad;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float4 color;
        uint kind [[flat]];
    };

    vertex VOut nyx_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                           const device Instance* instances [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]]) {
        Instance i = instances[iid];
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        float2 px = i.pos + corner * i.size;
        float2 ndc = float2(px.x / u.viewport.x * 2.0 - 1.0, 1.0 - px.y / u.viewport.y * 2.0);
        VOut o;
        o.position = float4(ndc, 0.0, 1.0);
        o.uv = (i.uv0 + corner * (i.uv1 - i.uv0)) / u.atlasSize;
        o.local = corner;
        o.color = i.color;
        o.kind = i.kind;
        return o;
    }

    fragment float4 nyx_fragment(VOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        switch (in.kind) {
        case 0: return in.color;
        case 1: { float a = atlas.sample(s, in.uv).a; return float4(in.color.rgb * a, a); }
        case 2: return atlas.sample(s, in.uv);
        case 3: {
            float wave = 0.5 + 0.35 * sin(in.local.x * 6.2831853 * 2.0);
            float a = 1.0 - smoothstep(0.15, 0.3, abs(in.local.y - wave));
            return float4(in.color.rgb * a, a);
        }
        case 4: { float a = fract(in.local.x * 4.0) < 0.5 ? 1.0 : 0.0; return float4(in.color.rgb * a, a); }
        case 5: { float a = fract(in.local.x * 2.0) < 0.6 ? 1.0 : 0.0; return float4(in.color.rgb * a, a); }
        default: return in.color;
        }
    }
    """
}
```

- [ ] **Step 4: Write Renderer.swift**

```swift
import Metal
import QuartzCore
import NyxCore

/// Everything the renderer needs for one frame. Built by the view under the session lock.
public struct RenderFrame {
    public var cols: Int
    public var rows: Int
    public var lines: [Row]
    public var graphemes: [String]
    public var palette: Palette
    public var cursor: Cursor?
    public var cursorShape: CursorShape
    public var focused: Bool
    public var preedit: String?

    public init(cols: Int, rows: Int, lines: [Row], graphemes: [String], palette: Palette,
                cursor: Cursor?, cursorShape: CursorShape, focused: Bool, preedit: String?) {
        self.cols = cols; self.rows = rows; self.lines = lines; self.graphemes = graphemes; self.palette = palette
        self.cursor = cursor; self.cursorShape = cursorShape; self.focused = focused; self.preedit = preedit
    }
}

/// Matches `struct Instance` in Shaders.swift: 64 bytes.
struct Instance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var uv0: SIMD2<Float>
    var uv1: SIMD2<Float>
    var color: SIMD4<Float>
    var kind: UInt32
    var p0: UInt32 = 0, p1: UInt32 = 0, p2: UInt32 = 0
}

struct Uniforms {
    var viewport: SIMD2<Float>
    var atlasSize: Float
    var pad: Float = 0
}

public enum RendererError: Error { case noCommandQueue }

public final class Renderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let atlas: GlyphAtlas
    public private(set) var fonts: FontSet

    private let pipeline: MTLRenderPipelineState
    private var instances: [Instance] = []
    private var glyphs: [Instance] = []
    private var decorations: [Instance] = []
    private var instanceBuffer: MTLBuffer?

    public init(device: MTLDevice, fonts: FontSet) throws {
        self.device = device
        self.fonts = fonts
        guard let q = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        queue = q
        let library = try device.makeLibrary(source: Shaders.source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "nyx_vertex")
        desc.fragmentFunction = library.makeFunction(name: "nyx_fragment")
        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = .bgra8Unorm
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        atlas = GlyphAtlas(device: device, fonts: fonts)
    }

    public func setFonts(_ f: FontSet) {
        fonts = f
        atlas.setFonts(f)
    }

    public func draw(_ frame: RenderFrame, in layer: CAMetalLayer, padding: Int) {
        guard let drawable = layer.nextDrawable(), let cb = queue.makeCommandBuffer() else { return }
        render(frame, to: drawable.texture, commandBuffer: cb, padding: padding)
        cb.present(drawable)
        cb.commit()
    }

    public func render(_ frame: RenderFrame, to texture: MTLTexture, commandBuffer: MTLCommandBuffer, padding: Int) {
        buildInstances(frame, padding: padding)
        let bytes = max(instances.count * MemoryLayout<Instance>.stride, 64)
        if instanceBuffer == nil || instanceBuffer!.length < bytes {
            instanceBuffer = device.makeBuffer(length: bytes * 2, options: .storageModeShared)
        }
        if !instances.isEmpty {
            instances.withUnsafeBytes { memcpy(instanceBuffer!.contents(), $0.baseAddress!, $0.count) }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let bg = frame.palette.background
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bg.r) / 255, green: Double(bg.g) / 255, blue: Double(bg.b) / 255, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        var uniforms = Uniforms(viewport: SIMD2<Float>(Float(texture.width), Float(texture.height)), atlasSize: Float(GlyphAtlas.size))
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(atlas.texture, index: 0)
        if !instances.isEmpty {
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
        }
        enc.endEncoding()
    }

    // MARK: - Instance building

    private func rgba(_ c: RGB) -> SIMD4<Float> {
        SIMD4<Float>(Float(c.r) / 255, Float(c.g) / 255, Float(c.b) / 255, 1)
    }

    private func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ color: RGB, kind: UInt32 = 0) -> Instance {
        Instance(pos: SIMD2(x, y), size: SIMD2(w, h), uv0: .zero, uv1: .zero, color: rgba(color), kind: kind)
    }

    private func resolve(_ c: Cell, _ p: Palette) -> (fg: RGB, bg: RGB) {
        var fg = c.fg
        if c.attrs.contains(.bold), fg.kind == .indexed, fg.index < 8 { fg = .indexed(fg.index + 8) }
        var f = p.resolve(fg, isForeground: true)
        var b = p.resolve(c.bg, isForeground: false)
        if c.attrs.contains(.inverse) { swap(&f, &b) }
        if c.attrs.contains(.dim) { f = f.scaled(0.6) }
        return (f, b)
    }

    private func buildInstances(_ f: RenderFrame, padding: Int) {
        let m = fonts.metrics
        let cw = Float(m.width), ch = Float(m.height), thick = Float(m.thickness)
        for _ in 0..<2 {
            let gen = atlas.generation
            instances.removeAll(keepingCapacity: true)
            glyphs.removeAll(keepingCapacity: true)
            decorations.removeAll(keepingCapacity: true)

            for y in 0..<min(f.rows, f.lines.count) {
                let row = f.lines[y]
                for x in 0..<min(f.cols, row.cells.count) {
                    let c = row.cells[x]
                    if c.attrs.contains(.wideSpacer) { continue }
                    let isCursor = f.cursor.map { $0.x == x && $0.y == y } ?? false
                    var (fg, bg) = resolve(c, f.palette)
                    let wide = c.attrs.contains(.wide)
                    let px = Float(padding + x * m.width), py = Float(padding + y * m.height)
                    let w = wide ? cw * 2 : cw

                    let blockCursor = isCursor && f.focused && f.cursorShape == .block
                    if blockCursor { bg = f.palette.cursor; fg = f.palette.background }
                    if bg != f.palette.background || blockCursor {
                        instances.append(rect(px, py, w, ch, bg))
                    }

                    if c.content != 0, !c.attrs.contains(.hidden) {
                        let text: GlyphText = c.graphemeIndex.map { .cluster(f.graphemes[$0]) } ?? .scalar(c.content)
                        let key = GlyphKey(text: text, bold: c.attrs.contains(.bold), italic: c.attrs.contains(.italic))
                        if let g = atlas.glyph(for: key) {
                            glyphs.append(Instance(pos: SIMD2(px + Float(g.left), py + Float(g.top)),
                                                   size: SIMD2(Float(g.width), Float(g.height)),
                                                   uv0: SIMD2(Float(g.x), Float(g.y)),
                                                   uv1: SIMD2(Float(g.x + g.width), Float(g.y + g.height)),
                                                   color: rgba(fg), kind: g.isColor ? 2 : 1))
                        }
                    }

                    let ulY = py + Float(m.underlineY)
                    let ulColor = c.ul.kind == .default ? fg : f.palette.resolve(c.ul, isForeground: true)
                    switch c.underline {
                    case .none: break
                    case .single: decorations.append(rect(px, ulY, w, thick, ulColor))
                    case .double:
                        decorations.append(rect(px, ulY - thick, w, thick, ulColor))
                        decorations.append(rect(px, ulY + thick, w, thick, ulColor))
                    case .curly: decorations.append(rect(px, ulY - thick, w, thick * 3, ulColor, kind: 3))
                    case .dotted: decorations.append(rect(px, ulY, w, thick, ulColor, kind: 4))
                    case .dashed: decorations.append(rect(px, ulY, w, thick, ulColor, kind: 5))
                    }
                    if c.attrs.contains(.strike) {
                        decorations.append(rect(px, py + Float(m.strikeY), w, thick, fg))
                    }

                    if isCursor {
                        let cc = f.palette.cursor
                        if !f.focused {
                            decorations.append(rect(px, py, w, thick, cc))
                            decorations.append(rect(px, py + ch - thick, w, thick, cc))
                            decorations.append(rect(px, py, thick, ch, cc))
                            decorations.append(rect(px + w - thick, py, thick, ch, cc))
                        } else if f.cursorShape == .bar {
                            decorations.append(rect(px, py, thick, ch, cc))
                        } else if f.cursorShape == .underline {
                            decorations.append(rect(px, py + ch - thick * 2, w, thick * 2, cc))
                        }
                    }
                }
            }

            if let pre = f.preedit, !pre.isEmpty, let cur = f.cursor {
                var x = cur.x
                for ch in pre {
                    let s = String(ch)
                    let width = CharWidth.width(of: s)
                    guard width > 0, x + width <= f.cols else { break }
                    let px = Float(padding + x * m.width), py = Float(padding + cur.y * m.height)
                    let w = Float(width) * cw
                    instances.append(rect(px, py, w, ch, f.palette.foreground))
                    let text: GlyphText = s.unicodeScalars.count == 1 ? .scalar(s.unicodeScalars.first!.value) : .cluster(s)
                    if let g = atlas.glyph(for: GlyphKey(text: text, bold: false, italic: false)) {
                        glyphs.append(Instance(pos: SIMD2(px + Float(g.left), py + Float(g.top)),
                                               size: SIMD2(Float(g.width), Float(g.height)),
                                               uv0: SIMD2(Float(g.x), Float(g.y)),
                                               uv1: SIMD2(Float(g.x + g.width), Float(g.y + g.height)),
                                               color: rgba(f.palette.background), kind: g.isColor ? 2 : 1))
                    }
                    x += width
                }
            }

            if atlas.generation == gen { break }
        }
        instances.append(contentsOf: glyphs)
        instances.append(contentsOf: decorations)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter NyxRenderTests 2>&1 | tail -8`
Expected: all render tests pass. Also confirm `MemoryLayout<Instance>.stride == 64` by adding this assertion to `RendererTests.swift`:
```swift
@Test func instanceLayoutMatchesShader() { #expect(MemoryLayout<Instance>.stride == 64) }
```

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(render): Metal instanced renderer with runtime-compiled shaders"
```

---

### Task 12: AppKit application (window, TerminalView, input, display link, bundle)

**Files:**
- Replace: `Sources/NyxApp/main.swift`
- Create: `Sources/NyxApp/AppDelegate.swift`, `Sources/NyxApp/MainMenu.swift`, `Sources/NyxApp/Theme.swift`, `Sources/NyxApp/TerminalWindowController.swift`, `Sources/NyxApp/TerminalView.swift`, `Sources/NyxApp/AtomicFlag.swift`
- Create: `Resources/Info.plist`, `scripts/bundle.sh`

**Interfaces:**
- Consumes: `TerminalSession`, `SessionConfig.loginShell`, `KeyEncoder`, `Renderer`, `RenderFrame`, `FontSet`.
- Produces: the `Nyx` executable and `build/Nyx.app`.

This task has no unit tests (all logic with tests lives in Core/Render); it is verified by launching the app and running the checklist steps listed in Step 8.

- [ ] **Step 1: main.swift, AppDelegate, MainMenu, Theme, AtomicFlag**

`Sources/NyxApp/main.swift`:
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
```

`Sources/NyxApp/AppDelegate.swift`:
```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        let controller = TerminalWindowController()
        controller.onClose = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controllers.append(controller)
        controller.showWindow(nil)
    }
}
```

`Sources/NyxApp/MainMenu.swift`:
```swift
import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Nyx", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Nyx", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Nyx", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(item("Nyx", appMenu))

        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        shell.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(item("Shell", shell))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        main.addItem(item("Edit", edit))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(TerminalView.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller", action: #selector(TerminalView.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(TerminalView.zoomReset(_:)), keyEquivalent: "0")
        main.addItem(item("View", view))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        main.addItem(item("Window", window))
        NSApp.windowsMenu = window
        return main
    }

    private static func item(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = submenu
        return i
    }
}
```

`Sources/NyxApp/Theme.swift`:
```swift
import NyxCore

enum Theme {
    /// Default dark theme (Tokyo Night colors, MIT).
    static let nyxDark = Palette(
        ansi: [0x1E2129, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xFF7A93, 0xB9F27C, 0xFF9E64, 0x7DA6FF, 0xBB9AF7, 0x0DB9D7, 0xC0CAF5].map { RGB(hex: $0) },
        foreground: RGB(hex: 0xC0CAF5),
        background: RGB(hex: 0x1A1B26),
        cursor: RGB(hex: 0xC0CAF5)
    )
}
```

`Sources/NyxApp/AtomicFlag.swift`:
```swift
import os

/// A one-bit mailbox between the PTY reader thread and the main thread.
final class AtomicFlag {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value = false

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    func set() {
        os_unfair_lock_lock(lock)
        value = true
        os_unfair_lock_unlock(lock)
    }

    func takeAndClear() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let v = value
        value = false
        return v
    }
}
```

- [ ] **Step 2: TerminalWindowController**

`Sources/NyxApp/TerminalWindowController.swift`:
```swift
import AppKit

final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    var onClose: ((TerminalWindowController) -> Void)?
    private var terminalView: TerminalView?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Nyx"
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self
        do {
            let view = try TerminalView(frame: window.contentView!.bounds)
            view.autoresizingMask = [.width, .height]
            view.onTitleChange = { [weak window] title in window?.title = title.isEmpty ? "Nyx" : title }
            view.onExit = { [weak self] _ in self?.close() }
            window.contentView = view
            window.contentResizeIncrements = view.cellSizePoints
            window.setContentSize(view.size(forCols: 100, rows: 30))
            window.center()
            window.setFrameAutosaveName("NyxMain")
            window.makeFirstResponder(view)
            terminalView = view
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func windowWillClose(_ notification: Notification) {
        terminalView?.terminate()
        onClose?(self)
    }
}
```

- [ ] **Step 3: TerminalView**

`Sources/NyxApp/TerminalView.swift`:
```swift
import AppKit
import Metal
import QuartzCore
import NyxCore
import NyxRender

enum NyxError: Error, LocalizedError {
    case noMetal
    var errorDescription: String? { "Metal is not available on this Mac." }
}

final class TerminalView: NSView, NSTextInputClient {
    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var optionAsMeta = false

    private let session: TerminalSession
    private let renderer: Renderer
    private var fonts: FontSet
    private var fontSize: CGFloat = 13
    private let fontFamily = "Menlo"
    private let padding: CGFloat = 8
    private var displayLink: CADisplayLink?
    private let dirty = AtomicFlag()
    private var markedText = ""
    private var currentEvent: NSEvent?
    private var scrollAccumulator: CGFloat = 0
    private var cols = 80, rows = 24
    private var observers: [NSObjectProtocol] = []

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    init(frame: NSRect) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw NyxError.noMetal }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        fonts = FontSet(family: fontFamily, pointSize: fontSize, scale: scale)
        renderer = try Renderer(device: device, fonts: fonts)
        session = try TerminalSession(config: .loginShell(cols: 80, rows: 24, palette: Theme.nyxDark))
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        session.onUpdate = { [weak self] in self?.dirty.set() }
        session.onEvent = { [weak self] e in DispatchQueue.main.async { self?.handle(e) } }
        session.onExit = { [weak self] code in DispatchQueue.main.async { self?.onExit?(code) } }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    var cellSizePoints: NSSize {
        NSSize(width: CGFloat(fonts.metrics.width) / fonts.scale, height: CGFloat(fonts.metrics.height) / fonts.scale)
    }

    func size(forCols c: Int, rows r: Int) -> NSSize {
        NSSize(width: cellSizePoints.width * CGFloat(c) + padding * 2, height: cellSizePoints.height * CGFloat(r) + padding * 2)
    }

    func terminate() {
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        session.terminate()
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        guard let window else { return }
        updateScale()
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.focusChanged(true) })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.focusChanged(false) })
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    override func layout() {
        super.layout()
        updateGrid()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        if scale != fonts.scale { rebuildFonts() }
        updateGrid()
    }

    private func rebuildFonts() {
        let scale = window?.backingScaleFactor ?? fonts.scale
        fonts = FontSet(family: fontFamily, pointSize: fontSize, scale: scale)
        renderer.setFonts(fonts)
        window?.contentResizeIncrements = cellSizePoints
        updateGrid()
    }

    private func updateGrid() {
        let scale = metalLayer.contentsScale
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        metalLayer.drawableSize = CGSize(width: w, height: h)
        let pad = Int(padding * scale)
        let c = max(2, (w - pad * 2) / fonts.metrics.width)
        let r = max(1, (h - pad * 2) / fonts.metrics.height)
        if c != cols || r != rows {
            cols = c
            rows = r
            session.resize(cols: c, rows: r)
        }
        session.withTerminal { $0.pixelSize = (c * fonts.metrics.width, r * fonts.metrics.height) }
        dirty.set()
    }

    private func focusChanged(_ focused: Bool) {
        let wants = session.withTerminal { $0.modes.focusEvents }
        if wants { session.send(Array((focused ? "\u{1B}[I" : "\u{1B}[O").utf8)) }
        dirty.set()
    }

    // MARK: - Rendering

    @objc private func tick() {
        if dirty.takeAndClear() { render() }
    }

    private func render() {
        let focused = (window?.isKeyWindow ?? false) && window?.firstResponder === self
        let preedit = markedText.isEmpty ? nil : markedText
        let frame: RenderFrame = session.withTerminal { t in
            let lines = (0..<t.rows).map { t.viewportRow($0) }
            let cursor: Cursor? = (t.modes.showCursor && t.viewportOffset == 0) ? t.screen.cursor : nil
            t.clearDirty()
            return RenderFrame(cols: t.cols, rows: t.rows, lines: lines, graphemes: t.graphemes, palette: t.palette,
                               cursor: cursor, cursorShape: t.cursorShape, focused: focused, preedit: preedit)
        }
        renderer.draw(frame, in: metalLayer, padding: Int(padding * metalLayer.contentsScale))
    }

    // MARK: - Events from the terminal

    private func handle(_ event: TerminalEvent) {
        switch event {
        case .titleChanged(let t): onTitleChange?(t)
        case .bell: NSSound.beep()
        case .clipboardWrite(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .colorsChanged: dirty.set()
        case .cwdChanged, .notification: break
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        currentEvent = event
        defer { currentEvent = nil }
        if !(inputContext?.handleEvent(event) ?? false) { sendKey(event) }
    }

    private func keyEvent(from e: NSEvent) -> KeyEvent? {
        var mods: KeyModifiers = []
        let f = e.modifierFlags
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.ctrl) }
        if f.contains(.option) { mods.insert(.alt) }
        if f.contains(.command) { mods.insert(.cmd) }
        let key: Key
        switch e.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 115: key = .home
        case 119: key = .end
        case 116: key = .pageUp
        case 121: key = .pageDown
        case 117: key = .delete
        case 114: key = .insert
        case 51: key = .backspace
        case 48: key = .tab
        case 36, 76: key = .enter
        case 53: key = .escape
        case 122: key = .f(1)
        case 120: key = .f(2)
        case 99: key = .f(3)
        case 118: key = .f(4)
        case 96: key = .f(5)
        case 97: key = .f(6)
        case 98: key = .f(7)
        case 100: key = .f(8)
        case 101: key = .f(9)
        case 109: key = .f(10)
        case 103: key = .f(11)
        case 111: key = .f(12)
        default:
            guard let chars = e.charactersIgnoringModifiers, let s = chars.unicodeScalars.first else { return nil }
            key = .char(s)
        }
        return KeyEvent(key: key, modifiers: mods, text: e.characters)
    }

    private func sendKey(_ e: NSEvent) {
        guard let ke = keyEvent(from: e) else { return }
        let opts = session.withTerminal {
            KeyEncoderOptions(cursorKeysApp: $0.modes.cursorKeysApp, keypadApp: $0.modes.keypadApp, optionAsMeta: optionAsMeta)
        }
        if let bytes = KeyEncoder.encode(ke, options: opts) { send(bytes) }
    }

    private func send(_ bytes: [UInt8]) {
        session.withTerminal { $0.scrollViewportToBottom() }
        session.send(bytes)
        dirty.set()
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        if let e = currentEvent, e.modifierFlags.contains(.control) || (optionAsMeta && e.modifierFlags.contains(.option)) {
            sendKey(e)
            return
        }
        send(Array(text.utf8))
    }

    func doCommand(by selector: Selector) {
        if let e = currentEvent { sendKey(e) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        dirty.set()
    }

    func unmarkText() {
        markedText = ""
        dirty.set()
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let cursor = session.withTerminal { $0.screen.cursor }
        let cell = cellSizePoints
        let rect = NSRect(x: padding + CGFloat(cursor.x) * cell.width,
                          y: bounds.height - padding - CGFloat(cursor.y + 1) * cell.height,
                          width: cell.width, height: cell.height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Mouse and scrolling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func scrollWheel(with event: NSEvent) {
        let cellHeight = cellSizePoints.height
        var lines: Int
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            lines = Int(scrollAccumulator / cellHeight)
            scrollAccumulator -= CGFloat(lines) * cellHeight
        } else {
            lines = Int(event.scrollingDeltaY.rounded(.awayFromZero)) * 3
        }
        guard lines != 0 else { return }
        let (alt, app) = session.withTerminal { ($0.modes.altScreen, $0.modes.cursorKeysApp) }
        if alt {
            let key: Key = lines > 0 ? .up : .down
            let opts = KeyEncoderOptions(cursorKeysApp: app, keypadApp: false, optionAsMeta: false)
            guard let bytes = KeyEncoder.encode(KeyEvent(key: key, modifiers: [], text: nil), options: opts) else { return }
            var all: [UInt8] = []
            for _ in 0..<abs(lines) { all += bytes }
            session.send(all)
        } else {
            session.withTerminal { $0.scrollViewport(by: lines) }
            dirty.set()
        }
    }

    // MARK: - Menu actions

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let bracketed = session.withTerminal { $0.modes.bracketedPaste }
        var bytes: [UInt8] = []
        if bracketed { bytes += Array("\u{1B}[200~".utf8) }
        bytes += Array(text.utf8)
        if bracketed { bytes += Array("\u{1B}[201~".utf8) }
        send(bytes)
    }

    @objc func zoomIn(_ sender: Any?) { fontSize = min(fontSize + 1, 72); rebuildFonts() }
    @objc func zoomOut(_ sender: Any?) { fontSize = max(fontSize - 1, 6); rebuildFonts() }
    @objc func zoomReset(_ sender: Any?) { fontSize = 13; rebuildFonts() }
}
```

- [ ] **Step 4: Build and launch from SwiftPM**

Run: `cd ~/projects/nyx && swift build 2>&1 | tail -3 && (swift run Nyx &) && sleep 4 && pgrep -x Nyx`
Expected: `Build complete!`, a window titled "Nyx" with a zsh prompt appears, and `pgrep` prints a pid. Fix any compile errors before continuing. Then quit the app (⌘Q or `pkill -x Nyx`).

Known pitfalls:
- `displayLink(target:selector:)` on NSView requires macOS 14; the package platform is `.v14` so it is available without `@available`.
- If nothing renders, check `metalLayer.drawableSize` is non-zero (`updateGrid` runs from `layout()`); `wantsLayer = true` must be set before touching `layer`.
- If typing does nothing, verify the window made the view first responder (`makeFirstResponder` in the controller) and `acceptsFirstResponder` returns true.

- [ ] **Step 5: Info.plist and bundle script**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Nyx</string>
    <key>CFBundleIdentifier</key><string>com.nyx.terminal</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Nyx</string>
    <key>CFBundleDisplayName</key><string>Nyx</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
```

`scripts/bundle.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Nyx.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Nyx "$APP/Contents/MacOS/Nyx"
cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "built $APP"
```

Run: `chmod +x scripts/bundle.sh && make app && open build/Nyx.app && sleep 3 && pgrep -x Nyx`
Expected: `built build/Nyx.app`, the app launches from the bundle with a Dock icon and menu bar, `pgrep` prints a pid. Quit it afterwards.

- [ ] **Step 6: Startup time check**

Run: `time (open -W -a "$PWD/build/Nyx.app" --args --nyx-selftest & sleep 1; pkill -x Nyx; wait)` is not precise enough; instead measure with:
```bash
cd ~/projects/nyx && /usr/bin/time -p sh -c 'build/Nyx.app/Contents/MacOS/Nyx & PID=$!; while ! pgrep -q -x Nyx; do :; done; osascript -e "tell application \"System Events\" to (name of every window of process \"Nyx\")" >/dev/null 2>&1; kill $PID'
```
Expected: `real` well under 0.5 s (the window exists within a few hundred ms; the spec target of 150 ms to prompt is measured properly in Task 13's checklist).

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat(app): AppKit window, TerminalView with Metal layer, input and bundle script"
```

- [ ] **Step 8: Manual smoke test (record results in the commit message of Task 13)**

Launch `build/Nyx.app` and verify each item, noting any failure to fix before Task 13:
1. Prompt appears; typing `echo привет 😀` echoes correctly (Cyrillic through the IME path, emoji 2 cells wide).
2. `ls -la --color` shows colors; `printf '\e[1;31mbold red\e[0m \e[4:3mcurly\e[0m\n'` renders bold-bright red and a wavy underline.
3. `vim` opens, `:set number`, insert text, `:q!` restores the shell screen (alt screen restore).
4. `htop` renders without artifacts and quits cleanly with `q`.
5. `cat /dev/urandom | base64 | head -c 100000000` scrolls without the UI freezing; ⌘Q afterwards quits immediately. (Requires macOS `base64`.)
6. Resize the window: the grid resizes in whole-cell increments, a long line reflows.
7. Scroll wheel scrolls back through history; typing jumps back to the bottom.
8. ⌘V pastes clipboard text; in `cat` with bracketed paste (`printf '\e[?2004h'; cat`) the paste is wrapped in `ESC[200~`/`ESC[201~`.
9. ⌘+/⌘- change the font size and keep the grid aligned.
10. `exit` closes the window and the app quits.

---

### Task 13: Benchmark, checklist, README

**Files:**
- Replace: `Sources/NyxBench/main.swift`
- Create: `docs/checklist.md`, `README.md`

- [ ] **Step 1: Benchmark**

`Sources/NyxBench/main.swift`:
```swift
import Foundation
import NyxCore

let args = CommandLine.arguments
var data: [UInt8]
if args.count > 1 {
    data = Array(try Data(contentsOf: URL(fileURLWithPath: args[1])))
} else {
    var s = ""
    s.reserveCapacity(120 * 800_000)
    for i in 0..<800_000 {
        s += "\u{1B}[32mline \(i)\u{1B}[0m \u{1B}[1;34mpath/to/file.swift:\(i % 500):7\u{1B}[0m текст Жё 漢字 filler text to make the line about one hundred bytes long\r\n"
    }
    data = Array(s.utf8)
}

let terminal = Terminal(cols: 200, rows: 50, scrollbackLimit: 10_000)
let start = DispatchTime.now()
data.withUnsafeBufferPointer { buf in
    var offset = 0
    while offset < buf.count {
        let n = min(65536, buf.count - offset)
        terminal.feed(UnsafeBufferPointer(rebasing: buf[offset..<(offset + n)]))
        offset += n
    }
}
let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
let mb = Double(data.count) / 1e6
print(String(format: "%.1f MB in %.3f s = %.0f MB/s", mb, seconds, mb / seconds))
```

Run: `make bench`
Expected: prints a throughput line. The spec target is ≥ 300 MB/s; record the number. If it is below 100 MB/s, profile with `swift build -c release && xcrun --find instruments` is unavailable without Xcode, so instead add `-Xswiftc -Ounchecked` temporarily and check `Cell` copies in `put` (the common fix is to avoid `pen.makeCell()` allocation per character by caching the pen cell in `Terminal` and invalidating it when `pen` changes).

- [ ] **Step 2: Checklist and README**

`docs/checklist.md`:
```markdown
# Manual checklist

Run before every release from `build/Nyx.app`.

## Phase 1
- [ ] Launch to prompt (measure: `printf '\e]0;%s\a' "$(date +%s%N)"` in .zshrc is not needed; use `time swift run -c release Nyx` visually) — window visible < 300 ms
- [ ] Typing Latin, Cyrillic, dead keys (⌥e then e → é), emoji picker (⌃⌘Space)
- [ ] `vim`, `nvim`, `htop`, `fzf`, `claude`, `tmux` render and exit cleanly
- [ ] `vttest` screens 1 (cursor movements) and 2 (screen features) pass visibly
- [ ] `cat` 100 MB of text: UI stays responsive, ⌘Q immediate
- [ ] Resize: no artifacts, reflow of long lines, vim redraws correctly after resize
- [ ] Scrollback with wheel/trackpad; typing returns to bottom
- [ ] ⌘V plain and bracketed paste; multi-line paste
- [ ] ⌘+/⌘-/⌘0 zoom
- [ ] Bell (`printf '\a'`) beeps
- [ ] Title (`printf '\e]0;hello\a'`) changes window title
- [ ] `printf '\e[?25l'` hides cursor; `\e[?25h` shows; `\e[5 q` bar cursor
- [ ] Unfocused window shows hollow cursor
- [ ] Idle CPU 0% in Activity Monitor after 10 s idle
```

`README.md`:
```markdown
# Nyx

A fast, light, native terminal for macOS. Swift + Metal, no dependencies, no Xcode required.

    make run        # build & launch from SwiftPM
    make test       # unit tests (swift-testing)
    make app        # build/Nyx.app
    make install    # copy to /Applications
    make bench      # parser throughput

Design: docs/superpowers/specs/2026-09-03-nyx-terminal-design.md
```

- [ ] **Step 3: Full test run, bundle, commit**

Run: `swift test 2>&1 | tail -3 && make app`
Expected: all tests pass, bundle builds.

```bash
git add -A && git commit -m "feat: benchmark, checklist and README; phase 1 complete"
```

---

## Self-review notes

- Spec coverage for Phase 1 (§11): PTY (T1), width table (T2), parser (T3), model types (T4), printing/cursor/erase/edit/scroll (T5), SGR/modes/alt/OSC/DCS/reports (T6), resize+reflow+viewport (T7), key encoding (T8), reader thread + write queue + responses (T9), font metrics + atlas with fallback (T10), Metal instanced renderer with bg/glyph/decoration passes, cursor styles, underline styles, preedit (T11), AppKit view with IME, scroll, paste, zoom, focus events, bundle (T12), bench + checklist (T13).
- Deliberately deferred to Phase 2 per spec: selection, search, tabs/splits, links, config file, themes switching, shell integration, session restore, notifications UI, cursor blink timer, `exit-behavior = hold`.
- Type names used consistently across tasks: `Terminal.viewportRow`, `Terminal.scrollViewport(by:)`, `Terminal.scrollViewportToBottom`, `Terminal.clearDirty`, `RenderFrame(cols:rows:lines:graphemes:palette:cursor:cursorShape:focused:preedit:)`, `Renderer.render(_:to:commandBuffer:padding:)`, `Renderer.draw(_:in:padding:)`, `GlyphKey(text:bold:italic:)`, `KeyEncoderOptions(cursorKeysApp:keypadApp:optionAsMeta:)`, `SessionConfig.loginShell(cols:rows:palette:cwd:)`.
