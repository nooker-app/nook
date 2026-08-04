# App Privacy

The questionnaire in App Store Connect and `NookiOS/PrivacyInfo.xcprivacy` describe
the same thing to two different audiences. They have to agree — Apple shows the
manifest's contents on the product page, and a mismatch is a discrepancy someone
eventually notices.

Answer the questionnaire from this file, and if either side changes, change both.

## Data used to track you

None. Answer **no** to tracking throughout. There is no advertising identifier, no
attribution SDK, no analytics, and no third-party partner receiving anything.

## Data linked to you

All three exist only because of publishing, which is optional and invitation-only.
A reader who never creates an account produces none of it.

| Data | Type in ASC | Purpose | Why it exists |
| --- | --- | --- | --- |
| Email address | Contact Info › Email Address | App Functionality | Given at account creation; the repository host confirms the address and sends password resets. |
| Account identifier | Identifiers › User ID | App Functionality | The DID and handle. The DID is what the user's own records belong to. |
| Published articles | User Content › Other User Content | App Functionality | What the user publishes on purpose. It lives in their AT Protocol repository. |

Linked, not tracking, and used for app functionality only — not analytics, not
personalisation, not advertising.

## Data not collected

Worth stating explicitly, because the answers are counter-intuitive for a reader:

- **Subscriptions, read state, stars, categories, filters.** On the device. Sync
  moves files through a folder the user chose, in their own cloud account; no
  server of ours sees them.
- **Browsing or reading history.** Never leaves the device and is not sent
  anywhere.
- **Article text sent for translation.** Apple Intelligence is on device. Gemini
  goes to Google under the user's own API key — their account with Google, not a
  partner of this app's, and not something the developer receives, stores, or can
  read. Declared nowhere because the developer collects none of it.
- **Diagnostics and crash data.** Not collected. There is no crash reporter.
- **Location, contacts, photos, health, financial, or device identifiers.** Not
  accessed at all.

## Required-reason APIs

Declared in `NookiOS/PrivacyInfo.xcprivacy`, and repeated here so the reason is
readable without opening a plist:

| API category | Reason | What actually uses it |
| --- | --- | --- |
| User Defaults | `CA92.1` | Settings, reading state, per-feed preferences. `UserDefaults.standard` with no suite name and no App Group entitlement anywhere in the project, so these are readable by this app alone. |
| File Timestamp | `C617.1` | Modification dates of cached translations and summaries, read to evict the oldest. The caches are inside the app container. |

Nothing else in the required-reason list is used: no disk-space queries, no active
keyboard list, no system boot time.

## When this needs revisiting

- A crash reporter or any analytics is added — that changes the first section.
- Sync stops being folder-based, or anything about reading reaches a server of
  ours.
- Publishing starts holding something not listed above.
- A required-reason API is introduced. Apple's check runs at upload and mails a
  warning; the fix is a manifest entry, and this table is where the reason gets
  written down.
