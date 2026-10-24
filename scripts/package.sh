#!/bin/sh
# Build SlideScroll.app and package it for release in build/dist: a
# drag-to-Applications disk image and a zip of the app.
#
# With SIGN_IDENTITY set, the app and the disk image are signed with it.
# With NOTARY_PROFILE also set (a keychain profile saved by
# `xcrun notarytool store-credentials`), the disk image is notarized and the
# ticket stapled, so Gatekeeper opens it without warnings.
set -eu

cd "$(dirname "$0")/.."
VERSION=$(cat VERSION)
APP=build/SlideScroll.app
DIST=build/dist
DMG="$DIST/SlideScroll-$VERSION.dmg"
ZIP="$DIST/SlideScroll-$VERSION.zip"

scripts/bundle.sh

rm -rf "$DIST"
mkdir -p "$DIST"
STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/SlideScroll.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SlideScroll $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    case "$SIGN_IDENTITY" in
        "Developer ID"*) stamp=--timestamp ;;
        *) stamp=--timestamp=none ;;
    esac
    codesign --force "$stamp" --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        xcrun stapler staple "$APP"
    fi
fi

# Zipped after stapling, so the zip carries the ticket too.
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "SlideScroll-$VERSION.dmg" "SlideScroll-$VERSION.zip" > SHA256SUMS)
echo "Packaged $DMG and $ZIP"
