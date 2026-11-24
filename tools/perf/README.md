# Nook performance fixtures and runs

These tools generate isolated, deterministic libraries and drive the DEBUG-only
performance harness. Generated fixtures live under `perf-data/`; captured logs
live under `perf-runs/`. Both paths are ignored by Git. The runner restores a
golden copy before every launch and passes `-NookPerfLibrary`, so it neither
opens the user's real library nor writes its bookmark/UserDefaults.
Each launch also gets an isolated article-preview cache. A scenario may explicitly
pass `-NookPerfPreviewCache <path>` to reuse a measured cache across launches.

## Generate golden libraries

Run these commands from the repository root:

```sh
NOOK_GEN_PERF_LIB="$PWD/perf-data/golden/lib-5k" NOOK_GEN_N=5000 \
  swift test --package-path NookKit --filter PerfLibraryGenerator
NOOK_GEN_PERF_LIB="$PWD/perf-data/golden/lib-10k" NOOK_GEN_N=10000 \
  swift test --package-path NookKit --filter PerfLibraryGenerator
NOOK_GEN_PERF_LIB="$PWD/perf-data/golden/lib-20k" NOOK_GEN_N=20000 \
  swift test --package-path NookKit --filter PerfLibraryGenerator
```

Each invocation also rewrites `perf-data/feeds/<lib>/{none,trickle,burst,big1}`,
so every library has its own feed XML. Each feed serves only its newest 30
items plus the variant's additions, like a real rolling feed. Article ids are
`<feedID>#<guid>`, the shape `RSSFeedService`/`ReaderStore` produce on refresh,
so `none` yields zero new articles. Running the same command twice produces
byte-identical fixture contents.

The fixture is a library's steady state, not an ideal one: `NookContent.json`
holds bodies only for the 600 ids `ReaderStore.recentArticleIDs(from:)` keeps
(newest by `Article.isOrderedBefore`, `bodyRetentionLimit`), as every replica
save does. Feed-window articles outside that set load without a body, so
today's full-equality merge counts them as changed on a `none` refresh (B1
`mergeChangedNoNew` > 0, lib-5k: 3,440 changed articles over 296 feeds). That is
the spurious-change bug Phase 1's MergeProjection fixes by comparing a body
only when the stored article has one. The always-on test
`none XML merge adds zero articles; changed count tracks the body-retention merge bug`
parses all 300 XML files with the real parser, overlays the shard's
read/star/category state, calls the store merge hook, and asserts zero new ids
and that every change is a body-less stored article. It asserts changed > 0
today; Phase 1 flips `PerfLibraryGenerator.noneRefreshIsChangeFree` to `true`
so it asserts zero changed articles and no republish.

`Nook/Info.plist` currently has `NSAppTransportSecurity` →
`NSAllowsArbitraryLoads=true`, so the cleartext `http://127.0.0.1:8765` feed
server needs no additional ATS exception. If that broad permission is removed,
add a localhost development exception before using refresh scenarios.

## Run

Build first with `make perf-build`: DEBUG instrumentation with `-O` app code,
in its own `DerivedData-perf/` so `make build` (`-Onone`) never replaces it.
`run.sh` launches that app (`NOOK_PERF_APP` overrides the path). `run.begin`
logs `opt=-O|-Onone`; after the run, `run.sh` exits 1 on anything but `-O`
(defence in depth, since only `make perf-build` stamps a launchable app), and
perfreport refuses to summarize or compare runs whose opt levels differ.

