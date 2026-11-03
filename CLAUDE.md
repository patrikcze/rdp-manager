# CLAUDE.md

Native macOS RDP manager. Swift 6 (language mode 6), SwiftUI + AppKit, RDPKit 0.7.0 engine. SwiftPM only, with no .xcodeproj.

## Commands
- `swift build` builds everything.
- `swift test` must pass before you finish (unit + engine integration tests).
- `Scripts/build-app.sh [debug]` produces `build/RDP Manager.app`, ad-hoc signed.
- Launch for UI checks: `open "build/RDP Manager.app" --args -SampleLibraryInMemory [-QuickConnect host:port]`. The window title is the selected session's name, not always "RDP Manager".
- `swift Scripts/render-icon.swift` regenerates the icon.

## Layout
- `Sources/RDPManagerCore`: models, inventory store, persistence, Keychain, import/export, session policy. No UI or RDPKit imports here. Put testable logic here.
- `Sources/RDPManager/Backend`: the only code that touches RDPKit. `SessionEndMapping` is the single place that interprets `RDPConnectionFailure`.
- `Sources/RDPManager/Features/*`: SwiftUI views, one folder per feature.
- Tests use Swift Testing (`import Testing`). Engine tests use `@testable import RDPManager`.

## Rules
- Never store passwords anywhere but the Keychain (`SecretStore`). Never log them. Exports never include them.
- Never set `hideCertificateWarnings` or `legacyCredSSP`, and never auto-trust a certificate.
- Automatic retries go through `ReconnectPolicy` only: network failures of a session that showed the desktop, and bounded. Never retry authentication failures.
- Status shown in the UI must come from real session state or engine measurements. Never invent metrics or "online" status.
- Keychain calls run off the main actor (`CredentialService`). RDPKit's blocking `run` stays inside `RDPLiveSession`.
- `InventoryStore.mutate` edits a copy, so closures may read the store. Keep it that way, because the exclusivity crash is easy to reintroduce.
- Keep RDPKit pinned with `exact:`. Read its CHANGELOG for breaking changes before bumping.
- Update KNOWN-LIMITATIONS.md and TESTING.md when you change what works or what was verified. Don't mark anything PASS without evidence.
- Commit style: imperative subject, with body explaining why.
