# Reply to Guideline 2.1 — Information Needed

The answer to the seven questions App Review asked on the first submission, written
to be pasted into the reply box in App Store Connect. English, because that is the
language review correspondence is read in.

## Why a complete submission still got this

Six of the seven items have no field in App Store Connect. There is a Notes box, a
demo-account box, and nothing else — no slot for a screen recording, a device list,
or a services list. Filling in every field on the form and answering these seven
questions are two different things, and only the second one closes a 2.1.

So this is not a rejection. Nothing in the app was found wanting; the review has not
started yet. Answer all seven in one reply and it starts.

## Before pasting: two things to settle

**1. The recording is the whole reply.** Items 2–7 are text and are written below.
Item 1 is a video, it is the reason the other six were asked, and a reply without it
will come back. Record it first — the script is at the end of this file.

**2. Account deletion — it now exists, and the recording must show it.**
`PlusOnboarding.swift` creates an account inside the app, from an invitation code, an
email address, and a password, and guideline 5.1.1(v) requires an app that creates
accounts to delete them too. App Review asked for that flow by name in item 1.

It was not there when 0.1.0 was submitted. Settings › Nook Plus › **Delete Account**
now runs the real thing: the reader confirms with their password, the server that
stores their writing verifies it, and the account is destroyed — the identifier, the
handle, every publication, every article, every image.

**Leave Nook Plus** is still there, above it, and is a different act: it ends the
membership and takes down the pages Nook generated while keeping everything the writer
wrote. Both are in the recording, and the reply says which is which. Do not describe
Leave as an account deletion — a reviewer who taps it and finds the handle still
resolving reads that as a false statement, which is a much worse position than not
having the feature.

## Fill these in before sending

- `[DEVICES]` in item 2 — the physical iPhones and iPads the build was actually run
  on, with their iOS versions. Simulators do not count and must not be listed.
- `[HANDLE]` / `[APP PASSWORD]` in item 4 — the review account. Also put them in the
  Demo Account fields; the reply is not a substitute for those.
- Nothing in item 1 — account deletion has shipped, and the text below already
  describes what is there.

## Where this goes, and the 4000-character wall

App Store Connect › the app › the unresolved-issues link at the top › **Resolve**
next to the submission › **Reply to App Review**. That dialog is the only place a
reply can be sent, and the only place the recording can be delivered: there is no
upload slot for a video anywhere else in App Store Connect. Attach it there with
**Attach File**, beside the text. Replies stay possible until the build is
resubmitted, and the reply needs Account Holder, Admin or App Manager.

**The Reply field takes 4000 characters.** The seven answers below the fold run to
about 12,000, so they cannot be sent as they are. Two ways to handle that, and the
first is the recommended one:

1. **Send the condensed reply immediately below**, which is 3,934 characters with
   every one of the seven items answered, and attach the recording to it.
2. Send the long answers as several consecutive replies. Nothing is lost, but a
   reviewer reading a four-part letter is a reviewer being asked to do work.

Either way, the long version stays here as the source, and the durable parts of it
— items 3, 5, 6, and 7 — belong in App Review Information › Notes for every future
submission, where they are read before anyone has to ask.

## The reply to send (3,934 characters)

Paste verbatim, replacing `[DEVICES]`. Attach the recording in the same dialog.

