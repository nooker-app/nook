# Development

## Build from source

Current toolchain:

- Xcode 26.5 or newer
- Swift 6
- macOS 26 deployment target
- iOS 18 deployment target

Build the macOS app without code signing:

```sh
make build
```

Equivalent command:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Build for the iOS simulator:

```sh
xcodebuild -project Nook.xcodeproj -scheme NookiOS \
  -destination 'generic/platform=iOS Simulator' build
```

For a physical iPhone or iPad, open `Nook.xcodeproj`, select the NookiOS scheme, choose a signing team and device, then press **⌘R**.

## Architecture

- **Shared core:** `NookKit`, a local Swift package containing the store, models, RSS/Atom and OPML parsing, storage, sync, translation, and native reader components.
- **macOS UI:** SwiftUI with AppKit bridges where native behavior is more reliable.
- **iOS/iPadOS UI:** SwiftUI, WidgetKit, and a share extension.
- **Networking:** `URLSession`.
- **Feed parsing:** `XMLParser`.
- **Native reader:** semantic SwiftUI rendering for parsed HTML and Markdown.
- **Article parsers:** two, chosen in Settings and switchable per article from inside the reader. [legibility](https://github.com/nooker-app/legibility) is the default — a Rust extractor compiled to WebAssembly and shipped as one self-contained page, `NookKit/Sources/NookKit/Legibility.html`. Mozilla's Readability.js is the alternative, and keeps the video and CodePen embeds legibility's sanitizer drops.
- **Full-page reader:** a deliberate opt-in `WKWebView` that renders whichever parser is chosen, styled by the reader's own typography settings.
- **Translation:** Foundation Models and NaturalLanguage on-device; optional Gemini through a direct network client.
- **Persistence:** per-device JSON CRDT shards in the chosen folder plus a disposable local SQLite replica/outbox.
- **Coordinated file access:** `NSFileCoordinator` and `NSFilePresenter`.
- **macOS updates:** Sparkle with an EdDSA-signed appcast.

There are no third-party UI frameworks and no Electron shell.

## The legibility engine

`NookKit/Sources/NookKit/Legibility.html` is generated and checked in: it is the
legibility engine compiled to WebAssembly and inlined as base64, ~900 KB in one
file. Checked in on purpose — building it needs a Rust toolchain and the
`wasm32-unknown-unknown` target, and `make build` has to work for someone who has
neither.

```sh
make legibility-check   # the asset was built from the commit the pin names
make legibility         # regenerate it (needs Rust; only when moving the pin)
```

The pin is `tools/legibility.pin`, which records the commit **and** the digest of
the module built from it. To move it: edit the commit, run `make legibility`, and
update the `wasm=` line to the digest the script reports.

## Verification

```sh
make build
xcodebuild -project Nook.xcodeproj -scheme NookiOS \
  -destination 'generic/platform=iOS Simulator' build
swift test --package-path NookKit
make legibility-check
plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements
git diff --check
```

The tests live only in the Swift package — `Nook.xcscheme` has no testables, so
`xcodebuild test` runs nothing. `swift test` is the way, and it runs the WebKit
tests (the extraction scripts and the legibility engine) headlessly.

## Releasing

Pushing a version tag runs `.github/workflows/release.yml`:

```sh
git tag v0.1.8
git push origin v0.1.8
```

The macOS runner archives a universal ad-hoc build, packages a DMG, publishes a GitHub Release, signs the update, and updates the Sparkle appcast on the `gh-pages` branch.
