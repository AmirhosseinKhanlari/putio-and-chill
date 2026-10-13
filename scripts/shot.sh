#!/bin/zsh
# usage: scripts/shot.sh "<simulator name>" <shot-name> [launch args...]
set -e
device=$1; name=$2; shift 2
app=build/Build/Products/Debug-iphonesimulator/AMDB.app
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"
xcrun simctl terminate "$device" app.amdb.ios 2>/dev/null || true
xcrun simctl launch "$device" app.amdb.ios "$@" >/dev/null
sleep ${SHOT_DELAY:-6}
mkdir -p build/shots
xcrun simctl io "$device" screenshot "build/shots/$name.png" >/dev/null
echo "build/shots/$name.png"
