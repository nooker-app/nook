# App Store screenshots

This directory renders localized App Store marketing screenshots from real Nook captures. The output is deterministic: source screenshots and copy live in the repository, and no design application or generated imagery is required.

## Generate

From the repository root:

```sh
make app-store-screenshots
```

Or write to another directory:

```sh
marketing/app-store/render.sh /path/to/output
```

The default output is organized by locale and platform:

```text
output/
  ko/
    iphone-6.9/  # 1290 x 2796 PNG
    ipad-13/     # 2048 x 2732 PNG
    mac/         # 2880 x 1800 PNG
  en/
  ja/
  zh-Hans/
```

Every locale gets the same platforms and the same slides.

PNG files are rendered without an alpha channel, as required by App Store Connect.

## Capture from Simulator

Prepare the desired screen in a booted simulator, then capture its native pixels:

```sh
make app-store-capture LOCALE=ko NAME=01-library
make app-store-capture LOCALE=ko NAME=03-reader
```

Pass `SIMULATOR='iPhone 16 Pro Max'` (or another 6.9-inch iPhone) for the phone set and `SIMULATOR='iPad Pro 13-inch (M5)'` for the tablet set. The script fixes the status bar, validates the App Store-compatible dimensions, and chooses the folder from the capture's own size: a 6.9-inch iPhone lands in `captures/<locale>/iphone-6.9/`, a 13-inch iPad in `captures/<locale>/ipad-13/`.

Capture a locale from a device in that language, not only from Nook's in-app language setting — a new simulator inherits the Mac's language. With the device shut down, set its language and relaunch:

```sh
xcrun simctl shutdown <device>
plutil -replace AppleLanguages -json '["en"]' \
  ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/Preferences/.GlobalPreferences.plist
xcrun simctl boot <device>
```

`simctl erase` first for a true first launch: `simctl uninstall` leaves preferences behind in `cfprefsd`, so the welcome tour does not reappear. The `en` set comes from an erased device whose welcome tour subscribed the English starter bundles — Hacker News, The Verge, Ars Technica, Daring Fireball, Quanta, and NASA — so the lists hold real content and no personal data.

Turn "Translate titles in the list" off (Settings › Experimental) before capturing a locale whose feeds are already in that language, then clear the translation cache. With nothing to translate, every row keeps a "Translating…" badge.

## Update

1. Replace captures in `docs/screenshots/` or `captures/<locale>/`, or change each slide's `source` path in `config.json`.
2. Edit localized titles and subtitles in `config.json`.
3. To add a language, add its identifier to `locales` and add matching copy under every slide's `localized` object.
4. Add, remove, or reorder slides in `config.json`.
5. Run `make app-store-screenshots` again.

`source` is the fallback app capture. When the app UI itself should be localized, add per-language captures with `localizedSources`:

```json
{
  "source": "docs/screenshots/ios-library.png",
  "localizedSources": {
    "ko": "marketing/app-store/captures/ko/ios-library.png",
    "ja": "marketing/app-store/captures/ja/ios-library.png",
    "zh-Hans": "marketing/app-store/captures/zh-Hans/ios-library.png"
  }
}
```

Locales without an entry continue to use `source`, so captures can be localized incrementally.

The optional `crop` values are normalized fractions of the source image and use a top-left origin. For example:

```json
"crop": { "x": 0.35, "y": 0.02, "width": 0.65, "height": 0.65 }
```

Keep each crop inside `0...1`. For undistorted output, its pixel aspect ratio should match the screenshot frame's aspect ratio.

## Capture checklist

- Use real app content and remove personal data, API keys, account identifiers, and notifications.
- Keep the device appearance, color scheme, content, and clock consistent across one set.
- Capture at native resolution. Avoid resizing the source by hand.
- Review headlines and article images for content you do not want associated with the store listing.
- Commit new source captures together with regenerated output so changes stay reviewable.
