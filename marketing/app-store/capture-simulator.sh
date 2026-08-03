#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "Usage: $0 <locale> <capture-name> [simulator]" >&2
  echo "Example: $0 ko 01-library 'iPad Air 13-inch (M4)'" >&2
  echo "Example: $0 en 01-library 'Nook Capture iPhone'" >&2
  exit 64
fi

LOCALE="$1"
CAPTURE_NAME="$2"
SIMULATOR="${3:-iPad Air 13-inch (M4)}"
SCRIPT_DIR="${0:A:h}"

if ! xcrun simctl list devices booted | grep -Fq "${SIMULATOR} ("; then
  echo "Boot the '${SIMULATOR}' simulator first." >&2
  exit 1
fi

# The device class comes from the screenshot itself rather than the simulator
# name, so a device named for its purpose ("Nook Capture iPhone") lands in the
# right folder and is still checked against the sizes the App Store accepts.
STAGING="$(mktemp -t nook-capture).png"
xcrun simctl status_bar "${SIMULATOR}" override \
  --time '12:30' \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4
xcrun simctl io "${SIMULATOR}" screenshot "${STAGING}"

WIDTH="$(sips -g pixelWidth "${STAGING}" | awk '/pixelWidth/ { print $2 }')"
HEIGHT="$(sips -g pixelHeight "${STAGING}" | awk '/pixelHeight/ { print $2 }')"
case "${WIDTH}x${HEIGHT}" in
  # 13-inch iPad, and the M4/M5 generation that is a little taller.
  2048x2732|2064x2752) DEVICE_CLASS='ipad-13' ;;
  # 6.9-inch iPhone: the 16 Pro Max size and the 17 Pro Max size.
  1290x2796|1320x2868) DEVICE_CLASS='iphone-6.9' ;;
  *)
    rm -f "${STAGING}"
    echo "Unexpected screenshot size: ${WIDTH}x${HEIGHT}" >&2
    echo "Capture on a 13-inch iPad or a 6.9-inch iPhone." >&2
    exit 1
    ;;
esac

DESTINATION="${SCRIPT_DIR}/captures/${LOCALE}/${DEVICE_CLASS}/${CAPTURE_NAME}.png"
mkdir -p "${DESTINATION:h}"
mv "${STAGING}" "${DESTINATION}"

echo "Captured ${DESTINATION} (${WIDTH}x${HEIGHT})"
