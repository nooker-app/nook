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

Answer everything at the lowest level. The app has no violence, no gambling, no
sexual content of its own, and no user-to-user features.

One question does apply: **Unrestricted Web Access — Yes**. Nook opens feeds and
original pages the user chooses, and a reader that can load any URL has to say so.
That answer alone puts the rating at 17+ or, with the newer age bands, 18+.

Do not answer no to look friendlier. It is the question most likely to be checked
against the app, because the app plainly has a browser in it.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in the iOS Info.plist, so this is
answered at build time and the upload stops asking. The claim is accurate: the app
uses HTTPS and the Keychain through Apple's APIs and implements no cryptography of
its own.

## Content rights

The app displays third-party content — the feeds the user subscribes to. Answer
that it does contain, show, or access third-party content, and that the user
supplies the sources. There is no bundled catalogue of publishers.
