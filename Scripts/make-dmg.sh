#!/bin/zsh
# Packages "RDP Manager.app" as a drag-to-Applications disk image.
#   Scripts/make-dmg.sh                         ad-hoc: runs on Macs after right-click › Open
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=<profile> Scripts/make-dmg.sh
#                                               signed, notarized and stapled for distribution
# NOTARY_PROFILE is a notarytool keychain profile: xcrun notarytool store-credentials <profile>
# The version comes from the git tag (Scripts/version.sh); VERSION=1.2.3 overrides it.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
FULL_VERSION="$(Scripts/version.sh --full)"

SIGN_IDENTITY="$SIGN_IDENTITY" Scripts/build-app.sh release

APP="build/RDP Manager.app"
DMG="${DMG:-build/RDP-Manager-${FULL_VERSION//+/-}.dmg}"
STAGING="build/dmg-staging"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "RDP Manager $FULL_VERSION" -srcfolder "$STAGING" -ov -format UDZO -fs APFS "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  else
    echo "Signed but not notarized: set NOTARY_PROFILE to notarize."
  fi
fi
hdiutil verify "$DMG" >/dev/null
echo "Created $DMG ($(du -h "$DMG" | cut -f1)), signed with '$SIGN_IDENTITY'"
