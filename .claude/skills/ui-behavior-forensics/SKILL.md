---
name: ui-behavior-forensics
description: Find the cause of UI misbehaviour that happens over time or in response to input — the scroll moves on its own, the caret or focus jumps, something flickers, "it only happens when I press space", "only on the last line", "only while syncing". Instrument the running app to a log, then read the numbers and reconstruct the arithmetic. Use when a standalone repro does not reproduce, when the symptom depends on input kind or position, and to measure the cost of a fix before shipping it. For static "it looks wrong / clipped / misaligned" use `swiftui-visual-harness` instead.
---

# UI behaviour forensics

`swiftui-visual-harness` answers *what does this look like*. This answers *what
moved, who moved it, and why now* — the class of bug where a screenshot is fine
and the complaint is motion, timing, or focus.

The whole skill is one idea: **stop reasoning about the framework and record what
it did.** Framework geometry is not derivable from source. In the case this came
from, the cause was a number the app never computed and no code path asked for.

## The rule that matters most

**If a standalone probe fails to reproduce the symptom twice, stop modelling and
instrument the real app.**

The record that earned this rule: five probes, each with a real `NSTextView` in a
real `NSScrollView` in a real window, the editor's pipeline replicated, a
simulated input method, spell checking on, real key events posted, the caret at
the document end and the view scrolled to the bottom. All five measured a
viewport that did not move at all. The app's own log answered it in **one**
reproduction by the user.

Probes are excellent at *comparing candidates* once you can reproduce (see
below). They are poor at reproducing a symptom whose cause you have not yet
guessed — you can only model what you already suspect.

## Instrument the running app

Copy `GeometryLog.swift` into the module, add call sites, ask the user for one
reproduction, read the file yourself.

```sh
find ~/Library/Containers -name 'ui-forensics.log'   # sandboxed app → container tmp
```

Four things make the log worth reading:

**Phase tags around every step of the path.** Not "before and after" — every
step, named: `will-change`, `enter`, `publish`, `restyle`, `update`, `next`
(a `DispatchQueue.main.async` hop, for what lands a turn later). The cause was
identified as the transition between two specific tags.

**An observer for moves nothing asked for.** `GeometryLog.observe(clip, in:)`
records every `boundsDidChange`. This is the one that mattered: the framework was
clamping and then animating back, and no call site of ours was involved.

**Every number that could take part in the arithmetic.** Offset, content height,
content width, viewport height, insets, selection, marked-range length, text
length. The answer came out of reconstructing one logged value from three others;
a missing field would have hidden it.

**A classification of the input, never its content.** `GeometryLog.kind(of:)`
gives `space` / `delete` / `char` / `newline`, which is what lets you split the
log by what the user pressed. Log lengths and offsets, not what somebody wrote.

Buffer in memory and flush at ~200 lines and on teardown. Writing per event
perturbs the timing you are measuring. `#if DEBUG` so it cannot ship.

## Read it with arithmetic, not adjectives

```sh
S=.claude/skills/ui-behavior-forensics
python3 $S/readlog.py "$LOG" --transitions origin docH   # who changes what
python3 $S/readlog.py "$LOG" --per will-change --by kind  # split by input kind
python3 $S/readlog.py "$LOG" --trail will-change          # whole events, verbatim
```

`--transitions` localises it. Here it printed `125  change.restyle → bounds` for
`docH`, which named the phase in one line.

Then **reconstruct the suspicious number from the others.** This is the step that
turns a hypothesis into a cause. One event, verbatim:

```
change.restyle  origin 584.50  docH 957.50
bounds          origin 455.50  docH 837.50
change.next     origin 455.50  docH 991.50
bounds  458 → 468 → 487 → 510 → 536 → 561 → 583
```

`455.50 == 837.50 − 424 + 42` exactly — content height, minus viewport height,
plus the reserved inset. So the viewport was clamped to the maximum offset implied
by a document 837.50pt tall, while the real height (991.50, one turn later) made
the writer's 584.50 valid all along. 837.50 was TextKit's *estimate* of the part
it had not laid out. Nothing downstream can tell an estimate from a measurement.

An exact reconstruction is proof. A number that *nearly* fits is a different
mechanism — keep looking.

The trailing ramp (`458 → 468 → … → 583`) is also information: evenly spaced
values over ~100ms is an *animation*, which is why the user saw shaking rather
than a jump. Count the samples before deciding what the user is looking at.

And read the symptom's own asymmetry against the log. "Backspace moves up, space
moves up and then back" was explained by the same clamp: delete stopped at it,
space went on to reveal the caret. When the user's description has two cases,
the right cause explains both.

## Compare candidates numerically, with a control

Once something is reproducible — in the app or a probe — never decide by eye.
Configurations down the side, a metric across:

```
                    moves  reversals  spread   origins
clamp (shipping)      9/10          5  191.5   482 520 554 482 520 554 …
clamp + 96pt slack    6/10          5  174.0   546 546 601 546 546 601 …
no clamp              1/10          0  118.5   554 554 554 554 554 554 …
clamp, mid-document   0/10          0    0.0   flat
```

Three things this table did that prose could not:

- **`reversals`** — back-and-forth, not just movement — is the metric that
  matches what a person calls shaking. Pick the metric the complaint is about.
- **The control row.** Mid-document was flat, which is exactly what the user had
  said ("with any line below it, it's fine"). A measurement that agrees with the
  user's own observation is a measurement you can trust for the rows they cannot
  see.
- **Disproof.** Row two killed a fix I liked: reserving space below the text did
  not help, so the clamp was the cause and not the tightness. Ruling a candidate
  out is as valuable as confirming one, and much cheaper than shipping it.

## Measure the cost of the fix, not just its effect

