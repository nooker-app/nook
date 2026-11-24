# AGENTS.md

## Scope

These instructions apply to the entire repository.

## User And Workflow

- The user prefers Korean communication. Reply in Korean unless the user explicitly asks for another language.
- Always write release notes in English.
- The user is a web developer with little macOS native app background. When explaining native concepts, map them briefly to familiar web concepts when useful.
- Unless the user says otherwise, work directly on `main`, commit completed work, and push to `origin/main`.
- Do not create feature branches, pull requests, or extra release flows by default.
- Preserve user changes. Never revert unrelated edits or run destructive git commands unless the user explicitly asks.

## Product Direction

Nook is a native macOS RSS reader. Keep it native.

- Use SwiftUI and macOS APIs, not Electron or a browser-style app shell.
- The app shell, navigation, lists, and default reader are native SwiftUI/AppKit. Do not turn Nook into a webview wrapper.
- One deliberate exception: an opt-in full-article reader mode may use a `WKWebView` (`ArticleWebView`) that loads the article page and injects a self-contained reader script. It is invoked from the reader title button, not the default reading surface.
- Favor standard macOS UI patterns: `NavigationSplitView`, toolbars, menus, settings scenes, share links, context menus, keyboard commands, and AppKit bridges when SwiftUI is unreliable.
- The app should fetch real RSS/Atom data. Do not reintroduce mock feed/article data for production reader behavior.
- RSS data belongs in a user-selected sync folder, preferably in iCloud Drive, similar to an Obsidian vault.
- Persistence is split so multi-device sync is conflict-free: `NookLibrary.json` is the shared **content baseline** (feeds, article content, refresh metadata), while each device's mutable **user state** (read, starred, folders, per-feed overrides, feed deletions) lives in its own shard at `.nook/state/<deviceID>.json`. Each device writes only its own shard, so devices never clobber each other; loads merge every shard over the baseline with a last-writer-wins CRDT stamped by a hybrid logical clock (`HLC`/`LWWRegister`/`DeviceStateDocument.materialize`). Do not go back to writing all user state into a single shared file.
- Treat `NookLibrary.json` and the `.nook/state` shards as user data. Make schema changes carefully and prefer backward-compatible migrations.

## Current App Shape

- `Nook/NookApp.swift`: SwiftUI app entry point, window sizing, commands, and Settings scene.
- `Nook/ContentView.swift`: main native UI, split view, sidebar, article list, reader pane, inspector, toolbar, sheets, import/export UI, and settings view.
- `Nook/ReaderStore.swift`: `@MainActor` observable application state, feed actions, persistence coordination, refresh loops, OPML import handling, and mutations.
- `Nook/ReaderModels.swift`: Codable library models for feeds and articles.
- `Nook/ReaderStorage.swift`: security-scoped bookmark persistence and `NookLibrary.json` load/save.
- `Nook/RSSFeedService.swift`: URL normalization, real `URLSession` fetching, RSS/Atom XML parsing, date parsing, and website feed auto-discovery.
- `Nook/OPMLService.swift`: OPML import/export and `.opml` file document support.
- `Nook/Info.plist`: explicit app metadata, including `CFBundleAllowMixedLocalizations` for native dialog localization.
- `Nook/Nook.entitlements`: App Sandbox, network client access, and user-selected read/write file access.

## Important Implementation Notes

