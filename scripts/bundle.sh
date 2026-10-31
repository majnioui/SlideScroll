#!/bin/sh
# Build SlideScroll.app in build/.
#
#   scripts/bundle.sh                          # ad-hoc signed, for this Mac
#   SIGN_IDENTITY="Developer ID Application: …" scripts/bundle.sh
#
# macOS ties the Accessibility permission to the app's signature. An ad-hoc
# signature changes with every build, so after rebuilding, remove SlideScroll
# from Privacy & Security → Accessibility and allow it again. A Developer ID
# signature keeps the permission across builds.
set -eu

cd "$(dirname "$0")/.."
BUNDLE_ID="${BUNDLE_ID:-com.majnioui.slidescroll}"
VERSION=$(cat VERSION)
APP=build/SlideScroll.app

# SWIFT_BUILD_FLAGS, e.g. --disable-sandbox when building inside another
# sandbox (Homebrew's), where SwiftPM can't start its own.
# shellcheck disable=SC2086
swift build -c release --product slidescroll ${SWIFT_BUILD_FLAGS:-}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path ${SWIFT_BUILD_FLAGS:-})/slidescroll" "$APP/Contents/MacOS/slidescroll"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SlideScroll</string>
    <key>CFBundleDisplayName</key>
    <string>SlideScroll</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>slidescroll</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>slidescroll</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Apple's timestamp service only stamps Apple-issued certificates; a
    # self-signed one signs without it.
    case "$SIGN_IDENTITY" in
        "Developer ID"*) stamp=--timestamp ;;
        *) stamp=--timestamp=none ;;
    esac
    codesign --force --options runtime "$stamp" --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, $BUNDLE_ID)"
