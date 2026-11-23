# Magazine scrolling and spatial map verification

## Magazine: retain SwiftUI (option A)

Measured on a Mac mini, macOS 26.5.1, a 60 Hz display, optimized application
code (`make perf-build`, `-O`). The actual Magazine screen uses a separate,
deterministic 10,000-story library and a 1440 × 900-point window. Each repetition
starts at the top of Unread / Newest and applies 12 short gesture + momentum
flicks (nine forward, three back). Five warm repetitions follow one excluded
warm-up. Both versions travel 5,988 points net. No screenshots, Instruments,
or builds run during the comparison.

| Median across five repetitions | Before | Option A |
| --- | ---: | ---: |
| Estimated missed display callbacks | 2.26% | 0.15% |
| Excess frame time per active second | 23.71 ms/s | 3.08 ms/s |
| Frame interval, p99 | 33.33 ms | 16.67 ms |
| Worst frame in a repetition | 48.91 ms | 44.01 ms |

These are display-link timing measurements, not GPU presentation timestamps.
They demonstrate a reduction in repeated scrolling hitches, not a guarantee
that every frame meets its deadline. Individual repetitions and the setup are
in [magazine-scroll-results.json](magazine-scroll-results.json).

The default **Unread / Recommended** order was also checked with the same
10,000-story fixture and five repetitions. Its median missed-callback estimate
fell from **5.86% to 2.70%**, excess frame time from **64.90 to 27.26 ms/s**, and
p99 interval from **42.37 to 33.33 ms**. Recommendation ordering retains more
scroll work than Newest; this is not a claim of completely hitch-free scrolling.

A separate Time Profiler run found most main-thread work below SwiftUI's
hosting-view layout / AttributeGraph updates. Hover hit testing was also
substantial: `EventBindingManager.enqueueHoverUpdateIfNeeded` appeared in
2,947 of 25,632 main-thread samples after startup. The profiler increased the
measured missed-callback median to 6.31%; that run is diagnostic, **not** the
before/after baseline.

The changes retain the native lazy grid, typography, card reveal, image reveal,
translation ripple, hover appearance and shared reader transitions:

- Give each grid ID a fixed card view boundary, moving live article observation
  into that realized child. Resolve the featured ID once outside filtering.
- Use one viewport visibility observation for both reveal and preview demand.
- Combine the card's two hover observers into one. Exclude decorative heading,
  excerpt and footer descendants from hit testing; the native card button and
  category scroller remain interactive.
- Hash a reading-time cache's RSS body only for Nook publications, which are the
  sources whose cached originals use that edit fingerprint.

The driver previously targeted the Classic `NSTableView`. Magazine now attaches
its probe **inside its own scroll content**, launches the same driver after
bootstrap, and sends native `NSScrollView.scrollWheel` events with gesture and
momentum phases. It does not drive another scroll view by guessing its width.

```sh
make perf-build
tools/perf/run.sh magazine-check lib-10k tools/perf/scripts/magazine.json none
```

Actual coordinate clicks on the heading opened the reader, and its Back action
returned to an interactive magazine. The snapshot used for this check was
isolated from the user's library.

## Actual articles, previews and translation

The additional M3 scenario uses 165 real English RSS articles from five feeds
(161 unread): Smashing Magazine, Simon Willison, Cloudflare, NASA and CSS-Tricks.
It opens a separate copy of the library and fetches actual pages and thumbnail
images under the existing rate limits. Apple Intelligence on this Mac translates
titles and excerpts into Korean; no fake translator is used. Preview caches are
isolated and initially empty. Each of three passes dwells for 12 / 8 / 8 seconds
between groups of four native gesture/momentum flicks, then waits 10 seconds.

Later passes reuse populated caches, but are **partially warm**, not identical
all-cached replays: arriving images change card heights, other stories enter the
viewport and new translations still complete. Network/model timing and generated
text vary between launches. These real-workload samples complement the repeatable
10k scrolling comparison; they are not a controlled causal comparison by themselves.

Each callback is retained in memory and written to CSV after the measured window.
`media-report.py` correlates it with actual thumbnail reveals, completed title or
summary ripples (650 ms windows), and the three scrolling intervals. Overlapping
windows are merged within each kind, but kinds can overlap with each other.
The rows measure co-occurring work, not the independent cost of one feature.
Looking only at whole-pass averages hides animation stalls behind dwell time.

The first implementation still had expensive translation drawing. A separate
Time Profiler recording of the real workload found `MagazineTitleRipple.draw`
in **4,212 of 14,481 main-thread samples** after startup. Every glyph recorded
blur/shadow drawing operations, including fully transparent glyphs and settled
text. The renderer now skips invisible glyphs and draws settled adjacent glyphs
as native runs; the moving wavefront retains its existing per-glyph effects,
0.55-second duration and 1.5 strength. Headlines also observe completed text only,
so provider token snapshots cannot invalidate a still-original headline.

Results with the retained optimization (estimated missed display callbacks;
p99 and worst are milliseconds):

| Active work | Cold pass: missed / p99 / worst | Revisit 1 | Revisit 2 |
| --- | ---: | ---: | ---: |
| Fresh thumbnails | 1.81% / 37.04 / 56.84 | Only 1 reveal | Only 2 reveals |
| Title ripple | 1.79% / 39.56 / 51.71 | 6.25% / 47.23 / 57.26 | 12.77% / 64.49 / 68.15 |
| Excerpt ripple | 5.63% / 54.62 / 67.26 | 26.23% / 76.56 / 84.87 | 45.50% / 248.31 / 257.78 |
| Fast scrolling | 4.68% / 45.47 / 65.03 | 1.81% / 34.43 / 48.09 | 3.83% / 38.15 / 115.42 |

