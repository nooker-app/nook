<h1 align="center">
  <img src="docs/icon.png" width="120" alt="Nook" /><br/>
  Nook
</h1>

<p align="center">A small, native RSS reader for macOS and iOS — offline-first, free, and stored in a plain folder on whatever cloud you already use.</p>

<p align="center">
  <a href="https://github.com/nooker-app/nook/releases/latest">
    <img src="https://img.shields.io/badge/Download-macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/nooker-app/nook/releases/latest"><img src="https://img.shields.io/github/v/release/nooker-app/nook?label=latest&color=4c71f2" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26+" />
  <img src="https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white" alt="iOS 18+" />
  <img src="https://img.shields.io/badge/built%20with-SwiftUI-fa7343?logo=swift&logoColor=white" alt="Built with SwiftUI" />
  <a href="https://github.com/nooker-app/nook/stargazers"><img src="https://img.shields.io/github/stars/nooker-app/nook?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4c71f2" alt="MIT License" /></a>
</p>

<div align="center">
  <table>
    <tr>
      <td valign="middle"><img src="docs/screenshots/main.png" width="660" alt="Nook on macOS — sidebar, article list, and reader"></td>
      <td valign="middle"><img src="docs/screenshots/ios-splash.png" width="180" alt="Nook launch screen on iPhone"></td>
    </tr>
  </table>
</div>

