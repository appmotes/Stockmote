#!/usr/bin/env bash
# make-screenshots.sh — genererer billederne i docs/.
#
# Det er renderinger af den rigtige UI-kode med rigtige kurser (appens
# --snapshot-tilstand), ikke skærmbilleder af den kørende app. Snapshot-
# tilstanden gemmer sine indstillinger i et separat domæne, så den rører ikke
# hvad appen selv viser.

set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p docs

swift build -c release
BIN=.build/release/Stockmote

# Fjern de gamle skærmbilleder — men ikke app-ikonet, som README viser øverst.
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
