# Nook map material study

A standalone macOS 26 demo for choosing a new map material before changing the
shipping app. It offers **Amber Lens**, **Light Halo**, and the **current dots**
on the same native 3D canvas. Drag, scroll, pinch, select stories, and switch
appearance without changing the library or recommendation state.

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
Nook palette into the output directory. It adds only the demo material hook to
the copy; exact-match guards fail if the production injection points change.
The Swift models here adapt the saved graph to that canvas. Demo source files
are outside every production target. Do not commit the generated app, graph,
or local screenshots. This is a visual prototype, not a completed integration
or a large-library performance certification.
