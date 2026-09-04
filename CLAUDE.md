# Nyx

A native macOS terminal: Swift + Metal + AppKit, own VT core. SwiftPM only -- there is no Xcode on
this machine, only Command Line Tools, so Metal shaders are compiled at runtime from source.

## Ground rules

- `NyxCore` must not import AppKit, Metal, CoreText or QuartzCore. `NyxRender` must not import
  CNyxPTY. Decision logic goes in `NyxCore` behind a pure interface and is unit-tested; the AppKit
  layer converts events and draws. This is not style: the environment denies Accessibility, so
  anything left in a view handler cannot be verified at all.
- Tests are **swift-testing** (`import Testing`, `@Test`, `#expect`). XCTest is NOT available.
- The build must stay warning-free, and `make bench` at or above 180 MB/s.
- Swift 6.0.3 in Swift 5 language mode, `// swift-tools-version:5.10`, macOS 14.

## swift-testing: mutating calls inside `#expect` / `#require`

The macros rewrite the expression into a closure that captures the receiver immutably, so a
**mutating** method called inside one never compiles — and the error points at the macro expansion
rather than at your code:

```
macro expansion #require:2:6: error: cannot use mutating member on immutable value: '$0' is immutable
```

Hoist the call to a local first:

```swift
let created = g.newGroup(named: "a", colorIndex: 1, fromTabAt: 0)   // not inside #require
let group = try #require(created).id
```

Three separate agents lost time to this on 2026-09-04. It is a property of the macro, not of the
code under test.

## Tests hang at launch

`swift test` in this checkout intermittently hangs in `swiftpm-testing-helper` before any test body
runs. It is a runner flake, not a code defect:

```
pkill -9 -f swiftpm-testing-helper; pkill -9 -f swift-test
swift test --no-parallel
```

Never wait on a background test run — kill the helper and re-run in the foreground.
