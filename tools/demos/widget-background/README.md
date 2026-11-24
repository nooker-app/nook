# Widget background experiment

An isolated macOS WidgetKit app comparing the same production Nook content with
three background paths. The lab app is not included in the Nook release or app
group. B now exercises Nook's optional production host-background bridge.

| Widget | Container content | Host request |
| --- | --- | --- |
| A · Public Material | Nook's `ultraThinMaterial` | Default |
| B · Home Blur | Clear | Private `preferredBackgroundStyle(.blur)` |
| C · Transparent | Clear | Private `preferredBackgroundStyle(.transparent)` |

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
