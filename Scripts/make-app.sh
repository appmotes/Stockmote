#!/usr/bin/env bash
# make-app.sh — pakker de byggede binærer som en rigtig Stockmote.app med
# widget-udvidelsen indeni.
#
# LSUIElement = true gør at appen ikke får dock-ikon og ikke optræder i
# ⌘-Tab — den lever kun i menubaren.
#
# Brug:
#   ./Scripts/make-app.sh            # release-build, signeres ad-hoc
#   ./Scripts/make-app.sh --debug    # brug debug-binærerne i stedet
#   ./Scripts/make-app.sh --install  # kopiér til /Applications
#   ./Scripts/make-app.sh --open     # åbn appen når den er bygget

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG=release
OPEN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --open) OPEN=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Ukendt flag: $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="Stockmote"
BUNDLE_ID="dk.stockmote.Stockmote"
WIDGET_ID="$BUNDLE_ID.Widget"
VERSION="1.0"
BUILD_DIR=".build/$CONFIG"
APP="build/$APP_NAME.app"
APPEX="$APP/Contents/PlugIns/StockmoteWidget.appex"

echo "==> Bygger ($CONFIG)"
swift build -c "$CONFIG"

for bin in Stockmote StockmoteWidget; do
  [ -x "$BUILD_DIR/$bin" ] || { echo "Fandt ikke $BUILD_DIR/$bin" >&2; exit 1; }
done

echo "==> Samler $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"

cp "$BUILD_DIR/Stockmote" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/StockmoteWidget" "$APPEX/Contents/MacOS/StockmoteWidget"

# Indices.json lægges i Contents/Resources, hvor UniverseStore leder først
# (efter brugerens egen kopi i Application Support).
cp Sources/Stockmote/Resources/Indices.json "$APP/Contents/Resources/Indices.json"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> AppIcon.icns mangler, genererer"
  ./Scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>Stockmote</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIconName</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>

    <!-- Ingen dock-ikon, intet ⌘-Tab: appen lever kun i menubaren. -->
    <key>LSUIElement</key>                   <true/>

    <!-- stockmote://open?tab=… — et klik på widget'en åbner panelet. -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>    <array><string>stockmote</string></array>
        </dict>
    </array>

    <key>NSApplicationCategoryType</key>     <string>public.app-category.finance</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Kurser fra Yahoo Finance og Nasdaq. Ikke investeringsrådgivning.</string>
</dict>
</plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>StockmoteWidget</string>
    <key>CFBundleDisplayName</key>           <string>Stockmote</string>
    <key>CFBundleExecutable</key>            <string>StockmoteWidget</string>
    <key>CFBundleIdentifier</key>            <string>$WIDGET_ID</string>
    <key>CFBundlePackageType</key>           <string>XPC!</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleSupportedPlatforms</key>    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key> <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST

# AppIntents-metadata: widget'ens konfiguration (indhold, indeks, sektor,
# tidsrum) skal beskrives i Metadata.appintents, ellers kan systemet ikke vise
# den. Xcode laver filen med appintentsmetadataprocessor ud fra compilerens
# konstantværdier; Package.swift beder compileren om dem (se StockmoteWidget).
echo "==> AppIntents-metadata"
META="$(mktemp -d)"
echo "$PWD/Sources/StockmoteWidget/StockmoteWidget.swift" > "$META/sources.txt"
echo "$PWD/.build/StockmoteWidget.swiftconstvalues" > "$META/consts.txt"
XCODE_BUILD="$(xcodebuild -version 2>/dev/null | awk '/Build version/ {print $3}')"
xcrun appintentsmetadataprocessor \
  --output "$APPEX/Contents/Resources" \
  --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name StockmoteWidget \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
  --xcode-version "${XCODE_BUILD:-27B52}" \
  --platform-family macOS \
  --deployment-target 14.0 \
  --target-triple "$(uname -m)-apple-macos14.0" \
  --source-file-list "$META/sources.txt" \
  --swift-const-vals-list "$META/consts.txt" \
  --binary-file "$BUILD_DIR/StockmoteWidget" 2>&1 | grep -v 'Starting\|Writing\|Metadata root' || true
[ -d "$APPEX/Contents/Resources/Metadata.appintents" ] \
  || { echo "Metadata.appintents blev ikke lavet — widget'en kan ikke konfigureres" >&2; exit 1; }

# Widget-udvidelser skal køre i sandbox. Netværk til Yahoo, og læseadgang til
# netop den mappe hvor appen lægger Widget.json (se WidgetShare.swift).
ENTITLEMENTS="$(mktemp -d)/widget.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>             <true/>
    <key>com.apple.security.network.client</key>          <true/>
    <key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
    <array><string>/Library/Application Support/Stockmote/</string></array>
</dict>
</plist>
PLIST

# Ad-hoc signering, indefra og ud: udvidelsen med sine entitlements, så
# appen. Appen selv har ingen sandbox, så den har fri netværksadgang.
echo "==> Signerer ad-hoc"
codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Færdig: $APP"

if [ "$INSTALL" -eq 1 ]; then
  # Den kørende kopi skal lukkes først, ellers ender vi med to ikoner i
  # menubaren og en halvt overskrevet bundle.
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  # Fortæl systemet om widget'en med det samme i stedet for ved næste scan.
  pluginkit -a "/Applications/$APP_NAME.app/Contents/PlugIns/StockmoteWidget.appex" 2>/dev/null || true
  echo "==> Installeret i /Applications/$APP_NAME.app"
  TARGET="/Applications/$APP_NAME.app"
else
  echo "    Installér den med:  ./Scripts/make-app.sh --install"
  TARGET="$APP"
fi

if [ "$OPEN" -eq 1 ]; then
  echo "==> Åbner $TARGET"
  # Lige efter at bundlen er udskiftet kan Launch Services stadig holde på den
  # gamle og svare -600 (procNotFound). Et enkelt genforsøg er nok.
  if ! open "$TARGET" 2>/dev/null; then
    sleep 2
    open "$TARGET"
  fi
fi