- Folder picking must use `NSOpenPanel` from `ContentView.chooseSyncFolder()`. Present it as a sheet with `beginSheetModal(for:)` when a window is available. Avoid `runModal()` for this panel because it can interfere with text input and Korean/English IME switching inside the panel's New Folder dialog.
- Do not replace the folder picker with SwiftUI `fileImporter` for folders; it previously made the "Choose iCloud Folder" action appear to do nothing on macOS.
- Keep the iCloud folder permission flow based on security-scoped bookmarks in `ReaderStorage`.
- The folder picker should default to `~/Library/Mobile Documents/com~apple~CloudDocs` when that path exists, but users may choose any folder.
- Folder picker dialog strings live in `Localizable.strings`. Keep `CFBundleAllowMixedLocalizations` enabled in `Nook/Info.plist` so AppKit-provided dialog controls can follow the user's preferred language.
- Use `URLSession` for network fetches and `XMLParser` for RSS/Atom/OPML parsing.
- Website URLs may be added as feeds. If direct RSS/Atom parsing fails, discover RSS/Atom links from HTML `<link rel="alternate">` tags.
- OPML import/export should support `.opml` and `.xml` where appropriate.
- Automatic refresh is controlled by `@AppStorage("autoRefreshEnabled")` and `@AppStorage("refreshIntervalMinutes")`.
- Prefer keeping UI state in `ContentView` and app/domain state in `ReaderStore`.
- Keep SwiftUI mutations on the main actor. `ReaderStore` is `@MainActor`.
- Beta's Unread recommendation list ranks the complete filtered unread set, regardless of age. Bound rendered cards and semantic inference, not candidate membership. Deliberate recommendation selections, foreground reading time, and stars teach local interests; bulk read mutations do not. "Not interested" durably excludes that story from recommendations without changing read state and adds a weak, decaying topic penalty; it does not block a feed. Keep this feedback in the per-library local recommendation profile, with undo and restoration. Freeze reader navigation during a visit and rerank on return.
- Beta's Map is a top-level destination beside Magazine. Both share the Unread, Today, Starred, Recent and All collections. Project the cached library graph into the selected collection without changing article positions or rerunning embeddings; read stories remain available in applicable collections, never ranked unread candidates. Build connections from titles, RSS bodies and successful cached reader HTML, independently of categories; never fetch pages for map indexing. Use the AppKit canvas's spatial index and overview buckets rather than a SwiftUI view per article. Keep ranking/graph/model work off the main actor, cancel on selection/library changes, and freeze input behind the reader. Reuse parsed reader originals through `RecommendationSnapshotBuilder`, keyed by library and exact HTML; read/rank changes must not reparse every cached page. Drop removed originals and honor cancellation before installing a snapshot.
- Map formation (unfolding, connection flashes, and relayout) belongs to initial semantic setup. Routine new stories or cached-original changes update links without replaying formation, moving existing nodes, or reframing the camera. Keep refined links through read/rank updates and invalidate them when their content changes. Preserve stored coordinates when excluded stories return.
- macOS widgets consume a bounded `WidgetSnapshot` in the team-prefixed App Group `F7WUT95TT6.com.tim.nook.widgets`; they never read the synced vault, fetch feeds, or load models. The app-lifetime publisher uses the same recommendation profile and excludes blocked articles independently of the current UI filter. Keep the legacy widget kind stable. Use WidgetKit's removable container background and accented groups so macOS owns Clear/Tinted Liquid Glass rendering. The full-color `.ultraThinMaterial` fallback does not provide Home's actual backdrop transparency; neither `Color.clear` nor another nested `glassEffect` removes the host's opaque background. Home uses the non-public `preferredBackgroundStyle(.blur)` host request. Its isolated verification lives in `tools/demos/widget-background`, outside the production targets. A standalone SwiftUI preview or black-backed window capture cannot verify WidgetKit's final desktop/Notification Center compositing; compare over a bright, colored background without changing the user's system appearance. Keep the publisher's recommendation engine alive and reload feedback only when its stored profile changes. Reload timelines once per installed app build even if snapshot content is unchanged. WidgetKit extensions can survive an app update: `NookWidgetRuntime` compares the running Mach-O UUID with the installed executable before producing views and retires only its own stale process. Never reset system WidgetKit databases or terminate system widget hosts. Perf launches must write isolated snapshots and never reload installed widgets.
- Article links use `NookReaderLink`'s opaque library/article tokens and the shared `LayoutSelection` router. Receive URLs in the app delegate and reopen the singleton main window, including when its view is closed; do not rely on SwiftUI scene URL routing for `Window`. Await an in-flight bootstrap, validate the active library, then deliver a reader request to the current Classic/Beta surface. Beta must open its own overlay, not merely set `selectedArticleID`. Snapshot publication is observational; only a user opening a story records reading or recommendation selection.
- The Map's 3D camera projects stable content-community depth onto the same native canvas. Keep the projected hit index consistent with drawing and preserve the camera on read/rank updates. Bound overview markers, edges and labels independently; retain exact article IDs for picking and search even when markers aggregate. Camera depth controls marker size, fading and defocus; reuse the bounded material/focus sprite atlas instead of running filters per story per frame, and pick the front marker where they overlap. Isolated stories use Amber Lens and stories with actual edges use Light Halo, independently of category. `tools/perf/orbit.sh` benchmarks the actual optimized canvas in a native window; offscreen bitmap timings are not presentation timings.
- Map navigation keeps a story visible during deliberate panning and uses fit-relative zoom. Frame selected neighbors without moving the orbit pivot. Keep camera history across read/rank updates; clear it on collection, layout or 2D/3D changes. The minimap samples at most 600 projected points and publishes at most 20 Hz outside drawing; only navigation leaves observe those snapshots. Toolbar, minimap and canvas keys must all respect the reader input lock. Do not clamp/reframe the camera for routine graph changes or passive formation frames.
- Magazine scroll checks use `tools/perf/scripts/magazine.json`, whose probe is inside the Beta scroll content. Keep card observation at a fixed lazy child boundary, share viewport visibility between reveal and preview demand, and keep hover handling singular. Decorative card text can skip hit testing while the native card button and category scroller stay interactive.
- Magazine and Map use the same local hybrid article search: exact keywords plus instruction-prefixed Qwen query embeddings against cached article vectors. Preserve source membership, cancel stale queries, and keep model work off the main actor. Map result keyboard selection follows article IDs across reranking; arrow/Return commands must not intercept IME marked text.
- Recommendation map models are opt-in downloads pinned by revision, size and SHA-256 in `RecommendationMap/Models.json`. MLX inference runs locally on Apple silicon; other Macs retain lexical connections. Store models under local Application Support and vectors/pair scores under per-library Caches, outside the synced vault. Cache identity includes model weights, quantization, prompt and content. Qwen embeddings use left padding and the final document token; generic token-count pooling assumes right padding and corrupts shorter batched inputs. Validate batch invariance when changing this path. Model disclosure reads the same pinned manifest as installation. First-time semantic indexing streams actual completed batches into the existing AppKit map: provisional cosine neighbors connect only analyzed articles, then the complete hybrid graph replaces them. Keep these visual updates separate from graph/search revisions; bound live pulses and respect Reduce Motion. Never simulate analysis progress or invalidate saved models/vectors just to replay the animation. Model disclosure reads the same pinned manifest as installation. First-time semantic indexing streams actual completed batches into the existing AppKit map: provisional cosine neighbors connect only analyzed articles, then the complete hybrid graph replaces them. Keep these visual updates separate from graph/search revisions; bound live pulses and respect Reduce Motion. Never simulate analysis progress or invalidate saved models/vectors just to replay the animation.
- `MagazineMorphingMenu` paints its button and expanded surface in the reader's root overlay. Use `magazineMenuContainer(visible:interactive:animation:)` on a hiding toolbar so descendants inherit its visibility and input state; ordinary `.opacity`/`.allowsHitTesting` on the toolbar cannot reach that overlay. Hiding or disabling the container must also close an active menu and release the reader's input lock.
- `RecentlyReadHistory` stores actual article opens per library on this device (latest 500), independently of read flags and recommendation preferences. Record from the presented reader/browser, not speculative selection or bulk actions. Recent ordering uses last-opened time; resetting recommendation interests preserves it.
- Use AppKit only where it improves macOS correctness or native behavior.
- Reader anchors must survive extraction as paired IDs and fragment links. Update Legibility through `tools/legibility.pin` and regenerate its bundled WASM; do not patch the generated asset manually. `NookPostAnchorRepair` repairs legacy Nook-post bodies that lost all targets from their complete local RSS with networking blocked, preserving the old body on failure. Keep successful caches for other sources and intact Nook posts.
- `ReaderContentStore` serves memory snapshots independently of coordinated iCloud I/O in `ReaderContentFiles`. Never make reader cache hits, misses, or anchor repair await shard downloads/writes. Merge late snapshots with HLC registers; keep pending local extractions authoritative until the serialized writer has witnessed peer clocks and stamped them. Preserve the existing own shard on read errors, retain failed writes for retry, and drain I/O before local reset releases the security scope. Sync updates the cache, never the displayed `readerContentStates` body or its parser/translation; only a deliberate refresh/parser change may replace that body. Recheck cancellation and cache identity after reader warm-up awaits. Cached comments use a read-only SQLite WAL snapshot rather than the replica reconciliation lock; validate the reader generation before publishing them.
- Studio published posts and draft previews consume PDS Markdown directly through `PlusMarkdownRenderer` and `HTMLContentView`, independently of RSS/Legibility. Preserve `[TOC]`, footnotes, and native anchor navigation on this path; a bare `HTMLBlockList` cannot follow document links. Verify the actual Studio entry separately from the RSS reader when changing publication rendering.
- Magazine previews use `ArticlePreviewCache`: device-local, bounded original HTML and downsampled images. Viewport visibility owns automatic requests; page, image, and redirect requests share per-feed and per-host budgets, with persistent server cooldowns. Keep these requests inert (no page scripts or subresources). Cached reader extraction reuses the selected parser with network blocked; a static parse failure must not become a synced failure verdict. Reading-time labels prefer the cached article body over the RSS estimate, update when the cache changes, and must not fetch a page just to calculate its length or write derived estimates into the synced RSS baseline.
- The Beta reader's `MagazineView.opened` state owns its overlay and input lock independently of `ReaderStore.selectedArticleID`. Clearing the store selection (including deletion) must also dismiss that overlay and release its frozen list snapshot.
- Magazine titles and RSS previews share `ListTitleTranslator`'s opt-in, list provider, bounded viewport queue and device-local cache. Both observe completed text only; previews keep their three-line slot stable and never overwrite the original article summary. Give titles and previews separate live identities, including their source text, so edits and language changes cannot reuse stale presentation state. In the card ripple, skip transparent glyphs and draw settled spans as native runs. Profile real media with `tools/perf/scripts/magazine-media.json` and isolated preview caches; do not infer translation smoothness from text-only scrolling or whole-run averages that include idle time.
- Native reader standfirsts join the reader translation document as its first paragraph and are routed back to `ReaderTranslatedSummary`; body indices and Markdown exports exclude that paragraph. Preserve paragraph boundaries during validation. Gemini source normalization, live snapshots, cache reads, and final results must retain every top-level paragraph; coalescing an entire section makes each streamed glyph re-layout previously settled paragraphs. Classic and Beta pass the same optional standfirst and share stop/run ownership.
- Reader translation separates provider snapshots from presentation through `TranslationTextPlayback` and `MarkdownTranslationPlayback`. Coalesce character beats into display frames and adapt to pending text; do not publish every provider chunk or impose a fixed slow character ceiling. Settling paragraph ripples overlap the next paragraph, while the final native HTML handoff waits for all pending ripples. Cancel playback and settlements on article/run changes. Keep translation state in stable per-block observable objects and read their values only inside leaf rows; the document observes row structure, never a mapped snapshot of all block values. Pause ripple rendering using scroll viewport visibility, not appearance callbacks in the eager reader stack. Keep settled text in native runs, splitting only arriving/trailing glyphs for `TextRenderer`; drawing every settled glyph separately causes severe stalls on long paragraphs. The reader effect uses 0.45 seconds and 0.3 strength, independently of the magazine card title effect. On macOS, enabled text selection bypasses `TextRenderer`: disable selection only for the active animated text, and restore it once settled.

