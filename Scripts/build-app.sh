#!/bin/zsh
# Builds RDP Manager.app from the Swift package.
#   Scripts/build-app.sh [debug|release]      (default: release)
# Environment:
#   SIGN_IDENTITY   codesign identity (default "-": ad-hoc, runs only on this Mac)
#   VERSION, BUILD  bundle versions (default 0.1.0 / git commit count)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="${0:A:h:h}"
cd "$ROOT"

VERSION="${VERSION:-0.2.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/RDPManager"

APP="build/RDP Manager.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RDPManager"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Bundle FreeRDP and every non-system library it pulls in (OpenSSL, Kerberos, libusb, cJSON),
# relinked to load from Contents/Frameworks, so the app needs nothing from Homebrew or the
# build folder at runtime.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
FREERDP_LIB="$ROOT/ThirdParty/freerdp/lib"
[[ -d "$FREERDP_LIB" ]] || { echo "FreeRDP is not built: run Scripts/build-freerdp.sh"; exit 1; }

non_system_deps() { # prints absolute dependency paths that must be bundled
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E "^(/opt/homebrew|/usr/local|$ROOT)" || true
}
bundle() { # copy one library (resolving symlinks) under its referenced file name
  local src="$1" name="${1:t}"
  [[ -f "$FRAMEWORKS/$name" ]] && return
  cp -L "$src" "$FRAMEWORKS/$name"
  chmod u+w "$FRAMEWORKS/$name"
  install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name"
  for dep in $(non_system_deps "$src"); do bundle "$dep"; done
}
for lib in libwinpr3.3.dylib libfreerdp3.3.dylib libfreerdp-client3.3.dylib; do
  bundle "$FREERDP_LIB/$lib"
done
# Point every reference at the bundled copies.
for file in "$APP/Contents/MacOS/RDPManager" "$FRAMEWORKS"/*.dylib; do
  for dep in $(otool -L "$file" | tail -n +2 | awk '{print $1}' | grep -E "^(/opt/homebrew|/usr/local|$ROOT|@rpath)"); do
    install_name_tool -change "$dep" "@rpath/${dep:t}" "$file" 2>/dev/null || true
  done
done
for lib in "$FRAMEWORKS"/*.dylib; do
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
# Swift's back-deployment shim: in the OS from macOS 26, bundled for macOS 15.
SPAN_LIB="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx/libswiftCompatibilitySpan.dylib"
if otool -L "$APP/Contents/MacOS/RDPManager" | grep -q libswiftCompatibilitySpan && [[ -f "$SPAN_LIB" ]]; then
  cp "$SPAN_LIB" "$FRAMEWORKS/"
fi
# Drop build-machine search paths from the executable; system ones (/usr/lib/swift) stay.
for rpath in $(otool -l "$APP/Contents/MacOS/RDPManager" | awk '/LC_RPATH/{getline;getline;print $2}' | grep -E "^($ROOT|/opt/homebrew|/usr/local|/Applications/Xcode)"); do
  install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/RDPManager"
done
if otool -L "$APP/Contents/MacOS/RDPManager" "$FRAMEWORKS"/*.dylib | grep -E "/opt/homebrew|/usr/local|$ROOT"; then
  echo "A bundled binary still references a build-machine path"; exit 1
fi
cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
# Full license texts of the bundled libraries, as their licenses require.
LICENSES="$APP/Contents/Resources/Licenses"
mkdir -p "$LICENSES"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
for pair in "FreeRDP:$ROOT/ThirdParty/FreeRDP-src/LICENSE" "OpenSSL:$BREW/opt/openssl@3/LICENSE.txt" \
            "MIT-Kerberos:$BREW/opt/krb5/NOTICE" "libusb:$BREW/opt/libusb/COPYING" "cJSON:$BREW/opt/cjson/LICENSE"; do
  [[ -f "${pair#*:}" ]] && cp "${pair#*:}" "$LICENSES/${pair%%:*}.txt"
done

# Sign inside out: libraries first, then the app.
for lib in "$FRAMEWORKS"/*.dylib; do
  codesign --force --options runtime $( [[ "$SIGN_IDENTITY" == "-" ]] && echo --timestamp=none || echo --timestamp ) --sign "$SIGN_IDENTITY" "$lib"
done
# Library validation only loads libraries signed by the app's own team. Ad-hoc signatures have
# no team, so an ad-hoc build (local use only) must turn it off; a Developer ID build signs
# every library with the same team and keeps it on.
ENTITLEMENTS="Resources/RDPManager.entitlements"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  ENTITLEMENTS="build/RDPManager-adhoc.entitlements"
  cp Resources/RDPManager.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
TIMESTAMP="--timestamp=none"
[[ "$SIGN_IDENTITY" == "-" ]] || TIMESTAMP="--timestamp"
codesign --force --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($CONFIG, $VERSION ($BUILD), signed with '$SIGN_IDENTITY')"
