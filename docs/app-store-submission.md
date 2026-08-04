# Submitting to the App Store

For the iOS app. The Mac app is distributed with a Developer ID outside the App
Store — see [Signing and notarizing the Mac app](#signing-and-notarizing-the-mac-app)
at the end, which became possible with the same enrolment.

Written to be followed by someone who has not done it before, in order, with the
things that block a submission first rather than the things that are pleasant to
prepare.

## What is already done

Committed in the repository, so no step below has to produce it:

- `NookiOS/PrivacyInfo.xcprivacy` — required-reason API declarations. An upload
  without this draws an ITMS-91053 warning mail and, eventually, a rejection.
- `ITSAppUsesNonExemptEncryption` in `NookiOS/Info.plist` — answers export
  compliance at build time so the upload stops asking on every build.
- Screenshots in four languages under `marketing/app-store/output/`, five per
  size: iPhone 6.9" (1290×2796), iPhone 6.5" (1284×2778), iPad 13" (2048×2732).
- Every string to paste, counted against its field limit, in
  `marketing/app-store/metadata/`.
- A support page at <https://www.nooker.app/support/>, which the Support URL field
  requires.

## Decisions already taken

- **App Store name: `Nook: Read, Write, Own`.** Plain "Nook" is taken — an app of
  exactly that name is published by nook Office DMCC — and Barnes & Noble holds the
  NOOK mark for e-readers, which is adjacent enough to be worth not walking into.
  The home-screen name stays "Nook"; `CFBundleDisplayName` is independent of the
  store listing.
- **The name carries no search terms**, so the subtitle and keywords carry RSS
  discovery. Do not "simplify" either without replacing that.
- **Publishing is not named in the title.** It is invitation-only, and a title that
  promises a feature most installers cannot use is a metadata rejection under
  guideline 2.3. It belongs in the description, where the sentence has room to say
  so.
- **Version stays 0.1.0**, build from the CI run number.

## 1. Register the bundle identifiers

In the Developer portal, Identifiers. Four App IDs, all under team `F7WUT95TT6`:

```text
com.tim.nook.ios                     the app
com.tim.nook.ios.share               Add Feed share extension
com.tim.nook.ios.share-discover      discover extension
com.tim.nook.ios.share-save          save extension
```

The hyphens are not cosmetic. An extension's identifier may add exactly one period
to the app's, so `com.tim.nook.ios.share.discover` is rejected at upload with
ContentDelivery 90347 — after the build has been archived, signed, and sent. Nothing
earlier in the toolchain objects to it.

On `com.tim.nook.ios`, enable **Associated Domains**. The Release build claims
`webcredentials:nooker.app` so the system can offer to save a newly created Plus
password, and a profile without the capability fails to build.

Verify the association file already answers, because the entitlement is useless
without it:

```sh
curl -s https://nooker.app/.well-known/apple-app-site-association
```

It must list `F7WUT95TT6.com.tim.nook.ios`. It does today.

## 2. Create the App Store Connect record

My Apps › add. Then:

| Field | Value |
| --- | --- |
| Platform | iOS |
| Name | `Nook: Read, Write, Own` |
| Primary language | Korean or English — the store falls back to it for any locale not filled in |
| Bundle ID | `com.tim.nook.ios` |
| SKU | any stable internal string, e.g. `nook-ios` — never shown, never changeable |

If App Store Connect says the name is unavailable, it is holding a reservation the
public search cannot see. `Nook: Feeds & Writing`, `Nook: Read & Write`, and
`Nook: RSS & Publishing` were all free at the time of writing.

## 3. Fill in the listing

Paste from `marketing/app-store/metadata/`, one file per locale: `en`, `ko`, `ja`,
`zh-Hans`. Every string there is already counted against its limit.

Non-localized fields:

```text
Primary category:    News
Secondary category:  Productivity
Copyright:           2026 Tim
Privacy Policy URL:  https://www.nooker.app/privacy/
```

App Store Connect adds the © itself. Typing one gives "©© 2026".

The categories are a listing choice and are unrelated to the Mac app's
`LSApplicationCategoryType`, which stays `productivity`.

Screenshots: upload from `marketing/app-store/output/<locale>/`, five each, in
filename order. The order in the list is the order people swipe.

**Match the folder to the slot.** Each display class accepts only its own
dimensions, and the error names the sizes it wants rather than the slot you are in:

| Slot in App Store Connect | Folder | Accepts |
| --- | --- | --- |
| iPhone 6.9" Display | `iphone-6.9/` | 1290×2796 |
| iPhone 6.5" Display | `iphone-6.5/` | 1284×2778 |
| iPad 13" Display | `ipad-13/` | 2048×2732 |

Both iPhone sets are rendered rather than one resampled to fit the other: scaling a
finished screenshot would scale its text too. `config.json` carries the second size
in `iphoneExtraSizes`, drawn from the same slide definitions.

## 4. Answer the questionnaires

From `marketing/app-store/metadata/app-privacy.md` and `review.md`. These are where
submissions get held up, so read both before starting rather than answering from
memory.

Two answers people get wrong on a reader:

- **App Privacy: publishing collects an email address, a user ID, and published
  articles.** All three are linked and used for app functionality. Reading collects
  nothing — but "Data Not Collected" is only true if nothing at all is collected,
  and Plus collects.
- **Age rating: Unrestricted Web Access is Yes.** The app opens pages the user
  chooses. Answering no to keep the rating down is the answer most likely to be
  checked against an app that plainly has a browser in it.

## 5. Prepare the demo account

Publishing is invitation-only, so a reviewer cannot reach it without one. Before
submitting, create a throwaway account on the production PDS, publish one or two
articles so the screens are not empty, and put its handle and an **app password**
into the Demo Account fields.

Not a personal account. Not the account password. Rotate or delete it when the
review completes. App Store Connect is the only place those credentials go — never
a commit, an issue, or a chat log.

## 6. Archive and upload

From Xcode, with the team selected and automatic signing on:

```sh
xcodebuild -project Nook.xcodeproj -scheme NookiOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$TMPDIR/NookiOS.xcarchive" \
  -skipPackagePluginValidation \
  MARKETING_VERSION=0.1.0 CURRENT_PROJECT_VERSION=1 \
  archive
```

Then Organizer › Distribute App › App Store Connect. Xcode is easier than
`altool` here because it resolves the four provisioning profiles itself.

Check before uploading:

```sh
# The manifest must be at the bundle root, not inside a framework.
ls "$TMPDIR/NookiOS.xcarchive/Products/Applications/NookiOS.app/PrivacyInfo.xcprivacy"
```

After the upload finishes, expect mail within the hour. Warnings arrive by mail and
do not block; ITMS-91053 (missing API reason) would mean the manifest did not make
it into the bundle.

## 7. Submit

Attach the build, then submit for review. First reviews commonly take one to three
days.

If it comes back:

- **Guideline 2.1, cannot reach publishing** — the demo account expired, or it was
  the account password rather than an app password.
- **Guideline 2.3, misleading metadata** — something in the listing promises what
  an invitation gates. Check that the title and subtitle still do not mention
  publishing.
- **Guideline 5.1.1, sign-in required** — answer "no" to requiring sign-in and say
  in the notes that the reader needs no account.
- **ATS asked about** — the justification is already in `review.md`; feeds are
  addresses the user types, and they cannot be enumerated in advance.

## Signing and notarizing the Mac app

Not an App Store submission, and independent of everything above. Live as of
0.1.51 — the release workflow signs with a Developer ID, notarizes, staples, and
then asks Gatekeeper whether it worked rather than assuming.

Before that, builds were ad-hoc signed with hardened runtime off, which is all a
personal team could do, so every download warned about an unidentified developer.

### What it took, so a future change does not undo it

**Sparkle's nested helpers have to be re-signed.** Xcode signs the app and the
frameworks it embeds, but not bundles nested inside a framework — and Sparkle
arrives from SwiftPM as a prebuilt binary carrying four of them: `Autoupdate`,
`Updater.app`, `Downloader.xpc`, `Installer.xpc`. Notarization rejected the first
two attempts on exactly those, for no Developer ID and no secure timestamp.

They are signed inside-out, because signing a container seals what is inside it.
Each keeps its own entitlements, read from what is already there: the downloader is
the only part allowed to reach the network, and dropping that gives an app that
notarizes cleanly and then cannot update.

If Sparkle is upgraded and gains or renames a helper, that step is what needs
looking at. It globs `Versions/*/XPCServices/*.xpc` plus `Updater.app` and
`Autoupdate`, so a new *kind* of nested bundle would be missed — and the symptom
is a rejected notarization naming the file.

**A tag release fails without the signing secrets.** Sparkle refuses an update
signed less well than what is installed, so once someone runs a Developer ID build,
an ad-hoc release is one they can never update to — and that failure appears on
their machine, not in CI. A manual run still falls back to ad-hoc, which is what
the fallback was for.

### The secrets

`make macos-signing-secrets` stores the five the workflow looks for. It creates
neither the certificate nor the API key: each puts a private key on a machine, and
which machine is not a script's decision.

Export the certificate from Keychain Access, not with `security export` — that
command takes every identity in the keychain, which would put the development
signing key into CI as well.

### Verifying a release

The workflow already checks the staple, Gatekeeper's verdict, and the hardened
runtime flag, and fails on any of them. Two things it cannot check:

1. **The update path.** Install the previous version and press Check for Updates.
   Whether `Downloader.xpc` fetches and `Installer.xpc` swaps the bundle under
   hardened runtime does not show up in a signature check. Verified by hand for
   0.1.50 → 0.1.51, including the ad-hoc-to-signed transition every existing
   install went through.
2. **`codesign -dv` alone will not tell you.** It is verbosity 1 and prints no
   `Authority` line, so a correctly signed helper reads as unsigned. Use
   `--verbose=4`.
