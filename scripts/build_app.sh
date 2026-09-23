#!/bin/zsh
# build_app.sh — builds YuE2Mac.app with only Apple's Command Line Tools (no Xcode,
# no Apple ID, no admin). Compiles the Swift sources with swiftc, packages the
# bundle by hand (Info.plist, icon via iconutil, engine scripts), ad-hoc signs it.
#
#   zsh scripts/build_app.sh            # -> build/YuE2Mac.app
#   zsh scripts/build_app.sh --install  # also copies it to ~/Applications
set -e
cd "$(dirname "$0")/.."

VERSION="0.1.0-workstation"
SDK="$(xcrun --show-sdk-path)"
OUT="build"
APP="$OUT/YuE2Mac.app"
ICONSET="YuE2Mac/Assets.xcassets/AppIcon.appiconset"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"

echo "▸ Compiling…"
swiftc -O -sdk "$SDK" -target arm64-apple-macos13.0 -parse-as-library \
    -o "$APP/Contents/MacOS/YuE2Mac" $(find YuE2Mac -name '*.swift' | sort)

echo "▸ Icon…"
TMP="$(mktemp -d)"
mkdir "$TMP/AppIcon.iconset"
for pair in 16:icon_16_x1 32:icon_16_x2 32:icon_32_x1 64:icon_32_x2 128:icon_128_x1 \
            256:icon_128_x2 256:icon_256_x1 512:icon_256_x2 512:icon_512_x1 1024:icon_512_x2; do
    px="${pair%%:*}"; name="${pair#*:}"; base="${name%_x*}"; scale="${name##*_x}"
    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    size="${base#icon_}"
    # The asset catalog's "PNGs" are really JPEGs; iconutil needs genuine PNGs.
    sips -s format png "$ICONSET/icon_$px.png" --out "$TMP/AppIcon.iconset/icon_${size}x${size}${suffix}.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

echo "▸ Engine scripts and web resources…"
cp engine/*.py "$APP/Contents/Resources/engine/"
cp -R YuE2Mac/Resources/. "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>YuE2Mac</string>
    <key>CFBundleDisplayName</key><string>YuE2Mac</string>
    <key>CFBundleIdentifier</key><string>arinltte.YuE2Mac</string>
    <key>CFBundleExecutable</key><string>YuE2Mac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>YuE2Mac records a hummed or sung melody to turn into a song.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "✓ Built $APP"
if [ "$1" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/YuE2Mac.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "✓ Installed to ~/Applications/YuE2Mac.app"
fi
