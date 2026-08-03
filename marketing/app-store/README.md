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

`simctl erase` first for a true first launch: `simctl uninstall` leaves preferences behind in `cfprefsd`, so the welcome tour does not reappear.

Every set starts from an erased device, so the lists hold real feed content and no personal data. Where the articles come from depends on the language, because the welcome tour offers Korean-first starter bundles only to Korean-language users and the English set to everyone else:

- `ko` — the tour's "IT·개발" and "기술 블로그" bundles (GeekNews, 우아한형제들 기술블로그, tech.kakao.com).
- `en` — the tour's three English bundles (Hacker News, The Verge, Ars Technica, Daring Fireball, Quanta, NASA).
- `ja`, `zh-Hans` — no bundle. Use "Or follow a site by its address" on the tour's last page to subscribe sites that publish in that language, otherwise a Japanese or Chinese listing shows English headlines. The current sets use gihyo.jp, Publickey, and the Hatena developer blog; and 少数派, 爱范儿, and 奇客 Solidot.

Turn "Translate titles in the list" off (Settings › Experimental) before capturing a locale whose feeds are already in that language, then clear the translation cache. With nothing to translate, every row keeps a "Translating…" badge.

## Check before publishing

```sh
make app-store-check-faces
```

Store screenshots show live feeds, and a live feed eventually serves a portrait — an author photo, a conference stage, a product page with someone in it. Screenshots must not show a person, so this scans every file under `captures/` and `output/` with Vision's face detector and fails with the offending paths. Recapture those scenes on a different article rather than cropping around the face.

Also read the visible headlines. A capture is only as good as whatever the feed published that hour, and a list is easy to reframe: scroll a row or two, or select a single feed, until nothing on screen is something the listing should not carry.

## Update

1. Recapture into `captures/<locale>/<device>/<slide id>.png`, or change the slide's paths in `config.json`.
2. Edit localized titles and subtitles in `config.json`.
3. To add a language, add its identifier to `locales`, add matching copy under every slide's `localized` object, and capture it on a device in that language.
4. Add, remove, or reorder slides in `config.json`.
5. Run `make app-store-screenshots`, then `make app-store-check-faces`.

Both iOS platforms carry the same five scenes, and every one of them is captured per language, so a slide names all four:

```json
{
  "id": "01-library",
  "source": "marketing/app-store/captures/ko/iphone-6.9/01-library.png",
  "localizedSources": {
    "ko": "marketing/app-store/captures/ko/iphone-6.9/01-library.png",
    "en": "marketing/app-store/captures/en/iphone-6.9/01-library.png",
    "ja": "marketing/app-store/captures/ja/iphone-6.9/01-library.png",
    "zh-Hans": "marketing/app-store/captures/zh-Hans/iphone-6.9/01-library.png"
  }
}
```

`source` is the fallback for a locale with no `localizedSources` entry, which lets a new language render before its captures exist — but a listing should not ship that way, since the screenshots would be in the wrong language.

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
