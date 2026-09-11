# How work gets done on Nyx

The goal is one sentence, and every decision is measured against it: **Nyx has to be the best
terminal on macOS** — faster, better-looking and more useful day to day than iTerm2, Ghostty,
WezTerm and Warp. Not shipped; better.

The user's standing brief is `.superpowers/sdd/nyx-brief.md`. The three complaints it opens with
are the ones every rule below exists to prevent:

1. Work reported as done while the path through the interface did not exist or did nothing.
2. Interfaces that need a manual to understand.
3. A feature that intercepts a core action (paste, copy, click) and degrades to silence.

## Definition of done

A change is done when all of these hold. They are the product manager's checklist, so meeting them
before review saves a round trip.

- Reachable: a person can get to it from the keyboard, the menu, the palette or the mouse, and the
  path has been exercised the way they would reach it (`docs/testing.md`, rung 6).
- Decided in `NyxCore`: the logic is a pure value type with tests; the AppKit layer converts and
  draws. Anything left in a view handler is unverifiable here.
- Green on every rung it can reach: warning-free build, `swift test --no-parallel`, bench ≥ 180,
  UI snapshots looked at.
- Failure has a face: when the precondition is missing (no shell integration, no theme file, no
  Metal device, a bad config line) the user is told, or the core action still happens. Never
  silence.
- Written down: README for the feature, `docs/configuration.md` for a key or action, the spec's
  §11 if it closes a promise there, a doc comment on the type that explains *why*.
- Reviewed: the `product-manager` agent has said APPROVED.

## The loop

```
brief / spec  ─▶  plan (docs/superpowers/plans/)  ─▶  branch  ─▶  TDD per task  ─▶  verify ladder
                                                                                        │
                        merge to main  ◀──  product-manager APPROVED  ◀──  code review  ◀┘
```

- **Spec** is `docs/superpowers/specs/2026-09-03-nyx-terminal-design.md`. Its §11 records what was
  promised and which promises are kept; when a promise is closed, §11 says so with the date.
- **Plans** live in `docs/superpowers/plans/`, one per phase, as task briefs an implementer can
  execute without asking questions. The ledger of a phase in flight is
  `.superpowers/sdd/<plan>/progress.md`; the review diffs and task reports sit beside it.
- **Branches** are named for the phase or the feature (`phase2a-daily-driver`, `loose-ends`,
  `feat/prompt-marks`). Merge into `main` with a merge commit whose message says what the branch
  delivered and the test count and bench figure at merge.
- **Reviews** come in two passes, spec compliance first (does it do what the brief says, nothing
  more, nothing less), then code quality. Findings are Critical / Important / minor; minors may be
  deferred but are written in the ledger. Then the product manager judges it as a user.

## Roles

Subagents in `.claude/agents/`. Each one is a specialist with its own tools and verdict format;
dispatch the one whose question you are asking.

| Agent | Ask it to | Verdict |
|---|---|---|
| `product-manager` | Judge finished work as a user; last gate before "done" | APPROVED / NEEDS WORK |
| `nyx-engineer` | Implement one task brief end to end: tests first, core first, verified | a report with the evidence |
| `code-reviewer` | Review a diff: spec compliance, then quality, against this project's rules | Critical / Important / minor, with a verdict |
| `qa-adversary` | Break a build: run it, probe it, drive real paths, read the PNGs | BROKEN / DEGRADED / SOUND, with steps |
| `vt-conformance` | Check terminal behaviour against xterm, vttest and the reference terminals | a table of sequence × terminal |
| `render-performance` | Measure a renderer or parser change rather than believe it | numbers, before and after |
| `design-reviewer` | Look at the interface as pictures and say what a person would notice | a ranked list with the PNG names |

## Skills

`.claude/skills/`. Each is a checklist for one kind of change; use the one that matches before
starting, not after.

| Skill | When |
|---|---|
| `nyx-verifying-a-change` | Before saying anything is done, fixed, or working |
| `nyx-core-first` | Deciding where a piece of logic goes, or extracting one from a view |
| `nyx-vt-sequences` | Adding or changing an escape sequence, a mode, or a terminal reply |
| `nyx-rendering` | Touching `RenderFrame`, the renderer, the atlas, or anything drawn per row |
| `nyx-ui-chrome` | Adding or changing drawn interface: bars, sheets, popups, banners |
| `nyx-config-keys` | Adding a config key, a theme property, an action, or a key binding |

## Commit messages

The title is a sentence that says what changed for the user or the code, in plain words, without
a type prefix unless the change is purely mechanical (`chore:`, `ci:`). The body says why, what
was considered, and the verification figures. Examples from the log:

```
Move the dirty-flag decision where it can be tested
Themes: colours that are actually distinguishable
fix(paste): the editor never opened, so a multi-line paste did nothing at all
```

Never commit a QA hook, a scratch file, or a `.DS_Store`. `git add` by name.

## Language

Code, comments, commit messages, README and these docs are in English. The design spec and the
user's brief are in Russian, and are quoted as written. Doc comments explain *why* a thing is the
way it is, including the mistake it prevents; a comment that restates the code is deleted.
