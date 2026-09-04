#!/bin/bash
# Renders the app icon and packs it into Resources/AppIcon.icns.
# The .icns is committed so a plain `scripts/bundle.sh` needs no extra step; re-run this only when
# scripts/make_icon.swift changes.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make_icon.swift "$WORK"
# iconutil wants this exact naming; the @2x entries are the next size up.
cp "$WORK/icon_16.png"   "$ICONSET/icon_16x16.png"
cp "$WORK/icon_32.png"   "$ICONSET/icon_16x16@2x.png"
cp "$WORK/icon_32.png"   "$ICONSET/icon_32x32.png"
cp "$WORK/icon_64.png"   "$ICONSET/icon_32x32@2x.png"
cp "$WORK/icon_128.png"  "$ICONSET/icon_128x128.png"
cp "$WORK/icon_256.png"  "$ICONSET/icon_128x128@2x.png"
cp "$WORK/icon_256.png"  "$ICONSET/icon_256x256.png"
cp "$WORK/icon_512.png"  "$ICONSET/icon_256x256@2x.png"
cp "$WORK/icon_512.png"  "$ICONSET/icon_512x512.png"
cp "$WORK/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil --convert icns --output Resources/AppIcon.icns "$ICONSET"
echo "wrote Resources/AppIcon.icns"
