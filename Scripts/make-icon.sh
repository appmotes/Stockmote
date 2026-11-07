#!/usr/bin/env bash
# make-icon.sh — generates Resources/AppIcon.icns from Scripts/make-icon.swift.
#
# Run it if you've changed the icon's drawing code. make-app.sh calls it
# automatically if the .icns file is missing.

set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Resources

swift Scripts/make-icon.swift Resources

# iconutil ships with macOS and packs the .iconset folder into a single .icns.
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset

echo "==> Resources/AppIcon.icns ($(du -h Resources/AppIcon.icns | cut -f1))"
