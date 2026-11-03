# Building

Requirements: macOS 15 or later on Apple Silicon, Xcode 16 or later (developed with Xcode 27.2 / Swift 6.4.2). No other tools are needed; SwiftPM fetches RDPKit and SwiftNIO.

```bash
swift build                      # debug build of everything
swift test                       # tests
Scripts/build-app.sh             # release "build/RDP Manager.app", ad-hoc signed
Scripts/build-app.sh debug       # debug app bundle
open "build/RDP Manager.app"
```

**Xcode:** run `open Package.swift`, choose the `RDPManager` scheme and "My Mac", then press ⌘R. Running the bare executable from Xcode works; the bundle (Info.plist, icon, local-network usage string) comes from `Scripts/build-app.sh`.

**Launch arguments (development):**

- `-SampleLibraryInMemory` uses a demo library and an in-memory password store.
- `-QuickConnect host[:port]` opens a session at launch.
- `-Show inspector|editor|group|credentials|none` (debug builds only) sets up the window for README screenshots, with the sample-mode banner hidden.

**App icon:** `swift Scripts/render-icon.swift` regenerates `Resources/AppIcon-1024.png` and `Resources/AppIcon.icns`.

## Signing and notarization

The script signs ad-hoc (`-`) with the hardened runtime. That runs on the build Mac only. To distribute:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" VERSION=0.1.0 Scripts/build-app.sh
ditto -c -k --keepParent "build/RDP Manager.app" build/RDPManager.zip
xcrun notarytool submit build/RDPManager.zip --keychain-profile <profile> --wait
xcrun stapler staple "build/RDP Manager.app"
```

The first connection to a host on the local network makes macOS ask for Local Network access (`NSLocalNetworkUsageDescription`). RDP Manager retries the TCP connect while macOS shows the prompt.