```text
Thank you. The recording is attached; the seven answers follow.

1. SCREEN RECORDING. Attached. Made on a physical iPhone on the current released iOS, from the Home Screen and a cold launch: the tutorial, the screen offering notifications and background refresh, adding a feed by pasting a website address, reading, translating, organising, and the settings behind it. None of that needed an account.

Nook Plus, the optional publishing feature, does have one, and the recording covers registration (invitation-only, so a code is used rather than a public form), sign-in, publishing, and account deletion in full. Deletion is at Settings > Nook Plus > Delete Account: the reader confirms with their password, the server holding their writing verifies it, and the account, its handle, and every publication, article and image go. "Leave Nook Plus" above it is a milder, different act: it ends the membership and takes our pages down, keeping the account and all its contents.

Absent because they do not exist: in-app purchases (the app links no purchase API), user-to-user content, and any request for location, contacts, camera, photos or tracking. The only permission requested is notifications, shown being asked only after a setting that needs it is switched on. All such settings ship off.

2. TESTED ON. [DEVICES]

3. WHAT IT IS. An RSS and Atom reader, for people who would rather choose what they read than be given it. Readers subscribe by address; Nook fetches on their schedule and renders natively, with per-feed choice of the reader, a web view, or the original site. Articles can be starred, categorised, filtered and saved offline, and subscriptions import and export as OPML. Two things distinguish it: any article can be translated in place, and read state syncs between the reader's own devices through a folder they pick — no account, nothing of ours in the path.

4. GETTING IN. Reading needs no setup and no account: launch, finish the tutorial, then Feeds > + > Subscribe to Site and paste a site address — a feed URL or an ordinary one. Try https://news.hada.io/rss/news or https://tech.kakao.com. Translate is in the reader's title bar; providers are in Settings > Translation. For Nook Plus: Settings > Nook Plus > Sign In with the demo credentials in App Review Information; that account already has published articles.

5. EXTERNAL SERVICES. Feeds are fetched straight from the sites the reader subscribed to — no catalogue, no proxy, nothing of ours in between. Translation and summaries run on-device via Apple Intelligence, or via Google Gemini only if the reader supplies their own API key, held in the Keychain. Publishing talks to our api.nooker.app and the writer's repository. No analytics, advertising, attribution or payment SDK.

6. REGIONS. Features and content are the same everywhere; nothing is region-gated. One thing varies by device rather than storefront: Apple Intelligence is not available in every region, device or system language. Where it is not, Nook falls back to the system translation overlay and hides the on-device summary features — so if translation looks absent on the review device, that is why. Choosing Gemini with an API key exercises the same feature.

7. REGULATION AND THIRD-PARTY MATERIAL. Nook is not in a regulated industry and makes no claim requiring a licence. It does display third-party material, as any feed reader does. Feeds exist to be fetched and rendered — that is what the formats are for. The reader chooses every source; we ship no catalogue and make no editorial selection. Nothing is redistributed: fetch and display happen on the device, nothing of ours stores or forwards publisher content, and the original page is one tap away. On the publishing side the material is the writer's own: single-author, members cannot reach each other, and authors can delete any article or their publication at any time. Support: https://www.nooker.app/support/
```

---

# The long version, and the source for the notes field

# 1. Screen recording

> Attached: a screen recording made on a physical iPhone running the current
> released version of iOS. It starts at the Home Screen, launches the app from a
> cold start, and goes through the whole first-run experience and then each core
> feature in the order a new user meets them: the tutorial, the one screen that
> offers notifications and background refresh, adding a feed by pasting a website
> address, reading an article in the native reader, translating it, starring and
> organising it, and the settings that control all of it.
>
> The reading half of Nook needs no account. Everything above works on a device
> that has never signed in to anything, and nothing in the app asks the reader to
> create an account in order to read.
>
> Nook Plus, the optional publishing feature, does have an account, and the
> recording covers it: signing in with the review credentials below, writing and
> publishing an article, and then the account controls in Settings › Nook Plus.
> Account creation is shown as well — it is invitation-only, so the recording uses
> an invitation code rather than a public sign-up form.
>
> Account deletion is in Settings › Nook Plus › Delete Account, and the recording
> shows it end to end. The reader confirms with their account password, which is
> verified by the server that stores their writing rather than by the app; the
> account, its identifier, its handle, every publication, every article, and every
> image are then deleted, and the published pages come down. It cannot be undone,
> and the app says so before it asks for anything. Unpublished drafts live only on
> the device and are offered as a separate choice in the same step, because deleting
> the account does not reach them and this device may hold the only copy.
>
> There is a second, milder control directly above it, and the difference is worth
> stating so it is not mistaken for the first. Nook Plus is a membership layered on
> top of a repository that belongs to the writer. "Leave Nook Plus" ends the
> membership and takes down the pages the service generated, and keeps the account
> and everything in it. Both are in the recording.
>
> The remaining items in your list do not apply and so are not in the recording:
> there is no paid content, subscription, or in-app purchase of any kind (the app
> links no purchase API), no user-to-user content, and no request for location,
> contacts, camera, photos, or App Tracking Transparency. The only permission the
> app ever requests is notifications, and the recording shows when: after a setting
> that needs it has been switched on, never at launch. Every such setting ships
> off.

# 2. Devices and operating systems tested

> [DEVICES]
>
> Example of the form to use — replace with what was actually tested:
> iPhone 17 Pro (iOS 26.x), iPhone 15 (iOS 26.x), iPad Pro 13-inch M4 (iPadOS 26.x).
> All physical devices; the builds were also exercised in the simulator during
> development, but the testing above was on hardware.
>
> The deployment target is iOS 18.0. The app ships one main app and three share
> extensions (Add Feed, Discover, Save), and all four were exercised on each device
> listed.

# 3. What the app does, and for whom

