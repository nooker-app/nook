#!/bin/zsh
set -uo pipefail
D=FCAD7603-21BD-410F-94D3-36EDBEFA6B36
OUT="${1:-/tmp/06-add-feed.mp4}"
rm -f "$OUT"

# The simulator keyboard is a Korean IME, so HID keystrokes arrive as jamo.
# Everything goes through the pasteboard instead, which is also what the
# on-screen copy tells the user to do.
printf 'https://tech.kakao.com' | xcrun simctl pbcopy "$D"

# Reset to the feeds tab with no sheet up.
idb ui tap --udid "$D" 51 103 2>/dev/null
sleep 1.2

xcrun simctl io "$D" recordVideo --codec h264 --force "$OUT" &
REC=$!
sleep 1.3

idb ui tap --udid "$D" 396 84                 # "+" in the feeds toolbar
sleep 1.0
idb ui tap --udid "$D" 272 92                 # "사이트 구독"
sleep 1.4
idb ui tap --udid "$D" 219 196 --duration 1.2 # long press the URL field
sleep 1.0
idb ui tap --udid "$D" 66 245                 # "붙여넣기"
sleep 1.3
idb ui tap --udid "$D" 388 103                # "추가"
sleep 4.2

kill -INT $REC 2>/dev/null
wait $REC 2>/dev/null
ls -la "$OUT"
