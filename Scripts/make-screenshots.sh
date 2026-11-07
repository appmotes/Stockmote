#!/usr/bin/env bash
# make-screenshots.sh — renders the images in docs/.
#
# These are renderings of the real UI code with live quotes (the app's
# --snapshot mode), not screenshots of the running app. Snapshot mode keeps
# its settings in a separate domain, so it doesn't touch what the app itself
# shows.

set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs

swift build -c release
BIN=.build/release/Stockmote

# Remove the old screenshots — but not the app icon, which the README shows at the top.
find docs -name '*.png' ! -name 'app-icon.png' -delete
"$BIN" --snapshot docs/map.png
"$BIN" --snapshot docs/light.png --theme light --index dax
"$BIN" --snapshot docs/c25.png --index c25
"$BIN" --snapshot docs/sector.png --sector "Information Technology"
"$BIN" --snapshot docs/nasdaq-1m.png --index ndx --period 1M --theme light
"$BIN" --snapshot docs/favorites.png --tab favorites
"$BIN" --snapshot docs/list.png --list --sector "Information Technology"
"$BIN" --snapshot docs/settings.png --tab settings --size small
"$BIN" --snapshot docs/english.png --lang en --index ftse
"$BIN" --snapshot docs/fullscreen.png --fullscreen --notch 32 --replay 0.6 --index c25
"$BIN" --snapshot docs/replay.png --replay 0.35
"$BIN" --snapshot docs/fund.png --fund IWDA.AS
"$BIN" --snapshot docs/fund-dialog.png --fund-search "semiconductor ucits" --fund-pick SEC0.DE