A single run takes a label (`[A-Za-z0-9._-]`,
no leading dot), library (a generated name or directory), driver JSON, and
optional feed variant. `--only ID[,ID]` runs just those steps
(`-NookPerfOnly`) and adds the ids to the log name. Port 8765 must be free; the runner refuses to start
next to a stale feed server. `make perf-build` stamps the checkout identity
from `tools/perf/build-id.sh` into the built Debug Info.plist's `NookBuildSHA`,
even when an incremental build does not relink: the full HEAD SHA on a clean
tree, or `<HEAD>-dirty-<12 hex>` otherwise, where the hex is a SHA-256 over
`git diff HEAD --binary` plus the paths and contents of untracked, non-ignored
files (NookKit and the synchronized extension folders compile untracked files).
The runner computes the same identity and refuses a missing or different stamp;
rebuild after every commit (including docs-only commits) or source edit, and
after adding or removing an untracked file. `-NookPerfSHA` carries that same
checkout identity, and `run.begin binarySha=` reads the build stamp directly
from the app bundle, so the two stay comparable. Each child receives an explicit `-NookPerfLog` path beneath
`perf-runs/.work/<label>/` (Foundation may ignore `TMPDIR`); its log is archived as
`perf-runs/<label>/<lib>-<script>-<variant>-<n>.log`. The runner never reads or
moves the real Nook container log or changes the installed app's defaults.
Other app defaults (for example `@AppStorage` and sort orders) may still be
written in the unsigned-build preferences domain, separate from the installed
sandboxed app's container domain.

The runner executes `Nook.app/Contents/MacOS/Nook` directly as its child
(never `open`) and waits for that PID; only that PID is ever signalled. It
refuses `/Applications/Nook.app`, an app outside the repository unless
`NOOK_PERF_APP` is paired with `NOOK_PERF_ALLOW_EXTERNAL_APP=1`, a
team-signed app (perf builds are unsigned), and any build without a matching
perf-build stamp. A plain `make build` product has no stamp and is refused. Saved-window restoration is disabled for the launch via
argument-domain defaults, which are never persisted. So are
`nookPlusSessionConfigured` and `geminiKeyConfigured` (both `NO`), so the UI
and Plus code never believe a session or key exists. The runner also passes
`-SUEnableAutomaticChecks NO`. In DEBUG perf mode `UpdateController` returns
before reading pending updates or creating Sparkle, so no appcast fetch, update
chip, or Sparkle `SU*`/pending-update defaults write occurs (including manual
update actions, which have no updater to call).

Two causes of a launch that logs `run.begin` but never reaches
`perf.library` were verified with `sample`; both fixes are DEBUG-only and
leave release behavior unchanged:

- **Keychain prompt in an unsigned build.** `ContentView.init` builds a
  `PlusStore`, whose `PlusCredential.current` read (`SecItemCopyMatching`)
  blocks the main thread on a Keychain access prompt nobody answers. Under
  `-NookPerfLibrary` (`PerfLaunch.isActive`), `PlusCredential.current` and
  `GeminiCredential.apiKey` return nil without touching the Keychain. Because
  every Plus call then fails as `.sessionInvalid` and signs out, the writes are
  guarded too: `PlusCredential.store`/`signOut`, `GeminiCredential.setAPIKey`,
  `PlusOwnFeed.remember`, and the local app reset are no-ops (or throw) in a
  perf run, so it can never delete the real Keychain items or rewrite their
  defaults flags.
- **No initial window.** A directly executed child without saved application
  state never gets its `Window("main")`. When no window is visible one second
  after launch, the DEBUG launch hook sends this process a
  `kAEReopenApplication` event (what a Dock click sends) and retries once at
  three seconds. The window comes from SwiftUI's default reopen handling.
  `Window` is single-instance, so the reopen cannot add a second window. The
  hook also sets the activation policy to regular and activates the process;
  it logs `perf.activation` lines (`windowsBefore=`/`windows=` for a reopen).

Each child gets its own `perf-runs/.work/<label>/launch.XXXXXX/` holding
`stdout.log`, `stderr.log`, and the `-NookPerfLog` file. That path takes
precedence over `NOOK_PERF_LOG_PATH`; without either the logger's usual path is
unchanged. Failure messages cite that launch's `stderr.log`.

