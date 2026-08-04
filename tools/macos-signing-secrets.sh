#!/bin/bash
# Puts the five secrets the release workflow needs for a signed, notarized Mac
# build into the GitHub repository. Until they exist the workflow builds ad-hoc,
# which is why downloads still warn about an unidentified developer.
#
# Run it yourself. Nothing here prints a secret, and every value is piped into
# `gh secret set` on stdin rather than passed as an argument, so none of them
# reach the process list or your shell history.
#
# What it does NOT do: create the certificate or the API key. Those are yours to
# make, on a machine you choose, because each one puts a private key on that
# machine and Apple limits how many can exist.

set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null || die "gh is not installed: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"

cat <<'PREREQ'
Before running this, two things have to exist.

1. A Developer ID Application certificate on this Mac.
   Xcode > Settings > Accounts > (your team) > Manage Certificates > + >
   Developer ID Application. This is the certificate that signs the app; the
   Apple Development one already installed cannot.

2. An App Store Connect API key with the Developer role, downloaded as a .p8.
   appstoreconnect.apple.com > Users and Access > Integrations > Keys.
   The .p8 downloads exactly once. Note the Key ID and the Issuer ID.

An API key rather than an Apple ID and app-specific password: it is scoped to
notarization, it does not carry the account's own credentials, and it can be
revoked on its own.

PREREQ

read -r -p "Both ready? [y/N] " ready
[ "$ready" = "y" ] || die "Nothing was changed."

# --- The certificate -------------------------------------------------------

IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
[ -n "$IDENTITY" ] || die "No Developer ID Application certificate found. See step 1 above."
printf 'Found: %s\n\n' "$IDENTITY"

P12="$(mktemp -t nook-signing).p12"
# Deleted whatever happens next, including a failure or an interrupt: a .p12
# holding a signing key must not be left behind in a temporary directory.
trap 'rm -f "$P12"' EXIT INT TERM

cat <<'EXPORT'
`security export` will ask twice for a password to encrypt the .p12 with. Pick
anything; you are about to store it as a secret and will not need to type it
again. It is not your Apple ID password and not your login password.

EXPORT

security export -t identities -f pkcs12 -o "$P12" \
  || die "Export failed. If it asked for keychain access, allow it and run again."

read -r -s -p "The password you just chose: " P12_PASSWORD; echo
[ -n "$P12_PASSWORD" ] || die "Empty password; the workflow could not open the .p12."

base64 -i "$P12" | gh secret set MACOS_CERTIFICATE_P12
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PASSWORD
unset P12_PASSWORD
printf 'Certificate stored.\n\n'

# --- The notary key --------------------------------------------------------

read -r -p "Path to the .p8 key file: " P8
[ -f "$P8" ] || die "No file at that path."
read -r -p "Key ID (the 10 characters in the filename): " KEY_ID
[ -n "$KEY_ID" ] || die "Key ID is required."
read -r -p "Issuer ID (a UUID, on the Keys page): " ISSUER_ID
[ -n "$ISSUER_ID" ] || die "Issuer ID is required."

base64 -i "$P8" | gh secret set MACOS_NOTARY_KEY_P8
printf '%s' "$KEY_ID" | gh secret set MACOS_NOTARY_KEY_ID
printf '%s' "$ISSUER_ID" | gh secret set MACOS_NOTARY_ISSUER_ID
printf 'Notary key stored.\n\n'

cat <<'NEXT'
All five are set. `gh secret list` will show them; their values are no longer
readable by anyone, including you.

Next, test it without publishing anything:

  gh workflow run Release -f version=0.0.0-signingtest

Run it that way — not by pushing a tag. Turning hardened runtime on changes how
Sparkle's installer XPC services load, and that combination has never been
exercised. The workflow now asks Gatekeeper whether the result is acceptable and
fails if it is not, so a broken build stops there instead of shipping.

Then download the artifact and confirm an update still installs over the
previous version. That is the path hardened runtime is most likely to break.

Move the .p8 somewhere safe or delete it. Apple will not let you download it
again, and it is now in the repository's secrets either way.
NEXT
