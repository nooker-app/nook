# App Review Information

Not shown to anyone but the reviewer. Its job is to answer, before it is asked,
every question this app is going to raise.

## Sign-in

Answer **no** to "Does your app require a sign-in?" — the reader is the app, and it
works completely without an account. Publishing needs one, and the note below says
how to reach it.

## Demo account

Publishing is invitation-only, so a reviewer who taps into it hits a wall unless we
hand them a way through. Create a throwaway account on the production PDS before
submitting and put it in the Demo Account fields:

```text
Username: <handle>.nooker.app
Password: <the account's app password>
```

Rules for that account, so submitting does not become a security event:

- Make it for review only. Not a personal account, not one holding real writing.
- Use an app password from the PDS, not the account password.
- Publish one or two throwaway articles first, so the screens are not empty.
- Rotate or delete it after the review completes.
- Never paste it into a commit, an issue, or a transcript. App Store Connect is
  the only place it goes.

## Notes

Paste into the Notes field:

```text
Nook is an offline-first RSS reader. Everything in the screenshots except the last
one works with no account and no network: add a feed, read, star, organise, and
translate. There is nothing to sign in to for that part of the app.

Publishing is a separate, optional feature, in beta and open to invited accounts
only. A demo account is provided above so it can be reviewed. It is reachable from
Settings > Nook Plus.

Two things worth knowing in advance:

1. NSAllowsArbitraryLoads is set. RSS feeds are addresses the user types in, and a
   large share of the web's feeds are still served over HTTP or redirect through an
   HTTP host. The app cannot know those addresses ahead of time, so it cannot list
   them as ATS exceptions. No first-party endpoint uses cleartext: the publishing
   API and the PDS are HTTPS only.

2. Translation offers two providers. Apple Intelligence runs on the device. Gemini
   is off until the user enters their own Google API key, which is stored in the
   device Keychain and never leaves it except as a request to Google on the user's
   behalf. Nothing is sent anywhere by default.

Background modes (fetch, processing) refresh feeds on the user's schedule. Both
badges and new-article notifications ship off; the app asks for notification
permission only after one of them is switched on, never at launch.
```

## Age rating

Content questions — violence, gambling, sexual content, horror, profanity — are all
none. Nook has no content of its own; it shows what the user subscribed to.

### Capabilities

| Question | Answer | Why |
| --- | --- | --- |
| Unrestricted Web Access | **Yes** | The reader embeds a web view for original pages, and links inside it open in the app. Any URL a feed points at is reachable, and nothing is filtered. |
| User Generated Content | **Yes** | Publishing distributes what the user writes as a public page with a feed. That is distribution of user-generated content, and it is the point of the feature. |
| Social Media | **No** | Nothing in the app shows one user another's writing. No following, no likes, no discovery of other writers, no shared timeline. A writer can subscribe to their own publication as a feed; that is the only place published content appears in the app. |
| Social media disabled for under-13 | **No** | There is no social media feature to disable. Answering yes would claim the app calls the Declared Age Range API, which it does not. |
| Messaging and Chat | **No** | Users cannot reach each other. There is no messaging of any kind. |
| Advertising | **No** | No ad SDK and no promotion. The dependency list is Apple's packages, Yams, OpenAPIKit, Sparkle, cmark, swift-markdown, and the project's own protocol package. |

Unrestricted Web Access alone puts the rating at 17+, or 18+ under the newer bands.
Do not soften it: it is the answer most likely to be checked against the app,
because the app plainly has a browser in it.

### What "User Generated Content — Yes" invites

Guideline 1.2 asks apps with user-generated content for a way to filter
objectionable content, a way to report it, a way to block abusive users, and
published contact information. Say this in the notes before it is asked:

```text
Publishing is a single-author tool: a member writes and publishes to their own
site. No screen in the app shows content authored by anyone else — there is no
timeline, no discovery of other writers, and no way for one member to reach
another. Filtering, reporting, and blocking have no surface to act on because
members never see each other's content in the app.

What does exist: the author can delete any article and their whole publication at
any time, deletion propagates to the pages and feeds built from it, and support is
published at https://www.nooker.app/support/.
```

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in the iOS Info.plist, so this is
answered at build time and the upload stops asking. The claim is accurate: the app
uses HTTPS and the Keychain through Apple's APIs and implements no cryptography of
its own.

## Content rights

The app displays third-party content — the feeds the user subscribes to. Answer
that it does contain, show, or access third-party content, and that the user
supplies the sources. There is no bundled catalogue of publishers.
