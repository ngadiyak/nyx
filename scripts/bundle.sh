#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/Nyx.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Nyx "$APP/Contents/MacOS/Nyx"
cp Resources/Info.plist "$APP/Contents/"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
# The shell integration scripts; -R because the zsh shim is a directory of dotfiles.
cp -R Resources/shell-integration "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built $APP"
