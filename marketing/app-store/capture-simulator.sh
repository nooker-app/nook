#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
  echo "Usage: $0 <locale> <capture-name> [simulator]" >&2
  echo "Example: $0 ko 01-library 'iPad Air 13-inch (M4)'" >&2
  exit 64
fi

LOCALE="$1"
CAPTURE_NAME="$2"
SIMULATOR="${3:-iPad Air 13-inch (M4)}"
SCRIPT_DIR="${0:A:h}"
DESTINATION="${SCRIPT_DIR}/captures/${LOCALE}/ipad-13/${CAPTURE_NAME}.png"

if ! xcrun simctl list devices booted | grep -Fq "${SIMULATOR} ("; then
  echo "Boot the '${SIMULATOR}' simulator first." >&2
  exit 1
fi

mkdir -p "${DESTINATION:h}"
xcrun simctl status_bar "${SIMULATOR}" override \
  --time '12:30' \
  --batteryState charged \
  --batteryLevel 100 \
  --wifiBars 3 \
  --cellularBars 4
xcrun simctl io "${SIMULATOR}" screenshot "${DESTINATION}"

WIDTH="$(sips -g pixelWidth "${DESTINATION}" | awk '/pixelWidth/ { print $2 }')"
HEIGHT="$(sips -g pixelHeight "${DESTINATION}" | awk '/pixelHeight/ { print $2 }')"
if [[ "${WIDTH}x${HEIGHT}" != '2048x2732' && "${WIDTH}x${HEIGHT}" != '2064x2752' ]]; then
  echo "Unexpected iPad screenshot size: ${WIDTH}x${HEIGHT}" >&2
  exit 1
fi

echo "Captured ${DESTINATION} (${WIDTH}x${HEIGHT})"