A watchdog requires `perf.library` within 60 seconds and caps the whole child
at 600 seconds (switch/scroll/toggle/misc) or 300 seconds (`refresh*.json`).
`NOOK_PERF_LIBRARY_TIMEOUT_SECONDS` and `NOOK_PERF_RUN_TIMEOUT_SECONDS` override
those positive-integer limits for testing. On timeout it terminates only its
child PID, escalates to SIGKILL after one second if it is still alive, appends
`perf.driver.error reason=launch-timeout` to the archived log (even if no app
log exists), and exits 124. Other child/driver failures also exit nonzero.
`--xctrace` attaches to the same child PID and stops the recording when the
child exits, so it omits the very earliest launch activity. The runner stops
xctrace with SIGINT and waits for the `.trace` to be written, escalating to
SIGTERM after 60 seconds and SIGKILL after 10 more.

```sh
tools/perf/run.sh before-$(git rev-parse --short HEAD) lib-10k tools/perf/scripts/switch.json none
tools/perf/run.sh after-p2 lib-10k tools/perf/scripts/refresh-trickle.json trickle
tools/perf/run.sh --only C3 after-p2 lib-5k tools/perf/scripts/scroll.json none
```

The first step a launch runs is cold. Unless it states `coldFirst` (A1 does),
the driver adds a rep 0 logged `cold=1 warmup=1`, which perfreport leaves out
of every median (`warmup` in the dropped counts). A script whose one rep per
launch is the sample states `"coldFirst": false`.

To capture an Instruments trace, put `--xctrace` first:

```sh
tools/perf/run.sh --xctrace 'Animation Hitches' after-p2 lib-10k tools/perf/scripts/scroll.json none
```

The matrix runner maps the groups to the driver scripts in `tools/perf/scripts`
(set `NOOK_PERF_SCRIPTS=/another/directory` otherwise): A → `switch.json`
(5k/10k/20k), B → `refresh-none.json` (B1), `refresh-trickle.json`
(B2/B3/B5), `refresh-big1.json` (B4), C → `scroll.json` (10k/20k),
D → `toggle.json`, E → `misc.json`. A single legacy `refresh.json` is still
accepted. Refresh-driven steps (all of B, plus C4 and E3 under `trickle`) run
one launch per step and repetition, five each, because the first refresh
consumes the new items and the golden library is restored only per launch.
Each such launch uses a derived copy of the group script (one rep,
`coldFirst: false`) with `--only <ID>`. Derived scripts are written under
`perf-runs/.work/<label>/scripts`:

```sh
tools/perf/run-all.sh before-$(git rev-parse --short HEAD)
```

`run-all.sh` refuses a label whose `perf-runs/<label>` directory is non-empty,
so a retry cannot silently mix more than five repetitions into a median. Use a
new label after an interrupted matrix. A failed launch skips the remaining
launches in that group; other groups continue. Only run-all's own INT/TERM
trap aborts the matrix; child exit codes 130/143 alone count as group failures.
The runner logs signal-killed app/trace failures as `reason=signal` and exits 1,
reserving 130/143 for its own INT/TERM traps. An interrupted group is recorded
as aborted in `groups.txt` before exit. The final `groups.txt` summary
records every group outcome, and any failure makes run-all exit 1. B3 and E3 wait for ambient refresh to
finish; with 300 feeds, two fetches at a time, and the deterministic 50–800 ms
latency they normally take about 65 seconds each. An interactive six-at-a-time
refresh is about 21 seconds; the full matrix is typically 45–90 minutes (and can
take longer for a pre-fix 20k build).

For a real wheel-path check, make Nook frontmost and grant Accessibility access
to the invoking Terminal/shell. `wheel.swift fling` posts phased wheel and
momentum events; `constant` posts a three-second constant-velocity scroll:

```sh
tools/perf/wheel.swift fling
tools/perf/wheel.swift constant
```

## Report and compare

