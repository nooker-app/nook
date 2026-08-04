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

1. A Developer ID Application certificate on this Mac, exported to a .p12.

   Create it in Xcode > Settings > Accounts > (your team) > Manage Certificates
   > + > Developer ID Application. The Apple Development certificate already
   installed cannot sign for distribution.

   Then export just that one, in Keychain Access: find "Developer ID
   Application", right-click > Export, save as .p12, and set a password.

   Keychain Access rather than `security export`: that command exports every
   identity in the keychain, which would put the development signing key into CI
   as well. Only the one certificate belongs there.

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
if [ -n "$IDENTITY" ]; then
  printf 'Installed on this Mac: %s\n' "$IDENTITY"
else
  printf 'No Developer ID Application certificate is installed here.\n'
  printf 'That is fine if the .p12 came from another Mac.\n'
fi
echo

read -r -p "Path to the .p12: " P12
[ -f "$P12" ] || die "No file at that path."
read -r -s -p "Its export password: " P12_PASSWORD; echo
[ -n "$P12_PASSWORD" ] || die "Empty password; the workflow could not open the .p12."

# Best effort: confirm the password opens it and that it holds the right
# certificate, so a wrong file fails here rather than in CI. Apple's .p12 files
# use ciphers OpenSSL 3 only reads with -legacy, and some builds lack it — a
# check that cannot run is skipped rather than treated as a failure.
if command -v openssl >/dev/null; then
  CONTENTS="$(printf '%s' "$P12_PASSWORD" \
    | openssl pkcs12 -in "$P12" -nokeys -passin stdin 2>/dev/null \
    || printf '%s' "$P12_PASSWORD" \
    | openssl pkcs12 -legacy -in "$P12" -nokeys -passin stdin 2>/dev/null || true)"
  if [ -z "$CONTENTS" ]; then
    printf 'Could not read the .p12 here; leaving it to CI to verify.\n'
  elif printf '%s' "$CONTENTS" | grep -q "Developer ID Application"; then
    printf 'Verified: the .p12 holds a Developer ID Application certificate.\n'
  else
    die "That .p12 has no Developer ID Application certificate in it. Exported the wrong one?"
  fi
fi

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

Move the .p8 and the .p12 somewhere safe, or delete them. Apple will not let you
download the .p8 again, and both are in the repository's secrets either way.
NEXT
