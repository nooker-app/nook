# Widget background experiment

An isolated macOS WidgetKit app comparing the same production Nook content with
background paths and a separate stacked-story experiment. The lab app is not included in the Nook release or app
group. B now exercises Nook's optional production host-background bridge.

| Widget | Container content | Host request |
| --- | --- | --- |
| A · Public Material | Nook's `ultraThinMaterial` | Default |
| B · Home Blur | Clear | Private `preferredBackgroundStyle(.blur)` |
| C · Transparent | Clear | Private `preferredBackgroundStyle(.transparent)` |
| D · Stacked Glass | Clear, with individual material story capsules | Private transparent background requests |

The installed Home extension imports `preferredBackgroundStyle` and the `blur`
enum case. The public macOS 26.5 WidgetKit Swift interface does not expose them;
an ordinary compile fails with “no member preferredBackgroundStyle”. The SDK's
linker stub does export the symbols. The build script uses
`tools/prepare-widget-host-sdk.py` to copy the required SDK declarations to a
temporary directory and add weak-linked declarations to that copy only. The
app links Apple's installed WidgetKit; no Apple framework or modified SDK is
embedded or checked into the repository. This unsupported ABI can change with
macOS updates. The production bridge checks its required symbols before use;
the standalone C variant is an experiment without that compatibility wrapper.

Build from the repository root with a local signing identity:

```sh
python3 tools/demos/widget-background/build.py --identity 'Developer ID Application: YOUR NAME (TEAMID)'
```

The default output is `/tmp/nook-glass-widget-demo/Nook Glass Lab.app`.
The generated app and extension have separate IDs (`com.tim.nook.glasslab` and
`.widgets`), sandbox entitlements only, no app group, no network entitlement,
and a timeline provider that serves only Nook's preview stories. The copied
content's URLs use `nookglasslab` so they cannot select real Nook stories.

Register and launch this app in the background, then add its widgets from
Notification Center's widget gallery. Compare A and B at the same size with
the existing system appearance unchanged; C is an additional diagnostic.
The footer identifies the variant and actual rendering mode.

## Verification boundary

A successful build, extension registration, or standalone SwiftUI screenshot
does not prove translucency. Verify the widgets inside Notification Center
over a bright or colored window, preferably moving that window to establish
whether its content really passes through. Do not interpret a black-backed
capture of Notification Center's isolated window as a desktop composite.

Remove the lab widgets after the experiment. The original Nook application,
library, and installed widget kinds remain independent.

## Observed result

On macOS 26.5.1, WidgetKit accepted the three extension timelines and rendered
all three in `fullColor`, without changing the system appearance. The user's
comparison over a bright blue and green background showed A retaining a dark
plate, B transmitting the background with blur and a readable tint, and C
transmitting substantially more of the background. Home was visible alongside
the variants. The selected appearance is **B · Home Blur**.

This confirms the mechanism in the actual host on this OS, not compatibility
with all future macOS versions. The selected B style is implemented for Nook's
macOS widgets through `NookWidgetHostBackground.swift`. The lab remains a
separate app with sample data.

## Stacked story experiment

Add **D · Stacked Glass** from the same widget gallery: small contains one
story, medium two, and large four. Each story is a separate rounded capsule;
the rows overlap by 5 points and narrow slightly toward the back of the stack.
Links use only `nookglasslab://story/...`, never real reader links. The demo
does not change the production widgets or system appearance.

The lab app contains a native motion preview with size selection, two colored
backdrops, **First display** and **Replace one story** buttons. `StackedContent.swift` shares layout and motion
between the app and the widget. Its material toggle deliberately distinguishes
the widget-compatible surface from native `glassEffect`; a successful native
preview is not evidence of WidgetKit's desktop compositing.
The native window was visually checked at all three sizes, including the
intermediate and settled states of a replay in the same running process.
The signed standalone build and `make build` both pass.

On macOS 26.5.1, applying `glassEffect` to the whole capsule produced a blank
widget, despite successful timeline archives and accessible story buttons.
The widget now keeps text outside the effect and uses `ultraThinMaterial` plus
a restrained gradient and stroke for each capsule. The user's colored-desktop
capture confirmed the capsules display. It also confirmed a surrounding system
Glass plate and outline remain: this is **not yet a borderless widget**.
The `isTransparent(true)` experiment did not remove that plate. D also probes
the older private `backgroundStyle(.transparent)` request; do not assume this
eliminates host chrome without checking the real host. These extra declarations
exist only in the demo's generated SDK copy, not the production build overlay.

First display and data updates have separate animation ownership. Only first
display unfolds all rows (0.48 seconds, with a 0.065-second stagger). Story
updates never change the expanded state: each retained article keeps its ID,
absolute slot, size and position. Only a replaced article fades out while its
replacement rises from the bottom of the stack over 0.55 seconds. An absolute
ZStack prevents outgoing and incoming views from reflowing the other rows.
Each slot is a stable parent with a fixed z-index (top to bottom: 4, 3, 2, 1
for large widgets). Article identity and replacement transitions live inside
that parent. Never assign an arriving article a shared negative z-index:
it otherwise stays behind the wrong neighbors after arrival and jumps in front
when the next replacement changes the arriving ID. No delayed z-index reset or
animation-completion callback is needed, including for overlapping updates.
Two noninteractive reserve surfaces peek out behind the bottom story before an
update. The layout reserves 16 points for this tail within the actual widget
bounds. A replacement starts at the front reserve card's origin, slightly
scaled down, and slides into its fixed slot; it no longer materializes from
outside the widget. Reserve surfaces share the story material and are excluded
from accessibility and hit testing. They do not trigger full-stack unfolding.
Native captures of a single replacement kept all three capsule-overlap bands
and the reserve deck pixel-identical before and after settlement. As a negative
control, reintroducing a second-slot z-index of -1 in an offscreen copy changed
1,957 of 2,170 pixels in the second/third overlap band; repeated correct renders
changed none. This checks layer order, not WidgetKit backdrop compositing.
The reserve tail was also checked at small, medium and large sizes.
Reduce Motion disables both transitions. **First display** explicitly resets
the native preview for inspection; **Replace one story** cycles through the
visible slots without resetting the stack.

The widget's finite sample timeline expands after three seconds, replaces one
story at 12 seconds, then one at 21 seconds. Its start date is persisted in the
demo extension's sandbox by widget family. Later provider calls, process
restarts and snapshots reuse the same sequence/current stories instead of
restarting the folded stack. StaticConfiguration shares timelines by kind and
family; this is not an independent first-show flag for every widget instance.
The app's widget-refresh button requests only D's timeline reload and never
resets this history. WidgetKit decides when to honor it; no timer loop, network
request, or continuous redraw is used. Notification Center opening does not
guarantee replay, and the native preview is not proof of actual widget animation.
Apple documents a maximum two-second duration for widget update animations:
https://developer.apple.com/documentation/widgetkit/animating-data-updates-in-widgets-and-live-activities

Verify the final host result over a colored background, including the space
between capsules, and capture an actual timeline transition before considering
production integration. A frameless desktop overlay app would be a different
product from a system-managed WidgetKit widget; the lab does not install one.
