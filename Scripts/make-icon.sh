#!/usr/bin/env bash
# make-icon.sh — genererer Resources/AppIcon.icns fra Scripts/make-icon.swift.
#
# Kør den hvis du har rettet i ikonets tegnekode. make-app.sh kalder den
# automatisk hvis .icns-filen mangler.

set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Resources

swift Scripts/make-icon.swift Resources

# iconutil er en del af macOS og pakker .iconset-mappen til én .icns.
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset

echo "==> Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
