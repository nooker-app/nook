# Nook map material study

A standalone macOS 26 study of the Glass materials now integrated in Nook. The default **Connected** mode uses **Amber Lens** for isolated
stories and **Light Halo** for stories with one or more graph edges, independently
of category or rank. Both individual materials remain available for comparison on the same native
3D canvas. Drag, scroll, pinch, select stories, and switch
appearance without changing the library or recommendation state.

Navigation follows Apple's [map guidance](https://developer.apple.com/design/human-interface-guidelines/maps)
to retain context when panning and reveal detail as people zoom. The app and demo share:

- A live projected overview, capped at 600 points, with a viewport rectangle;
  click or drag it to move to the nearest overview story, including when clicking
  empty space between clusters. Updates are coalesced to at most 20 Hz.
- Pan boundaries that keep a story in view and stop inertial drift at the edge.
- Zoom limits relative to the fitted map (80–1,200%); a fitted map reads 100%.
- Full-map (`0` or Escape), selected neighborhood (`F`), previous camera position
  (Delete), and reset-orientation controls. Camera history is capped at 20 entries.
- Selection focus that fits nearby connected stories instead of using a fixed
  magnification. Coordinates and connections are unchanged by navigation.

Geometry checks exercised all four overview corners, extreme continuous wheel
events, repeated minimum/maximum zoom, 30 selected-story targets, and restoring
the previous camera on both a 107-story local RSS snapshot and a 20,000-node
fixture. They check visibility and camera state, not presented-frame performance.

The toolbar uses SwiftUI's system Liquid Glass. The graph uses custom cached
optical sprites, not a live system Glass view for every article: transparent
centers, warm lower-edge refraction, and fine highlights. Both new options keep
camera-relative size, fading, defocus, and depth ordering. The enlarged material
sample uses the same drawing at a higher resolution. No per-frame image filters
are introduced.

## Build and open

Run from the repository root on an Apple silicon Mac with Xcode 26 or newer:

```sh
python3 tools/demos/map-materials/build.py \
  --library /path/to/copied-library/NookLibrary.json \
  --graph /path/to/matching/graph-v1-lexical.plist \
  --output /tmp/nook-glass-demo
```

Open `/tmp/nook-glass-demo/Nook Glass Study.app` to compare the materials.

The graph cache normally lives under
`~/Library/Caches/Nook/RecommendationMap/<library-scope>/` (or the sandboxed
app's equivalent Caches folder). Supply a graph belonging to the library you
want to preview. The builder reads these two files and copies only matching
story titles, RSS summaries, source names, URLs, coordinates, and edges into the
local demo bundle. It never writes to the original files, downloads models,
fetches articles, or opens the user's main app. Selecting a story only previews
it; **Open original** opens its URL if the user clicks the link.

The build script copies the production canvas, projection, marker renderer and
Nook palette into the output directory. It adds only an individual-material override to the copy; camera navigation and
adaptive markers are production code. Exact-match guards detect changed hooks.
The Swift models here adapt the saved graph to that canvas. Demo source files
are outside every production target. Do not commit the generated app, graph,
or local screenshots. The demo is for visual comparison; production performance measurements live in
`docs/perf/magazine-and-spatial-map.md`.
