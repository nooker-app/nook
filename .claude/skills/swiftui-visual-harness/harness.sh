#!/bin/zsh
# Build + launch a standalone SwiftUI harness app and capture its window.
#
#   harness.sh init                       create the harness dir with a skeleton
#   harness.sh shot <name> [delay]        build, launch, capture <name>.png, quit
#   harness.sh log  <name> [seconds]      build, run in foreground, grep stderr
#   harness.sh at   <name> <t1> [t2 ...]  capture at several delays in one run
#
# Sources compiled = every *.swift in the harness dir except helper tools.
# Screenshots and the .app live in the same dir.
set -e

DIR="${HARNESS_DIR:-$(pwd)/harness}"
APP="$DIR/Harness.app"
BIN="$APP/Contents/MacOS/Harness"
TARGET="${HARNESS_TARGET:-arm64-apple-macos14.0}"

skeleton() {
  mkdir -p "$APP/Contents/MacOS"
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Harness</string>
<key>CFBundleIdentifier</key><string>com.harness.visual</string>
<key>CFBundleExecutable</key><string>Harness</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
  # Window-id probe: the harness's largest normal-layer window, so panels and
  # sheets are not picked instead.
  cat > "$DIR/winid.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
var best: (id: Int, area: CGFloat)?
for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "Harness",
          let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? CGFloat, let height = bounds["Height"] as? CGFloat
    else { continue }
    let area = width * height
    if best == nil || area > best!.area { best = (number, area) }
}
if let best { print(best.id) }
SWIFT
  if [[ ! -f "$DIR/App.swift" ]]; then
    cat > "$DIR/App.swift" <<'SWIFT'
import SwiftUI
import AppKit

// Reproduce the real screen here. Copy the project's own source files into this
// directory and use the real types — a reimplementation proves nothing.
struct RootView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace me")
        }
        .padding(20)
        .frame(width: 420, height: 600, alignment: .topLeading)
    }
}

// `-parse-as-library` is what lets @main live in a file named anything.
// `.windowResizability(.contentSize)` is essential: without it the window opens
// at some inherited size and every width-dependent measurement is meaningless.
@main struct HarnessApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .windowResizability(.contentSize)
    }
}
SWIFT
  fi
  echo "harness ready at $DIR — edit App.swift, then: $0 shot first"
}

sources() {
  # Helper tools are compiled separately, never linked into the app.
  find "$DIR" -maxdepth 1 -name '*.swift' ! -name 'winid.swift' | sort
}

build() {
  [[ -d "$APP" ]] || skeleton >/dev/null
  local files
  files=("${(@f)$(sources)}")
  xcrun swiftc -O -parse-as-library -target "$TARGET" -o "$BIN" "${files[@]}"
  [[ -x "$DIR/winid" ]] || xcrun swiftc -O -o "$DIR/winid" "$DIR/winid.swift"
}

quit() { pkill -f "$BIN" 2>/dev/null || true }

launch() {
  quit
  open -a "$APP"
  sleep "${1:-1.5}"
}

case "${1:-}" in
  init) skeleton ;;

  shot)
    name="${2:?usage: harness.sh shot <name> [delay]}"
    build; launch "${3:-1.5}"
    id=$("$DIR/winid")
    [[ -n "$id" ]] || { echo "no Harness window — did it crash? try: $0 log $name" >&2; exit 1 }
    screencapture -o -l"$id" "$DIR/$name.png"
    quit
    echo "$DIR/$name.png"
    ;;

  at)
    name="${2:?usage: harness.sh at <name> <t1> [t2 ...]}"; shift 2
    build; launch 1.2
    id=$("$DIR/winid")
    [[ -n "$id" ]] || { echo "no Harness window" >&2; exit 1 }
    elapsed=0
    for t in "$@"; do
      python3 -c "import time,sys; time.sleep(max(0, float(sys.argv[1])-float(sys.argv[2])))" "$t" "$elapsed"
      screencapture -o -l"$id" "$DIR/${name}_t$t.png"
      echo "$DIR/${name}_t$t.png"
      elapsed="$t"
    done
    quit
    ;;

  log)
    name="${2:-}"; seconds="${3:-8}"
    build; quit
    # Run in the foreground so stderr (instrumentation) is capturable.
    ("$BIN" 2>&1 >/dev/null | grep -E "${HARNESS_GREP:-.}" &) 
    sleep "$seconds"; quit
    ;;

  *) sed -n '2,12p' "$0" ;;
esac
