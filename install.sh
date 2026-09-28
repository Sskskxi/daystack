#!/bin/bash
# Installs (or updates) DayStack from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/Sskskxi/toy-calendar/main/install.sh | bash
# Downloading with curl (not a browser) means macOS doesn't mark the app as "from the internet",
# so it opens without the "can't verify" / Open Anyway step.
set -euo pipefail

URL="https://github.com/Sskskxi/toy-calendar/releases/latest/download/DayStack.dmg"
TMP=$(mktemp -d)
MNT="$TMP/mnt"
cleanup() {
    hdiutil detach -quiet "$MNT" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

DEST=/Applications
[[ -w "$DEST" ]] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

echo "Downloading DayStack…"
curl -fL --progress-bar "$URL" -o "$TMP/DayStack.dmg"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$TMP/DayStack.dmg"

pkill -x DayStack 2>/dev/null || true
rm -rf "$DEST/DayStack.app"
ditto "$MNT/DayStack.app" "$DEST/DayStack.app"
xattr -dr com.apple.quarantine "$DEST/DayStack.app" 2>/dev/null || true

open "$DEST/DayStack.app"
echo "DayStack is installed in $DEST and running. Look for the calendar icon in your menu bar."