## Known Native UI Pitfalls

- The app previously hit a SwiftUI/AppKit constraint crash when toggling the first sidebar. Prefer Apple's native sidebar commands (`SidebarCommands`) and avoid custom split-view hacks unless thoroughly tested.
- macOS may log `com.apple.linkd.autoShortcut` or App Intents registration errors during debug runs. Treat them as OS/App Intents noise unless there is a matching app crash or user-visible failure.
- If a UI action appears inert, verify both the SwiftUI action path and whether the native panel/sheet is being presented from a valid window context.
- Do not leave user-facing app launches with preference overrides such as `-markReadOnOpen NO`. UserDefaults' argument domain outranks saved settings, making settings appear to revert. Use an isolated harness for QA overrides and launch the app normally before handing it back.

## Build And Verification

Use these commands from the repository root:

```sh
make build
```

Equivalent explicit build command:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Additional checks:

```sh
plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements
git diff --check
```

Notes:

- Xcode builds may need to run outside the sandbox in Codex because Xcode and Swift plugin services access system locations.
- `make build` disables code signing for fast local verification.
- MLX needs the Metal compiler component. If Xcode reports a missing Metal Toolchain, install it with `xcodebuild -downloadComponent MetalToolchain`; release CI performs this before archiving. Model weights are downloaded at runtime, never bundled in the app or repository.
- For actual app runs and UI checks, opening `Nook.xcodeproj` in Xcode and using `Command-R` is the simplest path.

## Project Configuration

- Current local toolchain used for verification: Xcode 26.5, Swift 6.3.2.
- Language mode: Swift 6.
- Deployment target: macOS 26.0.
- Apple's newest Xcode may be newer than the local version. Do not churn project settings just because Xcode offers updates unless the user asks or the change is required.

## Git Hygiene

- Before editing, check `git status --short --branch`.
- Stage only files related to the task.
- Before committing, run `git diff --check`; run `make build` or the explicit `xcodebuild` command for Swift changes.
- Commit messages should be concise and conventional, for example `fix: open sync folder picker reliably`.
- Include the Codex co-author trailer when creating commits:

```text
Co-authored-by: Codex <noreply@openai.com>
```
