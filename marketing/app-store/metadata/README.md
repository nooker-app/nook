# App Store Connect metadata

The text that goes into App Store Connect, kept here so it is reviewable and so
the four locales can be compared side by side instead of being retyped into a web
form one at a time.

App Store Connect is still the system of record. Nothing here is uploaded
automatically; these are the strings to paste, and the reasoning behind them.

## Files

```text
en.md         English (primary)
ko.md         Korean
ja.md         Japanese
zh-Hans.md    Simplified Chinese
review.md     App Review Information: notes, demo account, ATS justification
app-privacy.md  Answers to the App Privacy questionnaire
```

## Field limits

App Store Connect truncates silently in some fields and refuses in others, so
every string below is counted before it is pasted:

| Field | Limit | Localized |
| --- | --- | --- |
| App Name | 30 | yes |
| Subtitle | 30 | yes |
| Promotional Text | 170 | yes |
| Description | 4000 | yes |
| Keywords | 100 | yes |
| What's New | 4000 | yes |

Keywords are one comma-separated list with no spaces after the commas — a space
counts against the 100.

## Two constraints that shaped the copy

**The name carries no search terms.** "Nook: Read, Write, Own" says what the app
is for rather than what it is called in a search box, so the subtitle and the
keyword list have to carry RSS discovery on their own. Both lead with it.

**Publishing is invitation-only.** Naming a gated feature in the app's title is
how metadata gets rejected under guideline 2.3: most people who install it cannot
use that feature. Publishing appears in the description, where the sentence has
room to say it needs an invitation, and nowhere earlier.

## Things Apple rejects that are easy to write by accident

- Competitors' names in keywords. No "feedly", "Reeder", "NetNewsWire" — a
  trademark in the keyword field is a rejection, not a ranking penalty.
- The words "RSS reader" repeated in keywords when they are already in the
  subtitle. Apple indexes name, subtitle, and keywords as one set; repeating
  spends characters for nothing.
- Prices, "free", or promotional claims in the description.
- Screenshots or copy showing a feature that needs an account the reviewer does
  not have. See `review.md`.