The fix was "finish the layout inside the change", which sounds like it might make
typing slow. It was measured before shipping:

```
                 first pass   every pass after
~500 words           2.80ms             0.10ms
~2000 words         51.38ms             0.45ms
~8000 words        134.47ms             0.98ms
```

Which turned a risky change into a known trade: sub-millisecond per keystroke,
one expensive first pass — moved to view creation, where milliseconds are
invisible. Any fix that adds work to a per-keystroke or per-frame path gets this
table.

## Verify the fix with the same log

The log appends across launches, so one file holds the runs before the fix and the
run after it. Split on time gaps in `systemUptime` and compare — the verification
costs nothing extra and is independent of "it feels better now":

```
 run  keystrokes  events with a reversal  worst swing   docH wobbled
   0          43              15 (35%)        223.5pt      18 / 42
   1         189              59 (31%)        223.5pt     107 / 189
   2         678               0 ( 0%)         72.5pt       4 / 638
```

Run 2 is after the fix: no reversals at all in 678 keystrokes, against roughly one
in three before, and the document height stopped wobbling. The 72.5pt that remains
is single-direction movement — the view following the caret, which is what it is
supposed to do. Distinguishing "still moves" from "still shakes" is the difference
between a fix and a regression, and only the metric can do it.

Ask the user for the reproduction; do not claim a verification you did not run.

## Measure constants instead of inventing them

A reserved strip was given `44` because two lines "looked like about that". The
real numbers, from `NSHostingView(rootView:).fittingSize`: 32pt at one line, 47pt
at two. The constant was wrong for the case it existed for. Either measure it, or
do not use a constant — that one became `onGeometryChange`, which is right at any
text size.

`ImageRenderer` + `Read` on the PNG is the quick way to see a small piece of
SwiftUI without a whole harness app; `fittingSize` is the quick way to get its
number.

## Driving the app: what works, what does not

- **`NSApp.postEvent(_:atStart:)` proves event ordering.** A synthesized ⌘Q
  keyDown showed a local monitor swallowing it before the menu's key equivalent:
  guard on, `applicationShouldTerminate` never reached; guard off, reached once.
  Definitive, no permissions, ten lines.
- **Posted key events do not reach a text view in an app that is not frontmost.**
  They vanish from the queue. A probe launched from a shell usually is not
  frontmost, so "keystrokes landed 0" means the harness, not the app.
- **`insertText` bypasses the input context.** Automatic spelling correction, text
  completion and link detection all live there, so none of them can be tested this
  way — which is why a probe cannot rule them in or out.
- **`setMarkedText` then `insertText` models an input method's stages** (jamo by
  jamo, then commit). Worth doing when the symptom is about Korean, Japanese or
  Chinese input: the interesting boundary is where the composition commits, which
  is exactly where a space lands.
- **Synthetic events are not evidence about the real input path.** Say which one
  you drove.

## The same method finds a flaky test

A test that fails once in ten runs is the same problem in a smaller box: rare,
timing-dependent, and not reproducible on demand. What worked:

**Loop until it fails, and capture everything.** Not `grep '✘'` — the whole output.
A filtered loop earlier had thrown away the one line that mattered.

```sh
for i in $(seq 1 40); do
  out=$(swift test 2>&1)
  # A build error must count as a failure, or a broken tree reports 40 clean runs.
  if echo "$out" | grep -qE "error:|✘"; then echo "run $i"; echo "$out" | grep -A 12 '✘ Test "'; break; fi
done
```

Then **do not touch the tree while the loop runs.** Editing tests mid-loop
invalidated two verification runs here.

**Read the failure's values.** The flake was a font-size comparison, and the
captured output said `NSFont = "Helvetica 12.00 pt."` — AppKit's fallback font,
which named the cause outright: font resolution asked from a parallel test thread
instead of the main one. A bare `#expect(a > b)` would never have said that, so
the expectations now carry the font names.

**Read the crash report for a signal 11.** `~/Library/Logs/DiagnosticReports/*.ips`
is JSON after the first line, and the faulting thread's frames name both the API
and the queue:

```
queue = com.apple.root.default-qos.cooperative     ← not the main thread
AttributedString.init(_:including:) → enumerateAttributes → swift_dynamicCast → SIGSEGV
```

Two anomalies, one cause. Both were AppKit used off the main actor from suites the
repo's own convention says should be `@MainActor`, and annotating them took 45
consecutive clean runs where the pair had been showing up every 8 to 20.

**Quote the odds.** At a rate of about one in fifteen, 45 clean runs is
`(14/15)^45 ≈ 5%` — worth saying, because "it stopped happening" is not a result.

**A test that finds a second bug should not be made to pass.** The italic coverage
added while verifying this uncovered a real one: `***bold italic***` renders as
italic alone. `withKnownIssue` records it, keeps the suite green, and fails loudly
if it is ever fixed — better than deleting the assertion or fixing an unrelated
engine in the same breath.

## Honesty

Do not ship a fix for a mechanism you have not measured. This session shipped two
that were wrong before instrumenting: keeping a clamp "as a safety net" made the
bottom edge measurably worse than the code it replaced (9 moves against 6), and
turning off automatic rewriting was plausible, principled, and not the cause. Both
cost the user a round of testing.

If you must ship on a hypothesis — because the reasoning is independently sound,
or the user is waiting — say plainly that it is reasoned rather than measured, and
ship the instrumentation with it so the next round produces an answer instead of
another guess.

Take the instrumentation out once it has answered the question. The pattern lives
here, and re-adding it is a two-minute job.

A peer review of the patch is worth a round on top of this (`peer-agent`): on this
bug it caught two real defects in my own fixes — an ordering that reverted
committed Korean input, and a state release that dropped a value it should have
kept.
