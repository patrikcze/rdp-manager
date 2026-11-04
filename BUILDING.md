# Building

Requirements:

- macOS 15 or later on Apple Silicon, Xcode 16 or later (developed with Xcode 27.2 / Swift 6.4.2).
- For the FreeRDP engine: Homebrew with `cmake ninja pkgconf openssl@3 krb5 libusb cjson`.

```bash
brew install cmake ninja pkgconf openssl@3 krb5 libusb cjson
Scripts/build-freerdp.sh         # once: FreeRDP 3.32.2 into ThirdParty/freerdp (~5 min)
swift build                      # debug build of everything
swift test                       # tests
Scripts/build-app.sh             # release "build/RDP Manager.app", libraries bundled, ad-hoc signed
Scripts/make-dmg.sh              # build/RDP-Manager-<version>.dmg
```

`ThirdParty/` (FreeRDP source, build and install) is not checked in. `Scripts/build-freerdp.sh` recreates it from the pinned tag and applies any patches in `Scripts/freerdp-patches/`.

**Xcode:** run `open Package.swift`, choose the `RDPManager` scheme and "My Mac", then press ⌘R (after `Scripts/build-freerdp.sh`).

**Launch arguments:**

- `-SampleLibraryInMemory`: demo library, nothing saved.
- `-QuickConnect host[:port]`: opens a session at launch.
- `-Engine rdpKit|freeRDP`, `-Security automatic|nla|tls|standardRDP`, `-Authentication ntlm|kerberos|kerberosOnly`, `-Printers`, `-SmartCards`: apply to that Quick Connect session.
- `-Show …`, `-RunInSession …`: debug builds only (screenshots, live tests).

**App icon:** `swift Scripts/render-icon.swift`.

## What the app bundle contains

`Scripts/build-app.sh` copies FreeRDP (`libfreerdp3`, `libfreerdp-client3`, `libwinpr3`) and its dependencies into `Contents/Frameworks`: OpenSSL 3, MIT Kerberos, libusb and cJSON. It relinks them to `@rpath`, removes build-machine search paths, and fails if any binary still points outside the bundle. It then signs everything inside out. License texts go in `Contents/Resources/Licenses`. CUPS and PC/SC come with macOS.

## Signing and distribution

- **Ad-hoc (default):** runs on this Mac. Other Macs need right-click › Open the first time. Library validation is turned off for ad-hoc builds only, because ad-hoc signatures have no team.
- **Developer ID:** every binary is signed by your team, and library validation stays on.

```bash
xcrun notarytool store-credentials rdpm-notary      # once
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=rdpm-notary VERSION=0.2.0 Scripts/make-dmg.sh
```

This produces a signed, notarized and stapled DMG that opens on any Apple Silicon Mac running macOS 15 or later.
