#!/bin/sh
# Render scripts/icon.swift into assets/AppIcon.png and assets/AppIcon.icns.
set -eu

cd "$(dirname "$0")/.."
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET" assets
swift scripts/icon.swift assets/AppIcon.png 1024
for size in 16 32 128 256 512; do
    sips -z $size $size assets/AppIcon.png --out "$SET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double assets/AppIcon.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "Wrote assets/AppIcon.png and assets/AppIcon.icns"
