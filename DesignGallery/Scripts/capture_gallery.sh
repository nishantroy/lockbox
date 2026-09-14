#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/DesignGallery.xcodeproj"
DERIVED="$ROOT/.build-gallery"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Lockbox Gallery.app"
DEVICE="${GALLERY_DEVICE:-4BA393D9-E104-4BEB-8EFB-3D0A1C513FFE}"
BUNDLE="com.phone-lockbox.design-gallery"
OUT="$ROOT/Reference"

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b
xcodebuild -project "$PROJECT" -scheme DesignGallery -destination "platform=iOS Simulator,id=$DEVICE" -configuration Debug -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build
xcrun simctl install "$DEVICE" "$APP"
mkdir -p "$OUT"
for theme in midnight circadian lantern; do
  for fixture in home rest focus; do
    name="${theme}_${fixture}"
    xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
    xcrun simctl launch "$DEVICE" "$BUNDLE" -gallery-theme "$theme" -gallery-fixture "$fixture" >/dev/null
    sleep 2
    xcrun simctl io "$DEVICE" screenshot "$OUT/${name}.png"
  done
done
