#!/bin/zsh
# Builds the FreeRDP 3 libraries RDP Manager links for Kerberos, Standard RDP Security and
# device redirection (printers, smart cards, USB). Output: ThirdParty/freerdp (gitignored).
#   Scripts/build-freerdp.sh
# Needs: Xcode command line tools, cmake, ninja, and Homebrew openssl@3 krb5 libusb cjson.
set -euo pipefail

FREERDP_TAG="3.32.2"   # Pinned; review FreeRDP security advisories before bumping.
ROOT="${0:A:h:h}"
THIRD="$ROOT/ThirdParty"
SRC="$THIRD/FreeRDP-src"
BUILD="$THIRD/FreeRDP-build"
PREFIX="$THIRD/freerdp"
BREW="$(brew --prefix)"

for formula in openssl@3 krb5 libusb cjson; do
  [[ -d "$BREW/opt/$formula" ]] || { echo "Missing Homebrew formula: $formula (brew install $formula)"; exit 1; }
done

if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch "$FREERDP_TAG" https://github.com/FreeRDP/FreeRDP.git "$SRC"
fi
[[ "$(git -C "$SRC" describe --tags)" == "$FREERDP_TAG" ]] || { echo "FreeRDP checkout is not $FREERDP_TAG"; exit 1; }

# Local patches (e.g. serial port support on macOS) live next to this script.
for patch in "$ROOT"/Scripts/freerdp-patches/*.patch(N); do
  if git -C "$SRC" apply --check "$patch" 2>/dev/null; then
    git -C "$SRC" apply "$patch"
    echo "Applied $(basename "$patch")"
  fi
done

export PKG_CONFIG_PATH="$BREW/opt/krb5/lib/pkgconfig:$BREW/opt/libusb/lib/pkgconfig:$BREW/opt/cjson/lib/pkgconfig:$BREW/opt/openssl@3/lib/pkgconfig"

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF -DWITH_VERBOSE_WINPR_ASSERT=OFF \
  -DWITH_CLIENT=ON -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT_CHANNELS=ON \
  -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_SDL=OFF -DWITH_CLIENT_SDL2=OFF -DWITH_CLIENT_SDL3=OFF \
  -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF \
  -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF -DWITH_MANPAGES=OFF -DWITH_WINPR_TOOLS=OFF \
  -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_DSP_FFMPEG=OFF -DWITH_CAIRO=OFF -DWITH_OPENH264=OFF \
  -DWITH_FUSE=OFF -DWITH_PULSE=OFF -DWITH_ALSA=OFF -DWITH_OSS=OFF -DWITH_URIPARSER=OFF \
  -DWITH_WEBVIEW=OFF -DWITH_AAD=OFF \
  -DWITH_OPUS=OFF -DWITH_FAAD2=OFF -DWITH_FAAC=OFF -DWITH_LAME=OFF -DWITH_SOXR=OFF -DWITH_GSM=OFF \
  -DWITH_KRB5=ON -DWITH_KRB5_NO_NTLM_FALLBACK=OFF -DKRB5_ROOT_CONFIG="$BREW/opt/krb5/bin/krb5-config" \
  -DWITH_PCSC=ON -DWITH_SMARTCARD_EMULATE=OFF \
  -DWITH_CUPS=ON -DCHANNEL_PRINTER=ON -DCHANNEL_SMARTCARD=ON -DCHANNEL_DRIVE=ON \
  -DCHANNEL_URBDRC=ON -DCHANNEL_SERIAL=ON -DCHANNEL_PARALLEL=OFF \
  -DWITH_CJSON_REQUIRED=ON \
  -DOPENSSL_ROOT_DIR="$BREW/opt/openssl@3"

cmake --build "$BUILD"
cmake --install "$BUILD"
echo "FreeRDP $FREERDP_TAG installed in $PREFIX"
