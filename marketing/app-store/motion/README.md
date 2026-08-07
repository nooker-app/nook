# App Store creative assets, as video

The product page header and the search result asset, rendered with
[Remotion](https://remotion.dev) — React and SVG, animated in code, so the output is
deterministic and reviewable in a diff the way the screenshots are.

```sh
npm install
npm run studio         # preview and scrub in a browser
node render.mjs        # render everything to ../output/creative/
node render.mjs header # or one composition
```

Rendered files land in `../output/creative/<locale>/<platform>/`, with the header under
`shared/` because it carries no words but the app's own name.

## The canvases, and the part that survives

Measured from Apple's own templates rather than guessed —
`creative_assets-product_page_header_template-static.psd` and its search counterpart, whose
art safe areas are marked in green:

| Asset | Canvas | Art safe area | Bleed |
| --- | --- | --- | --- |
| Product page header | 3840 x 1646 | 1645 x 659, centred | 1098 left/right, 494 top/bottom |
| Search result | 3840 x 2560 | 2167 x 1029, centred | 836 left/right, 766 top/bottom |

Everything that has to be read sits inside that box. The scene itself runs to the edges,
because the store crops the rest freely for each placement.

## What these assets are, and what they are not

Apple's own examples — Forest Explorer, Airline, The Coast — are flat illustrated scenes of
the world the icon promises, with the app's name set into them. Not screenshots, and not a
marketing slide with a device and feature copy beside it: that is a different asset for a
different job, and building one of those first is how this started.

The header is one scene and one word. The search asset has more room and a different brief
from Apple — state the obvious, because somebody searching is looking for a specific thing,
and show the firsthand experience — so it carries a short line and a scenario with cuts
between scenes, using `@remotion/transitions`.

## The nest

Nook's icon is a nest, and the app is named for the same idea, so the scenes are built from
it. Two corrections are worth knowing, because both were visible only once rendered:

- **Strands cross; they do not run parallel.** Long parallel sweeps read as stripes.
- **Ends ride above the middle, but not all of them.** With the curvature left to chance,
  a third of the strands drooped and the pile read as something dropped. With every strand
  lifted, it read as a woven basket. Two thirds hold the shape — the outer end of each
  higher than its middle — and a third are left to lie as they fall.

## Video specifics

- 30fps. The header is a 6 second loop; every motion in it is periodic over that window,
  because the asset autoplays and repeats and Apple asks for a loop with no visible jump.
- H.264, CRF 18. Muted by default, so nothing depends on sound.
- The one duration this repository cannot confirm is the store's own limit for these
  assets: Apple publishes the static templates but its video templates return 403, and the
  best-practices page gives no numbers. Check App Store Connect before uploading.