> **New to RSS?** RSS lets you follow sites, blogs, and newsletters in one place — no algorithm, no ads, and nothing deciding what you should read. [Why use RSS feeds →](https://openrss.org/guides/what-are-rss-feeds#why-use-rss-feeds)

## Why Nook

I have read RSS every day for more than ten years. In that time I paid for readers, tried most of the free ones, and kept meeting the same small frictions. The feature I wanted was behind a subscription. The app that had it was missing something else. There were bugs. Sometimes there were ads, in an app I had opened specifically to get away from ads.

None of that is a catastrophe. They are papercuts. But you feel papercuts every day for ten years, and eventually you want to fix them yourself.

What I wanted was for reading to be more than reading. I wanted to find the piece I half-remembered without going hunting for it. I wanted a foreign-language post to be legible without leaving the app. And I wanted the collection to be mine — a place I built, not a feed handed to me.

A bird builds its nest one twig at a time, and the result is entirely its own. That is the idea: gather the writing you care about into a space that fits you, keep it somewhere you control, and stop having to think about it.

So Nook tries to do three things. Make good writing easy to read. Make it easy to find again later, without having to be organized about it up front. And leave every piece of it under your control.

There is no Nook account and no Nook sync server. Pick a folder in iCloud Drive, Dropbox, Google Drive, OneDrive, Syncthing, or any other folder-sync service. That service carries Nook's files between devices; Nook then merges the per-device files with CRDTs so concurrent reads, stars, categories, and feed changes do not overwrite each other.

## What AI is for here

I did not add AI to Nook to borrow someone else's moment. It earns its place or it does not ship.

In practice that is four things: translating an article without wrecking the shape of the original, summarizing one when you only need the gist, sorting what arrives into your own categories, and condensing a batch of new items into one notification instead of a wall of them. Small jobs that save you effort. It does not write for you, rank your reading, or decide what deserves your attention.

If you want none of it, you can have none of it. Full-article translation runs only when you press Translate. Summaries, automatic list-title translation, and AI categorization are each off until you turn them on — and summaries stay manual after that unless you also ask for them automatically. Keyword rules, manual categories, and search all work with every AI feature disabled.

A few things run without a switch of their own — the new-article notification digest, for one — and only where I judged the behavior to disappear into ordinary use. Those always use Apple Intelligence on-device, and they degrade quietly instead of failing: if the model is unavailable or slow, you get a plain list of titles.

Keeping this on your device instead of on my server is a tradeoff, and it is worth stating plainly rather than hiding it. On-device models are smaller than hosted ones, so some results are weaker. A long translation is real work, and your machine can get warm doing it. Apple Intelligence needs recent hardware to run at all. I took that deal anyway, because privacy and data ownership matter more to me here than the last increment of quality. Gemini is the escape hatch if you would rather use a hosted model: you select it yourself and supply your own API key, and only then does article text leave for Google. Someday there may be a Nook server to hand this work off to. There is none today, and none is required.

## What's here today

- **Native Mac, iPhone, and iPad apps.** SwiftUI and AppKit surfaces, native navigation, menus, gestures, widgets, sharing, and accessibility.
- **A folder is the sync service.** Your library remains portable, inspectable JSON in storage you choose, with OPML import and export for subscriptions.
- **A real native reader.** Images, links, code, quotes, nested lists, and tables render without making the default reader a web view. Full-page and original-site modes remain available.
- **Two article parsers, switchable mid-article.** [legibility](https://github.com/nooker-app/legibility) is the default: it reads short posts and link posts that Readability rejects, and never invents a title or a date. Mozilla's Readability is one tap away for the pages it reads better — the ones with a video in them — and the reader tells you when an embed was left out rather than showing you a blank space.
- **Typography you can set, or measure.** Choose font, size, line height, and letter spacing, with a live specimen so you can see the change before you commit to it. On iOS, Reading Fit times how fast you actually read short standardized passages and recommends a size and spacing from that, rather than asking you to guess.
- **Translation that keeps its shape.** Use Apple Intelligence on-device or opt into Gemini. Gemini translates the native reader as coherent Markdown, preserving the context of headings, lists, tables, links, and code while it streams.
- **Summaries when you want the gist.** Opt in, then summarize an article on demand in the native reader — concise, detailed, or expert — with Apple Intelligence on-device by default. Automatic summarizing is a second, separate switch.
- **Markdown in and out.** Copy the article body as Markdown or save it as a `.md` file. When a Gemini-translated Markdown article is visible, that translated version is exported.
- **Rules you control.** Create categories, keyword filters, hidden sources, and optional AI classification. Automatic list-title translation and new-article notifications are opt-in.
- **Offline-first reading.** Feed content is local, selected full articles can be downloaded, and automatic expiry is configurable.
- **Quiet cross-device alerts.** Seen state suppresses duplicate alerts. A Mac left open but hidden, minimized, locked, asleep, or idle yields notification ownership to iOS.

See [all features and their defaults](docs/features.md), including which options are opt-in, opt-out, device-local, or network-backed.

## Where this is going

**None of this is implemented yet.** It is the direction, not a feature list — if you are deciding whether to install Nook today, decide on the section above.

Reading and writing are the same habit split across too many apps. You read something, the thought it gave you goes into a notes app, and the post it turns into goes somewhere else again. I want reading, marking up, keeping a note, finding it later, and publishing to be one continuous motion in one app.

The part I want most: writing that starts on your own disk. No deciding where to publish before you have written anything. Write the file, and if you decide it should be public, Nook publishes it. If you change your mind, you unpublish it. The file was always yours and stays yours either way.

I plan to build this on [ATProto](https://atproto.com), so what you publish lives in a protocol anyone can read and move rather than in my database. Its spec does require an account for publishing — so publishing will be opt-in, and reading Nook will never require signing in to anything.

Concretely: highlights, notes, and publishing do not exist yet. Subscribing, the native reader, and article search work today.

## Is Nook the right reader for you?

Nook is strongest when you want a native Apple-platform reader, no service account, control of the sync folder, and optional translation without making AI mandatory. A hosted reader may fit better if you need a web or Android client, server-side feed collection while all your devices are offline, team features, or a large annotation and knowledge-management system.

See the neutral [RSS reader comparison](docs/reader-comparison.md) for Nook, NetNewsWire, Reeder, Feedly, and Readwise Reader, with official sources and tradeoffs rather than a checklist score.

Whether to use a server, who owns what you write, whether AI is involved at all — those are your calls, not mine. Nook's job is to keep them yours.

## Install

### macOS (Homebrew)

```sh
brew install --cask nooker-app/tap/nook
```

Nook is ad-hoc signed rather than notarized. On first launch, right-click **Nook** in Applications and choose **Open**, or install without quarantine:

```sh
HOMEBREW_CASK_OPTS="--no-quarantine" brew install --cask nooker-app/tap/nook
```

### macOS (DMG)

1. Download the latest [Nook DMG](https://github.com/nooker-app/nook/releases/latest).
2. Drag **Nook** into **Applications**.
3. Right-click `Nook.app` and choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/Nook.app` once.
4. Choose the folder where Nook should keep and sync your library.

Requires **macOS 26 (Tahoe)** or later. The universal build supports Apple Silicon and Intel. Apple Intelligence translation requires a supported Apple Silicon Mac; Gemini is optional and requires your own API key and a network connection.

### iOS / iPadOS

There is no App Store build yet. To install it on your own device:

1. Open `Nook.xcodeproj` and select the **NookiOS** scheme and your device.
2. Choose your team under **Signing & Capabilities**, then press **⌘R**.
3. Through the Files picker, select the same synced folder used by your Mac.

Requires **iOS/iPadOS 18** or later. Apple Intelligence translation requires a supported device running **iOS 26**.

## Learn more

- [Features, controls, and platform details](docs/features.md)
- [Comparison with other RSS readers](docs/reader-comparison.md)
- [Data ownership, cloud sync, and conflict handling](docs/data-and-sync.md)
- [Building, architecture, and releasing](docs/development.md)
- [Homebrew tap setup](docs/homebrew-tap.md)
- [Submitting to the App Store](docs/app-store-submission.md)

## Build from source

```sh
git clone https://github.com/nooker-app/nook
cd nook
make build
```

See [development notes](docs/development.md) for the iOS build command, architecture, toolchain, and release process.

## License

[MIT](LICENSE) © 2026 Tim.
