---
name: swiftui-visual-harness
description: Reproduce, diagnose, and verify SwiftUI layout/rendering bugs by building a throwaway standalone macOS app from the project's real source files, screenshotting its window, and looking at the result. Use for any "it looks wrong / clipped / truncated / cut off / misaligned / wrong spacing / doesn't update on screen" report, for measuring what actually fits on a device, and for confirming a visual fix instead of reasoning about it. Not for agent/skill harness construction (that is the `harness` skill).
---

# SwiftUI visual harness

Layout bugs do not yield to reading code. Twice in this repo a fix shipped that
"should" have worked and did not, because the real cause was framework
behavior nobody can derive from source: a `List` inside `NavigationSplitView`
measures a row once and ignores every later size change, and SwiftUI's `Text`
silently ignores `NSParagraphStyle.paragraphSpacing` that `boundingRect` counts.
Both were found in minutes by building a small app and looking at it.

Use this whenever a claim about pixels is load-bearing.

## The loop

**1. Reproduce before fixing.** Build the smallest app that shows the bug, using
the project's **real source files** — copy them into the harness directory, do
not reimplement them. A reimplementation proves nothing: the first attempt this
session failed to reproduce precisely *because* it left out
`NavigationSplitView`.

```sh
export HARNESS_DIR="$SCRATCHPAD/harness"     # keep it out of the repo
.claude/skills/swiftui-visual-harness/harness.sh init
cp NookKit/Sources/NookKit/ExpandReveal.swift "$HARNESS_DIR"/   # the real thing
# edit "$HARNESS_DIR/App.swift" to stage the screen
.claude/skills/swiftui-visual-harness/harness.sh shot before
```

Then **Read the PNG**. Looking at it is the point; a green build is not evidence.

If it does not reproduce, add the surrounding structure back one piece at a time
until it does — the missing piece is the cause.

**2. Bisect once it reproduces.** Keep a full copy (`App.full.swift`) and remove
one structural element per run, capturing each: `shot no_swipe`,
`shot no_translation`, `shot plain_list`. The element whose removal changes the
picture is the culprit. Pair the reproducing case with a control that should be
fine, so "it looks bad" is not a judgment call.

**3. Instrument when the picture is not enough.** Print numbers to stderr from
inside the view and grep them — never guess at what the framework did:

```swift
FileHandle.standardError.write("PROBE row=\(row) h:\(before)->\(after)\n".data(using: .utf8)!)
```

```sh
HARNESS_GREP='^PROBE' .claude/skills/swiftui-visual-harness/harness.sh log probe 8
```

This is how the actual cause surfaced: the SwiftUI cell's fitting size grew
78→100pt while `NSOutlineView` stayed at 78 — visible in one line of output,
invisible in the source.

**4. Check analytical predictions against ground truth.** If code predicts a
size, render the same content and read the real height back, then compare:

```swift
Text(attributed).background(GeometryReader { g in
    Color.clear.onAppear { actual = g.size.height }
})
```

Treat a single `onAppear` read with suspicion — it can capture a pre-layout
value. Trust a number only when several sizes agree on the same ratio.

**5. Verify the fix in the same harness**, with the shipping code pasted back
in. Then **mutation-test it**: deliberately reintroduce the fault and confirm
the harness (or the test you wrote) catches it. A mutation that *passes* is
information — this session's first mutation attempt passed, which revealed the
guarded invariant was not what the comment claimed.

## Commands

```sh
harness.sh init                    # scaffold HARNESS_DIR with App.swift + .app bundle
harness.sh shot <name> [delay]     # build, launch, capture <name>.png, quit
harness.sh at <name> <t1> [t2 …]   # capture at several delays in ONE run
harness.sh log <name> [seconds]    # run in foreground, grep stderr (HARNESS_GREP)
```

Every `*.swift` in `HARNESS_DIR` is compiled (except `winid.swift`). Set
`HARNESS_DIR` to a scratchpad path; never commit the harness.

Use `at` for anything time-dependent (a timer, an animation, text that should
refresh): capturing twice in one run is the only way to prove something advanced
rather than rendered once. Two separate `shot` runs cannot show that.

## Gotchas that cost real time here

- **`@main` + top-level code** — the script passes `-parse-as-library`; without
  it `swiftc` rejects `@main`. Do not name a file `main.swift`.
- **Window size must be pinned.** `.windowResizability(.contentSize)` is in the
  skeleton for a reason: otherwise the window opens at an inherited size and
  every width-dependent measurement is meaningless.
- **`screencapture -o -l<id>`** omits the drop shadow, which is what you want
  for measuring. (The `update-macos-screenshot` skill deliberately omits `-o`
  because a hero image wants the shadow.)
- **The PNG is the window, not your content.** With a 720×420 content frame the
  capture came back 1440×944 at 2×: the width matches exactly (720 × 2), the
  height carries ~52pt of titlebar on top. Measure content by differencing two
  captures, or read sizes back with `GeometryReader` — do not treat image
  height as content height.
- **Quit before rebuilding** — the script does it, but a stale process holding
  the binary silently captures the old build.
- **Screen Recording permission** is required; a black or empty capture is
  almost always that, not a code bug.
- **Copied iOS code may not compile as-is.** `NSAttributedString.boundingRect`
  needs `context:` on UIKit; `Thread.current` and `Thread.isMainThread` are
  unavailable from async contexts (use `pthread_main_np() != 0` when the thread
  genuinely is what you mean to observe).
- **Synthetic gestures are unreliable.** Trackpad-style swipes posted via
  `CGEvent` did not open a `List`'s swipe actions here. Prefer driving state
  directly, or query the AppKit layer (`tableView.delegate?.tableView?(_:rowActionsForRow:edge:)`)
  to check what was *registered* — then say plainly that the rendering itself
  was not verified.
- **zsh quirks** when scripting around it: quote `--include='*.swift'` for
  `grep`, and `sed -i ''` needs the empty argument on macOS.

## Scope and honesty

This is a **macOS** harness. Shared code (anything in `NookKit`) tests directly;
iOS-only surfaces need a macOS stand-in, and a stand-in only proves things about
the shared layer — say so rather than implying the iOS screen was verified.

When the harness cannot reproduce a report (an intermittent, long-idle, or
device-specific symptom), state that plainly, note which candidate causes the
change eliminates, and ask the user to watch for recurrence. Do not present a
harness pass as proof of a fix it did not exercise.
