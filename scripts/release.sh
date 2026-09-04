#!/bin/bash
#
# Builds a signed, notarised Nyx.app.
#
# Signing and notarisation need an Apple Developer account: a Developer ID Application certificate
# in the login keychain, and an app-specific password stored as a keychain profile. Neither can be
# faked, so this script checks for them first and says exactly what is missing rather than producing
# an artefact that looks shippable and is not.
#
#   xcrun notarytool store-credentials nyx-notary \
#       --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
#
#   NYX_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" ./scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Nyx.app"
PROFILE="${NYX_NOTARY_PROFILE:-nyx-notary}"

if [ -z "${NYX_SIGN_IDENTITY:-}" ]; then
    echo "NYX_SIGN_IDENTITY is not set."
    echo
    echo "Available signing identities:"
    security find-identity -v -p codesigning || true
    echo
    echo "Without a Developer ID certificate this build can only run on the machine that made it:"
    echo "Gatekeeper refuses an ad-hoc signature everywhere else. Use ./scripts/bundle.sh for that."
    exit 1
fi

echo "==> Building"
swift build -c release
./scripts/bundle.sh >/dev/null

echo "==> Signing as $NYX_SIGN_IDENTITY"
# --options runtime is the hardened runtime, which notarisation requires; --timestamp is a signed
# timestamp, without which the signature expires with the certificate.
codesign --force --deep --options runtime --timestamp \
         --entitlements Resources/Nyx.entitlements \
         --sign "$NYX_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarising"
ZIP="build/Nyx.zip"
rm -f "$ZIP"
# ditto rather than zip: it preserves the bundle's symlinks and extended attributes, and notarytool
# rejects an archive that has lost them.
ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait; then
    echo
    echo "Notarisation failed. If the profile is missing, create it with:"
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id <team> --password <app-specific>"
    exit 1
fi

# Stapling puts the notarisation ticket inside the bundle, so it opens on a machine that is offline.
echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo
echo "Signed and notarised: $APP"
spctl --assess --type execute --verbose=2 "$APP"
