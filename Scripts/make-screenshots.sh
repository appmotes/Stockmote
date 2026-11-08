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
# The window's default size: wide enough for the period picker with each
# range's figure (at 940 × 600 it folds into a menu).
WIN="--window 1200x780"

# Remove the old screenshots — but not the app icon, which the README shows at the top.
find docs -name '*.png' ! -name 'app-icon.png' -delete
"$BIN" --snapshot docs/map.png $WIN
"$BIN" --snapshot docs/light.png $WIN --theme light --index dax
"$BIN" --snapshot docs/c25.png $WIN --index c25
"$BIN" --snapshot docs/sector.png $WIN --sector "Information Technology"
"$BIN" --snapshot docs/nasdaq-1m.png $WIN --index ndx --period 1M --theme light
"$BIN" --snapshot docs/favorites.png $WIN --tab favorites
"$BIN" --snapshot docs/list.png $WIN --list --sector "Information Technology"
"$BIN" --snapshot docs/settings.png --settings
"$BIN" --snapshot docs/english.png $WIN --lang en --index ftse
"$BIN" --snapshot docs/fullscreen.png --fullscreen --notch 32 --replay 0.6 --index c25
"$BIN" --snapshot docs/replay.png $WIN --replay 0.35
"$BIN" --snapshot docs/fund.png $WIN --fund IWDA.AS
"$BIN" --snapshot docs/fund-dialog.png --fund-search "semiconductor ucits" --fund-pick SEC0.DE