```sh
python3 .claude/skills/ui-behavior-forensics/perfreport.py perf-runs/before-abc1234
python3 .claude/skills/ui-behavior-forensics/perfreport.py --compare before-abc1234 after-p2
python3 .claude/skills/ui-behavior-forensics/perfreport.py perf-runs/after-p2 --trail A1
python3 .claude/skills/ui-behavior-forensics/perfreport.py perf-runs/after-p2 --json
python3 .claude/skills/ui-behavior-forensics/perfreport.py --selftest
```

Records are keyed by scenario, library, and feed variant (from the log file
name). Warm repetitions are summarized as median and worst; the cold rep
(`cold=` on the stats or `scenario.begin` line, else rep 0) is kept separate,
and `ttfr=-1` (no selection in the scenario) is not a sample. `mergeP95` is
read as logged (older builds: `mergeMs`, which was the per-call p95);
`publish/dur` uses `activeDur` when present; `updateInPlaceMs` is gated on
`updateInPlaceMaxMs` (with total and mean retained), while `rowcontent` and
`body` are divided by `toggles=` (or the count from `toggle.json`). `--trail ID` prints each rep's raw
window from `scenario.begin` through `scenario.stats`. Compare output applies
the thresholds from `docs/perf/measurement.md` and calls out every common
lower-is-better metric whose median worsened by more than 10%, including rises
from 0. `droppedPct`, `missedSelection`, and `readerTTFR` feed the C3/D1 thresholds,
which show NO DATA for builds that do not log them.

Invalid repetitions are dropped before summarizing, as `measurement.md` §4
requires: `perf.quiesce.timeout id=…` and `perf.settle.timeout id=…` drop the
next stats record of that id, `perf.frame.timeout` drops the next stats record,
and `perf.driver.error` drops every record in that log file. The summary and
compare output print how many reps and files were dropped and why; `--trail`
marks a dropped rep.

Besides the table, every summarized scenario, library, variant, and metric that
a §5 gate covers is judged (A2–A14, B stalls/fallback ratio/hitch ratio, C
stalls on 10k, D list.body per toggle, D1 stalls≥100, D5 hlcTick per open, the
20k stalls≥250 gate, cold A1 ttfr ≤400) and listed under "Gate failures".
`--strict` exits 1 when that list is not empty (for `--compare`, the after
run), for CI-style use:

```sh
python3 .claude/skills/ui-behavior-forensics/perfreport.py --compare before-abc1234 after-p2 --strict
```

## Magazine and 3D map

`tools/perf/scripts/magazine.json` measures the actual Beta grid with repeated
native gesture/momentum flicks. `magazine-media.json` exercises real preview
fetches and Apple Intelligence title/excerpt translation against a local copy
of an actual RSS library. Its detailed frame CSVs remain beside the launch logs;
`python3 tools/perf/media-report.py <archived-log> <launch-directory>` groups
the callbacks by scrolling and media-animation windows. `tools/perf/orbit.sh` compiles the real map canvas
in a standalone optimized native-window benchmark with 20,000 fixture nodes.
It opens a foreground window and exits after 260 display callbacks. See
[the measurement report](../../docs/perf/magazine-and-spatial-map.md) for scope,
controls and results. Classic scenarios and their table probe are unchanged.

## Background-only captures

Pass `-NookPerfBackground YES` in a scenario's `launchArgs` to leave the user's
foreground application alone. The driver skips activation and keeps its window
behind other windows. In this isolated DEBUG launch only, Magazine preview
requests remain enabled despite the inactive scene, so originals and thumbnails
can still be exercised. Widget publishing writes `.nook-perf-widget.json` inside
the fixture and never reloads installed widgets. The production foreground and
network-demand rules are unchanged.

Use main-thread watchdog stalls and phase timings for these runs. Occlusion can
throttle display callbacks; do not present background frame statistics as the
user's foreground scrolling FPS. See
[widget and refresh investigation](../../docs/perf/widget-and-refresh.md).