The cold pass contained **24 fresh thumbnails, 13 title ripples and 14 excerpt
ripples**. The two revisits contained 10 / 5 title ripples and 11 / 5 excerpt
ripples. These are observed completions, not an assumption that enabling a
preference caused media work. The initial pre-optimization cold pass had 24 fresh
thumbnails and 7 / 9 title/excerpt ripples; its excerpt-window missed estimate
was 11.93%, followed by 39.88% and 57.75% on revisits. There are still substantial
tail hitches in real translation, especially on later excerpts. The completed
option-A work improves scrolling and avoids wasted drawing, but **does not
establish consistently smooth live translation**.

Adding `.drawingGroup()` around the temporary translation surface was also
measured and **discarded**: excerpt-window missed estimates were 5.03%, 29.44%
and 52.92%, with a 403.87 ms worst interval on the last pass. It did not solve
the repeated rendering stalls, so the final code does not retain that extra
offscreen surface. Full counts and per-window metrics for all three candidates
are in [magazine-real-media-results.json](magazine-real-media-results.json).

```sh
tools/perf/run.sh magazine-media lib-real tools/perf/scripts/magazine-media.json none
python3 tools/perf/media-report.py <archived-log> <launch-directory-with-frame-CSVs>
```

The real library is a local QA snapshot, not a bundled fixture or user-data export.
Use an isolated copy of an actual library as `lib-real` to repeat this check.

## Spatial map

The map remains one AppKit canvas. Native perspective projection adds a third
coordinate derived from stable content communities, independently of category,
read state or recommendation rank. Changing read flags or filtering the library
does not recompute those world positions or embeddings. The camera can orbit,
pan and zoom; the 2D surface remains available through the bottom control.

Projection and its spatial index are cached between camera changes. Overview
markers are grouped in screen space; geometry drawing is bounded to 2,400
representatives plus a small selected neighborhood, 1,600 edges, and 36 regular
labels plus selected/hovered labels. Actual story coordinates remain in the hit
index even when overview markers aggregate them. There are no per-story views,
entities, physics bodies or new model dependencies. Idle views stop their timer.

A standalone optimized native-window harness compiles the **actual**
`RecommendationCanvas.swift` and `RecommendationOrbit.swift`. Only metadata and
controller DTOs are fixtures. It rotates 20,000 points and 19,999 edges in a
1200 × 800-point window for 260 display callbacks, excluding the first 20.
It exercises the real projection, spatial index, LOD, line drawing and canvas,
not graph indexing or embedding throughput.

- 240 measured callbacks: p99 **16.67 ms**, worst **49.98 ms**; **1** over 25 ms.
- 240 canvas draws: median **6.70 ms**, p95 **7.18 ms**.
- Final draw: 1,573 overview representatives, 1,600 edges, no overview labels.

```sh
tools/perf/orbit.sh
swift test --package-path NookKit --filter 'RecommendationOrbitTests|RecommendationMapStabilityTests'
```

The harness opens its own foreground window and exits automatically. Unit tests
also cover perspective, rotation limits, finite 20k projections, camera/position
stability and bounded actual drawing. Their offscreen bitmap draw times use
unoptimized code and software rasterization, so they are not substituted for
native-window timing. A separate actual-app check used 165 real English articles
and verified the drag interaction, initial whole-map framing, 2D/3D switching,
search result selection using Down/Return, opening the selected article, and
returning from the reader to an interactive map. The optimized isolated preview
was left running; the installed app and user's library were not replaced.

### Glass markers and navigation

The 3D canvas uses camera-relative depth for marker size, opacity and Gaussian
defocus. Isolated stories use **Amber Lens** (transparent center, fine warm rim);
stories with actual edges use **Light Halo** (a small luminous center). Categories
and ranks do not select the material. Two materials share twelve cached focus
levels per appearance; camera frames only composite images, far to near. Size
is capped at a 16-point radius. Hit testing picks the visible front marker at
crossings. The 2D renderer remains unchanged.

System Liquid Glass belongs to the navigation controls and minimap. The map
uses custom optical sprites to avoid one retained Glass view/filter per story.
The minimap samples at most 600 projected points, coalesces snapshots to 20 Hz,
and observes them independently from the graph/search/inspector. Fit-relative
zoom, bounded panning, framing selected neighbors and twenty-entry camera
history preserve context. Routine graph updates do not reframe the camera.

The same optimized 20k native-window benchmark after integration measured:

- Canvas draws: **6.44 ms median / 8.34 ms p95**.
- 240 display callbacks: **16.67 ms p99**, worst **39.90 ms**, **2** over 25 ms.
- Initial sprite preparation/draw: **46.10 ms**, separately from warm rotation.
- Final draw: 1,398 representatives and 1,600 edges; no overview labels.

The former soft spheres measured **6.34 ms / 7.08 ms** per draw in an earlier
run, with a **15.20 ms** initial draw. These are local canvas/callback timings,
not GPU presentation timestamps or a whole-app FPS guarantee. The standalone
benchmark does not render SwiftUI's minimap or inspector; appearance preparation
is still a one-time cost. No new model, download or SDK is required.

`RecommendationNavigationTests` exercises extreme wheel input, min/max zoom,
minimap corners, resize, camera restoration, routine read-state updates, input
locking behind the reader, actual-edge material selection and empty/2D state.
The geometry/stability/navigation suites contain twelve tests. Their offscreen
bitmap timings use unoptimized code/software rasterization, not presentation.
