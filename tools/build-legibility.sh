#!/bin/bash
# Regenerate NookKit/Sources/NookKit/Legibility.html from the pinned legibility commit.
#
# The generated page is one self-contained file: legibility's Rust engine compiled to
# WebAssembly and inlined as base64, plus the glue that exposes `window.legibility`. Nook
# loads it into an offscreen WKWebView (WebKit runs WebAssembly normally, JIT restrictions
# do not apply inside it) and hands it article HTML to extract. Its own CSP forbids every
# kind of network access, which is why an untrusted article can be parsed inside it.
#
# Running this needs Rust and the wasm32-unknown-unknown target; the result is checked in
# so that building Nook does not. Only run it to move the pin.
#
#   tools/build-legibility.sh            # build from the pinned commit
#   tools/build-legibility.sh --check    # verify the checked-in page matches the pin
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/tools/legibility.pin"
OUT="$ROOT/NookKit/Sources/NookKit/Legibility.html"
# Kept out of the repository: a Rust checkout and its target directory are hundreds of
# megabytes, and the only thing Nook needs from them is the one file this writes.
WORK="${LEGIBILITY_CHECKOUT:-${TMPDIR:-/tmp}/nook-legibility}"

repo="$(sed -n 's/^repo=//p' "$PIN")"
commit="$(sed -n 's/^commit=//p' "$PIN")"
digest="$(sed -n 's/^wasm=//p' "$PIN")"
short="${commit:0:7}"
[ -n "$repo" ] && [ -n "$commit" ] || { echo "tools/legibility.pin is missing repo= or commit=" >&2; exit 65; }

if [ "${1:-}" = "--check" ]; then
  # The likeliest first-run failure is the asset simply not being there, and a bare
  # `sed: no such file` does not tell anyone what to do about it.
  [ -f "$OUT" ] || { echo "${OUT#"$ROOT"/} is missing — run: make legibility" >&2; exit 1; }
  # The page states which commit and which wasm digest produced it. Checking both
  # catches what actually happens: the pin moved and nobody regenerated the asset, or
  # the asset was regenerated from a tree that was not the pinned one.
  stamp="$(sed -n 's/^const BUILD_STAMP = "\(.*\)";$/\1/p' "$OUT")"
  case "$stamp" in
    "$short · wasm $digest") echo "Legibility.html: $stamp (matches the pin)" ;;
    *) echo "Legibility.html says '$stamp' but tools/legibility.pin says '$short · wasm $digest' — run: make legibility" >&2; exit 1 ;;
  esac
  exit 0
fi

command -v cargo >/dev/null || { echo "cargo not found. Install Rust from https://rustup.rs, then re-run." >&2; exit 69; }
command -v python3 >/dev/null || { echo "python3 not found." >&2; exit 69; }

if [ ! -d "$WORK/.git" ]; then
  echo "==> cloning $repo into $WORK"
  rm -rf "$WORK"
  git clone --quiet "$repo" "$WORK"
fi

echo "==> checking out $short"
git -C "$WORK" fetch --quiet origin "$commit" 2>/dev/null || git -C "$WORK" fetch --quiet origin
git -C "$WORK" -c advice.detachedHead=false checkout --quiet "$commit"
# The generated page stamps `+dirty` when the checkout has local edits, and a stamp that
# says dirty is a stamp that cannot be reproduced. Start clean every time.
git -C "$WORK" clean -qfd
git -C "$WORK" checkout --quiet -- .

# Not fatal when it fails: a Rust installed by Homebrew rather than rustup has no
# `rustup`, and may still have the target. Let the cargo build be the thing that
# decides, and say what to do if it is the target that is missing.
if command -v rustup >/dev/null; then
  echo "==> ensuring the wasm target is installed"
  rustup target add wasm32-unknown-unknown >/dev/null
else
  echo "    note: no rustup — assuming wasm32-unknown-unknown is already installed"
fi

# wasm-opt is not required, but it is worth 120 KB of the shipped asset, so say when it is
# missing rather than quietly shipping the larger module.
command -v wasm-opt >/dev/null || echo "    note: wasm-opt not found (brew install binaryen) — the module will be ~18% larger"

# The engine build itself lives in legibility's own script, which also runs
# `cargo build --release -p legibility-wasm --target wasm32-unknown-unknown`, then
# `wasm-opt`, then inlines the module into `js/reader/reader.html` as base64. Calling
# it rather than reimplementing it is what keeps this from drifting from upstream.
echo "==> building the engine and inlining it"
python3 "$WORK/scripts/build-offline-demo.py" --template reader "$OUT"

stamp="$(sed -n 's/^const BUILD_STAMP = "\(.*\)";$/\1/p' "$OUT")"
case "$stamp" in
  "$short · wasm "*) ;;
  *) echo "the generated page is stamped '$stamp', which does not match the pin $short" >&2; exit 1 ;;
esac

built_digest="${stamp##*wasm }"
if [ -n "$digest" ] && [ "$digest" != "$built_digest" ]; then
  echo "the module built to digest $built_digest but tools/legibility.pin says $digest." >&2
  echo "If you moved the pin on purpose, update its wasm= line to $built_digest." >&2
  exit 1
fi

printf '==> wrote %s (%s KB, %s)\n' \
  "${OUT#"$ROOT"/}" "$(( $(wc -c < "$OUT") / 1024 ))" "$stamp"