> Nook is an RSS and Atom reader for people who would rather choose what they read
> than be given it.
>
> The problem: following a few dozen writers, blogs, and publications now means
> either visiting each site by hand or accepting an algorithmic feed that decides
> what surfaces. The first does not scale and the second is not yours.
>
> What Nook does about it: the reader subscribes to sources by address, and Nook
> fetches them on a schedule the reader sets and renders them in a native reading
> surface — real typography, images, code, quotes, tables — with per-feed control
> over whether an article opens in that reader, in a full-page web view, or on the
> original site. Articles can be starred, filed into colour-coded categories,
> filtered, searched, and downloaded for offline reading. Subscriptions import and
> export as OPML, so nothing is locked in.
>
> Two things distinguish it. **Translation**: any article can be translated in
> place, title list included, on-device through Apple Intelligence or through the
> reader's own Gemini API key. **Sync without an account**: read state, stars,
> folders, categories and per-feed settings move between the reader's own devices
> through a folder they choose — iCloud Drive, Dropbox, anything that syncs files.
> Each device writes its own file and Nook merges them, so there is no server of
> ours in the path and no account to create.
>
> Audience: people who already read this way — developers, designers, researchers,
> journalists, and anyone who kept using feeds after the big readers shut down —
> and readers of more than one language, for whom the translation is the reason to
> switch.
>
> Nook Plus, the optional publishing side, is for the subset of those readers who
> also write. It is invitation-only and in beta. It is not named in the app's title
> or subtitle, precisely because most people who install the app cannot use it.

# 4. Setting up and reaching the features

> **Reading — no setup, no account.**
> 1. Launch the app and go through the short tutorial.
> 2. The screen after it offers notifications and background refresh. Both are off
>    until accepted, and declining leaves the app fully functional.
> 3. Feeds › + › Subscribe to Site, then paste a site address. Nook accepts a feed
>    URL directly or discovers the feed from an ordinary web address. Working
>    examples, all public and free:
>    - https://news.hada.io/rss/news
>    - https://developer.apple.com/news/rss/news.rss
>    - https://tech.kakao.com
>    - https://daringfireball.net/feeds/main
> 4. Tap an article to read it. The Translate action is in the reader's title bar.
>    The reading language and the translation provider are in Settings ›
>    Translation.
> 5. Alternatively import many feeds at once: Settings › Import OPML.
>
> **Sync (optional).** Settings › Sync folder, then pick any folder — iCloud Drive
> is the default suggestion. Not needed to review anything.
>
> **Nook Plus (optional, account required).** Settings › Nook Plus › Sign In.
>
> ```
> Handle:   [HANDLE]
> Password: [APP PASSWORD]
> ```
>
> The same credentials are in the Demo Account fields. The account already has
> published articles, so no screen is empty. Account creation is invitation-only;
> if you would like to exercise the sign-up flow yourself rather than watch it in
> the recording, reply here and we will issue an invitation code to a review
> address of your choosing.

# 5. External services

> **Nothing in the reading half of the app talks to a service of ours.** Feeds are
> fetched from the addresses the reader typed, directly from the device.
>
> - **Feed and article hosts** — whichever sites the reader subscribes to. There is
>   no bundled catalogue, no proxy, and no server of ours between the device and
>   the publisher. This is also why `NSAllowsArbitraryLoads` is set: a large share
>   of the web's feeds are still served over HTTP or redirect through an HTTP host,
>   and the app cannot enumerate addresses the reader has not typed yet. No
>   first-party endpoint uses cleartext.
> - **Apple Intelligence / Foundation Models (Apple, on device)** — the default
>   provider for translation, article summaries, and category suggestions. Runs on
>   the device; nothing leaves it. Falls back to the system Translation overlay
>   where the on-device model is unavailable.
> - **Google Gemini (`generativelanguage.googleapis.com`)** — an alternative
>   provider for the same three features, **off unless the reader enters their own
>   Google API key**, which is stored in that device's Keychain and never written
>   to the sync folder or sent anywhere but Google. When it is on, the article text
>   being translated or summarised goes to Google under the reader's own API key
>   and their agreement with Google. Models used: `gemini-3.5-flash-lite`, with
>   `gemini-3.6-flash` as the retry.
> - **Nook Plus service (`api.nooker.app`) and the writer's AT Protocol repository
>   (PDS)** — used only by the optional publishing feature, only after sign-in.
>   Holds the membership, the invitation, and the public pages generated from what
>   the writer publishes.
> - **Sync transport** — none of ours. Files are written to a folder the reader
>   picks; whatever syncs that folder is the reader's existing service, and Nook
>   never sees it.
>
> No analytics SDK, no advertising SDK, no attribution or tracking of any kind. No
> in-app purchase, subscription, or payment processor — the app links no purchase
> API. Third-party code is limited to open-source libraries compiled into the app
> (swift-markdown, cmark, Yams, OpenAPIKit, and our own protocol package); none of
> them is a service and none makes network calls of its own.

# 6. Regional differences

