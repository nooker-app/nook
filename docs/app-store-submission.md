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
- Screenshots for both required sizes in four languages, under
  `marketing/app-store/output/`. iPhone 6.9" (1290×2796) and iPad 13"
  (2048×2732), five each.
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
com.tim.nook.ios.share.discover      discover extension
com.tim.nook.ios.share.save          save extension
```

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

Screenshots: upload `marketing/app-store/output/<locale>/iphone-6.9/` and
`.../ipad-13/`, five each, in filename order. The order in the list is the order
people swipe.

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

Not an App Store submission, and independent of everything above. The release
workflow currently builds **ad-hoc signed with hardened runtime off**, because a
personal team could not do better — so every download shows an unidentified
developer warning. Enrolment changes that.

`release.yml` now takes the signed path when the secrets exist and the old ad-hoc
path when they do not, so nothing breaks until they are added:

```text
MACOS_CERTIFICATE_P12       base64 of a Developer ID Application .p12
MACOS_CERTIFICATE_PASSWORD  its export password
MACOS_NOTARY_KEY_P8         base64 of an App Store Connect API key (.p8)
MACOS_NOTARY_KEY_ID         the key's ID
MACOS_NOTARY_ISSUER_ID      the issuer UUID from the Keys page
```

An API key rather than an Apple ID and app-specific password: it is scoped, it does
not carry the account's own credentials, and it can be revoked alone.

Run it once with **workflow_dispatch**, not a tag. Turning hardened runtime on
changes how Sparkle's installer XPC services are loaded, and the entitlements for
them (`temporary-exception.mach-lookup.global-name`) have never been exercised
under it. Verify on the produced DMG before cutting a release:

```sh
spctl -a -vvv -t install /Volumes/Nook*/Nook.app   # must say "accepted, Notarized Developer ID"
codesign -dv --verbose=4 /Volumes/Nook*/Nook.app   # must show "runtime" in flags
xcrun stapler validate Nook-*.dmg
```

Then confirm an update still installs from the previous version, because that is
the path hardened runtime is most likely to have broken.
