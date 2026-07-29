#!/bin/zsh
# Build + launch a standalone SwiftUI harness app and capture its window.
#
#   harness.sh init                       create the harness dir with a skeleton
#   harness.sh shot <name> [delay]        build, launch, capture <name>.png, quit
#   harness.sh log  <name> [seconds]      build, run in foreground, grep stderr
#   harness.sh at   <name> <t1> [t2 ...]  capture at several delays in one run
#
#   harness.sh ios-init                   scaffold an iOS harness (needs a booted sim)
#   harness.sh ios-shot <name> [frames]   build for the sim, install, capture
#
# Sources compiled = every *.swift in the harness dir except helper tools.
# Screenshots and the .app live in the same dir.
#
# iOS matters on its own: a layout bug can be invisible on macOS and present on
# iOS (a LazyVStack row realized mid-scroll gets a different width proposal), so
# a macOS pass is not evidence about iPhone. `ios-shot` takes several frames in a
# row because the first ones catch the launch animation.
set -e

DIR="${HARNESS_DIR:-$(pwd)/harness}"
APP="$DIR/Harness.app"
BIN="$APP/Contents/MacOS/Harness"
TARGET="${HARNESS_TARGET:-arm64-apple-macos14.0}"
IOS_APP="$DIR/HarnessIOS.app"
IOS_SRC="$DIR/ios"
IOS_TARGET="${HARNESS_IOS_TARGET:-arm64-apple-ios18.0-simulator}"

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

  ios-init)
    mkdir -p "$IOS_SRC" "$IOS_APP"
    cat > "$IOS_APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Harness</string>
<key>CFBundleIdentifier</key><string>dev.harness.visual</string>
<key>CFBundleExecutable</key><string>Harness</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>UILaunchScreen</key><dict/>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
</dict></plist>
PLIST
    if [[ ! -f "$IOS_SRC/App.swift" ]]; then
      cat > "$IOS_SRC/App.swift" <<'SWIFT'
import SwiftUI

// Copy the project's real source files into this directory and use the real
// types. Two things are usually needed to reproduce an iOS-only layout bug:
//   * the article/list must be long enough that LazyVStack actually virtualizes
//   * you must scroll — use ScrollViewReader + scrollTo, because rows realized
//     mid-scroll are the ones measured against a stale width
// Anything that spins the run loop (the WebKit HTML importer) must run OUTSIDE
// the view body or AttributeGraph trips: precompute into a cache in `.task`.
struct RootView: View {
    var body: some View {
        ScrollView { Text("Replace me").padding(16) }
    }
}

@main struct HarnessApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}
SWIFT
    fi
    echo "iOS harness ready at $IOS_SRC — boot a simulator, then: $0 ios-shot first"
    ;;

  ios-shot)
    name="${2:?usage: harness.sh ios-shot <name> [frames]}"; frames="${3:-10}"
    xcrun simctl list devices booted | grep -q Booted \
      || { echo "no booted simulator. create/boot one, e.g.:
  xcrun simctl create HarnessPhone com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro <runtime>
  xcrun simctl boot HarnessPhone" >&2; exit 1 }
    [[ -f "$IOS_APP/Info.plist" ]] || { echo "run '$0 ios-init' first" >&2; exit 1 }
    sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    files=("${(@f)$(find "$IOS_SRC" -maxdepth 1 -name '*.swift' | sort)}")
    xcrun --sdk iphonesimulator swiftc -sdk "$sdk" -target "$IOS_TARGET" \
      -parse-as-library -O "${files[@]}" -o "$IOS_APP/Harness"
    xcrun simctl terminate booted dev.harness.visual >/dev/null 2>&1 || true
    xcrun simctl install booted "$IOS_APP"
    xcrun simctl launch booted dev.harness.visual >/dev/null
    # Successive frames instead of a sleep: the early ones are the launch
    # animation, and the last stable one is the settled layout.
    for i in $(seq 1 "$frames"); do
      xcrun simctl io booted screenshot "$DIR/${name}_$i.png" >/dev/null 2>&1 || true
    done
    echo "$DIR/${name}_${frames}.png"
    ;;

  *) sed -n '2,18p' "$0" ;;
esac
