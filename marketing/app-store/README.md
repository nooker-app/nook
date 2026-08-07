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

## Product page header and search result

Two newer App Store assets, rendered by the same command into
`output/<locale>/<platform>/`:

```text
output/ko/ios/product-page-header.png      3840 x 1646
output/ko/ios/search-result.png            3840 x 2560
output/ko/ipados/product-page-header.png
output/ko/ipados/search-result.png
```

One of each per platform, because App Store Connect treats iOS and iPadOS
separately, and one of each per locale.

### The safe area is the whole design constraint

Both canvases are far larger than the part that is guaranteed to be shown. The
numbers are measured from Apple's own templates rather than guessed —
`creative_assets-product_page_header_template-static.psd` and its search
counterpart, whose art safe areas are marked in green:

| Asset | Canvas | Art safe area | Bleed |
| --- | --- | --- | --- |
| Product page header | 3840 x 1646 | 1645 x 659, centred | 1098 left/right, 494 top/bottom |
| Search result | 3840 x 2560 | 2167 x 1029, centred | 836 left/right, 766 top/bottom |

Everything that has to be read — the mark, the line, the screenshot panel — is
laid out inside that box, in its own coordinate space, and the background bleeds
to the full canvas. The store crops the rest freely for whichever placement it is
drawing.

### What the design is doing

Apple's asset best practices ask for a single clear idea, an asset built for
someone who has never seen the app, and short text that enhances the picture
rather than describing it. So each asset is one line, one sub-line, and one
magnified piece of the real app.

Magnified deliberately: a header is drawn small at the top of a product page, and
a whole device screen at that size is a grey rectangle with specks in it. The
panel shows a slice of the app large enough to read — for iPhone the reading
view, for iPad the list and the article side by side, which is what the iPad
version is for.

The search asset follows the other half of that guidance: state the obvious,
because somebody searching is looking for a specific thing, and show the
firsthand experience. It names the category outright and puts two real screens
under it.

Also observed: no prices, URLs, awards or other platforms; nothing that needs a
rating above 4+; the copy is localized for every language the app ships in.

### Crops are per locale on purpose

The captures are of different articles scrolled to different places — Korean and
Japanese open on an article's title, English sits mid-paragraph, Chinese near an
illustration — so `localizedCrops` picks a starting point per language. A shared
crop opens one language cleanly and cuts a sentence in half in the others. The
iPad crops start just under the toolbar instead, which is the one boundary every
locale's capture shares.

### The translation asset, when there is a capture for it

The strongest thing to show is arguably the one no current capture holds: a
foreign-language article becoming readable — the list translating a title in
place, or the reader streaming a translation in. Nothing here fabricates UI, so
that asset is not rendered yet.

What it needs is one capture per locale of a *foreign* feed being read: an English
article in a Korean-language device with list-title translation on, and the reader
part-way through a translation. The existing sets cannot show it because each
locale was captured from feeds in its own language — the Korean set from Korean
bundles, the Japanese set from `gihyo.jp`.

```sh
# Subscribe to a feed in another language first, turn on list-title translation,
# then capture the list and the reader mid-translation.
make app-store-capture LOCALE=ko NAME=06-translate-list
make app-store-capture LOCALE=ko NAME=07-translate-reader
```

Then add an asset to `creative.assets` in `config.json` pointing at them. Suggested
copy, in the same shape as the rest:

| Locale | Title | Subtitle |
| --- | --- | --- |
| ko | 영어로 쓰인 글도, 한국어로 | 목록에서 제목부터, 본문은 읽는 동안 번역됩니다. |
| en | Read it in your language | Titles in the list, the article as you read it. |
| ja | 英語の記事も、日本語で | 一覧では見出しから、本文は読みながら翻訳。 |
| zh-Hans | 英文文章，也能用中文读 | 列表先译标题，正文边读边译。 |

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

## Capture the Mac app

The Mac app has no simulator, so its captures come from the installed app driven
through accessibility. Two tools split the work because each is only reliable at
one half of it:

- `agent-device` reads this app's accessibility tree accurately and clicks a ref
  taken from the snapshot immediately before the click. Never click by label —
  a label that fails to match can land on a neighbouring window button, and
  "minimize" is one of them.
- Its text entry sends keystrokes, which land on the window when a sheet's field
  is not focused and minimize it. Set the field's value through AppleScript
  instead: `set value of text field 1 of group 1 of sheet 1 of window 1`.

AppleScript needs Accessibility, and that permission belongs to the *process*
that asks. A shell inherits the terminal's, which is usually denied, so wrap the
script in its own applet and grant that once:

```sh
osacompile -o NookAXRunner.app runner.applescript   # runner does: run script <file>
open NookAXRunner.app                                # prompts as "NookAXRunner"
```

The app reads its language and storage from launch arguments, not preferences —
it rewrites its own defaults as it quits, so anything set beforehand is lost:

```sh
open -a /Applications/Nook.app --args -AppleLanguages '(ja)' -appLanguage ja \
  -usesLocalLibrary 1 -translateListTitles 0 -translateTitlesPromoSeen 1
```

`-appLanguage` matters as much as `-AppleLanguages`: dates format from the stored
preference, so without it an English UI still prints Korean dates. Pass
`-translateTitlesPromoSeen 1` or the translation promo covers the window and every
click misses. Each language is one uninterrupted run: the override lives only in
that process, and a second script attaching later may find a different instance.

Capture the window, never the screen:

```sh
screencapture -x -o -l "$(xcrun swift check-window.swift Nook)" out.png
```

`-l` takes a CGWindowID and works on a background window, so nothing has to come
forward — and nothing else on the desktop can end up in a public asset.

Known gap: the reader frame needs the sidebar and inspector hidden, and those
toggles are titled in English only, so a non-English run captures the overview
twice. The Mac set is therefore two frames per language. Japanese has no Mac
captures yet and falls back to `source`.

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