> The app's features are the same in every region and no content is gated by
> region, but two things vary with the device rather than with the store front, and
> a reviewer could meet either:
>
> - **Apple Intelligence is not available everywhere.** Its availability depends on
>   the device model, the system language, and the region Apple has enabled it in.
>   Where it is unavailable, Nook detects that and falls back to the system
>   Translation overlay, and the on-device summary and categorisation features stay
>   hidden rather than failing. If translation appears absent on the review device,
>   this is why; selecting Gemini in Settings › Translation and supplying an API key
>   exercises the same features over the network.
> - **What a feed contains depends on the publisher, not on us.** Nook displays
>   whatever the subscribed site publishes, in whatever language it publishes it.
>   There is no editorial selection and no region-specific catalogue.
>
> The app's interface ships in English, Korean, Japanese, and Simplified Chinese,
> and follows the device language. Nook Plus is invitation-only worldwide — it is
> not restricted to, or withheld from, any particular region.

# 7. Regulated industry and third-party material

> Nook does not operate in a regulated industry. It is not a financial, medical,
> gambling, or health app, it makes no claims requiring a licence, and it holds no
> credential of that kind because none applies.
>
> It does display third-party material, and that is worth answering plainly rather
> than denying: open a feed reader and somebody else's article is on screen. The
> basis for it:
>
> - **Feeds exist to be fetched and rendered.** Publishing an RSS or Atom feed is
>   an invitation to readers like this one; that is what the formats are for.
> - **The reader chooses every source.** Nook ships no catalogue of publishers and
>   makes no editorial selection. Somebody types an address, or pastes a site and
>   the app looks for its feed.
> - **Nothing is redistributed.** The fetch happens on the device and the article
>   is displayed on that device. No server of ours stores, caches, or forwards
>   publisher content, and there is no surface where one user sees what another
>   subscribed to.
> - **The original is always one tap away.** Reader view renders the publisher's own
>   page, the original page opens in the app, and a feed can be set to open the
>   original by default. Nothing removes a publisher's attribution or their page.
> - **Translation is the reader's own act**, performed on the reader's device for
>   the reader alone, on an article they already have open — on-device through
>   Apple Intelligence, or through the reader's own Google API key. It is not
>   published anywhere and is the same category of act as a browser's translate.
>
> The screenshots and the recording show real public feeds for the same reason:
> mock content would misrepresent the app.
>
> On the publishing side, the material is the writer's own. Nook Plus is a
> single-author tool — a member writes and publishes to their own site, and no
> screen in the app shows content authored by anyone else. Members cannot reach
> each other, so there is no timeline, no discovery, and no messaging. Authors can
> delete any article or their whole publication at any time, and deletion
> propagates to the pages and feeds built from it. Support and contact are
> published at https://www.nooker.app/support/.

---

## The recording (item 1)

One take, on a physical iPhone, current released iOS. Start on the Home Screen —
App Review asks for the launch, and a recording that begins with the app already
open gets sent back. Do not narrate; captions are unnecessary. Aim for four to six
minutes and do not rush the parts that answer a question they asked.

Delete and reinstall the app first, so the first run is genuinely a first run.

1. **Home Screen → cold launch.**
2. **Tutorial**, at reading pace.
3. **The notifications and background-refresh screen.** Show that every switch is
   off, turn one on, and let the iOS permission prompt appear. This is the answer
   to their "prompts requesting access" bullet, and it needs to be visible that the
   prompt follows the choice instead of preceding it.
4. **Add a feed**: Feeds › + › Subscribe to Site, paste a site address, watch the
   feed resolve and the articles arrive. Use a site with a discoverable feed rather
   than a bare feed URL — it shows more of what the app does.
5. **Import OPML** briefly, so the library is not one feed for the rest of the take.
6. **Read an article** in the native reader. Scroll through images, code, a quote.
7. **Translate it** in place. If the review device has Apple Intelligence, use it;
   if not, this is the moment to show the fallback, and item 6 has already
   explained why.
8. **Star it, categorise it, search for it.** Swipe a row to mark read.
9. **Switch the reading mode** for one feed to the full-page web view, and to the
   original site.
10. **Settings**, unhurried: sync folder, translation providers, refresh schedule,
    badges, notification diagnostics.
11. **Nook Plus** — sign in with the review credentials, write and publish a short
    article, open its public page, then Settings › Nook Plus and go through the
    account controls. Show Leave Nook Plus and its wording, then go through Delete
    Account in full — enter the password, confirm, and let the deletion complete.
    This is the flow App Review asked for by name; a recording that stops at the
    confirmation dialog has not shown it. Deleting the review account ends the
    recording, so do this last, and re-create it before sending the reply so the
    demo credentials still work.
12. **Account creation**, from the invitation code, so registration is on the tape
    as they asked.

Save it as H.264 in a file App Store Connect will accept, and attach it to the same
reply as the seven answers. One reply, everything in it.
