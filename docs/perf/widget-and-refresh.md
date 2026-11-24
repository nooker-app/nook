# Widget recovery and refresh work

## Blank widgets after an app update

The shared `ReadingSnapshot.json` was valid: 4,991 bytes, 3,258 unread stories,
and six entries in each reading collection. App and extension shared the same
signed App Group. The failure happened when WidgetKit archived the view, not
when Nook loaded RSS data.

The installed app was 0.1.75 (build 79). Its widget process had survived since
November 16. The running arm64 executable UUID was
`F008756A-51B8-3C23-BF56-3101A9945AAD`, while the installed executable UUID was
`02F02239-E052-3C83-B8C7-51EF4AAF3696`. `chronod` repeatedly rejected it with
`WidgetKit.WidgetArchiver.ValidationError.bundleStubNotSupported` and
`Bundle version did not match`. A process sample's bundle version came from the
new on-disk plist, so that version alone could not identify stale running code.

Terminating only that verified Nook extension and registering the installed
extension produced a new process and accepted widget archives. The user
confirmed that the widgets displayed normally. No library, container, system
widget host or LaunchServices database was reset.

The app now reloads timelines once per installed version/build independently of
snapshot equality. The extension checks its **loaded** Mach-O UUID against its
installed architecture slice before producing a placeholder, snapshot or
timeline. It exits only itself if replacement is proven, allowing WidgetKit to
launch current code. Unknown/malformed/unreadable binaries fail open. A signed,
sandboxed probe detected an actual executable replacement (`false` before,
`true` after); process enumeration from that sandbox was unavailable, so the app
does not rely on inspecting or signalling other processes.

This guard must already be present in a running extension to detect its next
replacement. It cannot retrofit code into an extension from an older release;
the already-stuck process in this investigation was recovered separately.

References: Apple's [WidgetCenter](https://developer.apple.com/documentation/widgetkit/widgetcenter)
and [timeline updates](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).

## Background compositing in full-color mode

The update-recovery problem and the dark background are separate. After the
current extension was running, `.ultraThinMaterial` still looked like an opaque
dark plate in Notification Center. A `Color.clear` container produced black;
an isolated SwiftUI material preview did not predict the WidgetKit result.
Home, Reminders and Nook were all logged in `fullColor` with background policy
`Include`, so the comparison did not involve different system appearance modes.

The installed Home extension imports WidgetKit's non-public
`preferredBackgroundStyle` and `WidgetBackgroundStyle.blur`. The macOS 26.5
public Swift interface omits them, and a normal type check rejects the call.
The SDK linker stub exports the symbols. This explains why replacing only the
SwiftUI container's content did not reproduce Home's host background request.

The [independent widget experiment](../../tools/demos/widget-background/README.md)
uses temporary SDK declarations, separate app/extension IDs and preview stories
only. Actual WidgetKit timelines succeeded for all three variants on macOS
26.5.1. The user's comparison over a bright colored background confirmed:

| Variant | Actual appearance in `fullColor` |
| --- | --- |
| Public material | Dark plate |
| Private host blur + clear container | Blurred background color with readable tint |
| Private transparent host + clear container | Much more visible underlying content |

The user selected **host blur (B)**. This is an experimentally verified private
API path, not a supported public WidgetKit feature or a production integration.
The system settings and real library were unchanged. Earlier temporary Nook
bundle replacements were restored to the signed 0.1.76 (80) release; the lab
remains a separate app. Its private declarations are absent from normal builds.

## Measured refresh costs

Measurements used optimized (`-O`) DEBUG app builds on the same Mac, with a
read-only export of the local replica and copied state shards. After applying
user-state deletions, the initial library contained 6,167 articles; a refresh
added 107 visible articles and ended at 6,257 eligible widget candidates.
Original article IDs, titles, RSS content and page URLs were retained. RSS
responses were served locally with deterministic latency. Original pages and
thumbnails used the real cache/transport and production per-feed limits.

The window remained in the background at the user's request. Native synthetic
scroll events exercised the actual Magazine. The first exploratory run did not
enable media while inactive and also exercised first-time legacy migration; it
is **not** the media baseline. The comparable runs use v2 content shards and
explicit background media demand:

| Run | Widget recalculation after feed batches (total elapsed) | Refresh worst main-thread stall | Later media browsing: stalls >= 50ms |
| --- | ---: | ---: | ---: |
| `before-nov24-media` | 3,015ms | 115ms | 3 (worst 134ms) |
| `after-widget-nov24` | 568ms | 109ms | 1 (worst 171ms) |
| `after-cards-nov24` | 468ms | 79ms | 0 |

Widget calculations previously discarded tokenizer/vector caches on every
publication. The publisher now owns one controller, adopts other readers'
profile changes, ignores unrelated preference notifications, and schedules work
at utility priority. The widget-only change reduced calculation time without
eliminating UI stalls. `MagazineCardSurface` then gave unchanged cards an
explicit value boundary, retaining their native text/layout subtree while live
thumbnail, category, reading-time and translation leaves remain observable.

The media browsing phases lasted about 50 seconds. They showed 15, 4 and 12
thumbnails respectively. Translation requests ran, but completions differed
(0, 3 and 0) with provider/cache availability. These are sequential diagnostic
samples, not a controlled translation throughput or foreground FPS benchmark.
Network latency, inference warming and background display throttling remain
confounders. Initial native window/library presentation still showed a roughly
276–384ms stall; these results do not claim every startup or scrolling hitch is
eliminated.

The final `verify-activation-nov24` run exercised `refreshOnActivation` on a
restored copy: nine merge flushes, three list publications, and no main-thread
stalls >= 50ms over the 8.69-second measured window. This is a verification of
the ambient refresh path, not a before/after comparison for cold application
startup. A separate background UI check confirmed card rendering, opening a
story and returning to the Magazine. No foreground input was used.

## Map preparation

A separate same-process comparison used 1,084 actual cached reader originals
(7,987,512 characters). The original `RecommendationLibrarySnapshot` path
reparsed every original on every map refresh, even when only reading state or
one new story changed. `RecommendationSnapshotBuilder` retains parsed text by
library, article ID and exact HTML, capped at 2,048 entries / 32 MiB. It drops
removed originals and rejects cancelled work before replacing its cache.

| Pass | Original full reparse | Cached builder | Cumulative parsed originals |
| --- | ---: | ---: | ---: |
| Cold | 2,226ms | 1,857ms | 1,084 |
| Unchanged | 1,828ms | 2.07ms | 1,084 |
| Unchanged again | 1,836ms | 2.22ms | 1,084 |

This SwiftPM DEBUG comparison measures text preparation, **not** complete map
layout or model inference. Every paragraph and original-source membership set
was compared for equality. No model weights, embeddings, network limits or
ranking candidate membership changed.

Run the optional private-data comparison without checking its input into Git:

```sh
NOOK_PERF_READER_HTML=/absolute/path/to/id-to-reader-html.json \
  swift test --package-path NookKit --filter RecommendationSnapshotTests
```

Regression tests also cover cross-reader profile reloads/reset/library switches,
changed and removed original content, cancelled snapshots, widget build reload
policy, and native/universal/malformed executable identities. Private fixtures,
app logs, samples and frame CSVs remain under ignored `perf-data/`, `perf-runs/`
and temporary paths.
