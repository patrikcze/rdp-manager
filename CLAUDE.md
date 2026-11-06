# CLAUDE.md

Native macOS RDP and SSH manager. Swift 6 (language mode 6), SwiftUI + AppKit, two RDP engines: RDPKit 0.7.0 (Swift) and FreeRDP 3.32.2 (C, through `Sources/FreeRDPBridge`); SSH runs `/usr/bin/ssh` on a PTY rendered by SwiftTerm 1.99.2. SwiftPM only, with no .xcodeproj.

## Commands
- `Scripts/build-freerdp.sh` must have run once (creates `ThirdParty/freerdp`; needs Homebrew `openssl@3 krb5 libusb cjson cmake ninja pkgconf`).
- `swift build` builds everything.
- `Scripts/make-dmg.sh` builds the distributable DMG. Versions come from git tags (`Scripts/version.sh`); never hard-code one.
- Releases: `Scripts/tag-release.sh X.Y.Z --push` after the CHANGELOG section is dated; `.github/workflows/release.yml` publishes the DMG. CI (`ci.yml`) must pass on PRs. See RELEASING.md.
- Live engine tests: `RDPM_LIVE_HOST=… RDPM_LIVE_USER=… RDPM_LIVE_PASSWORD=… swift test --filter LiveFreeRDP`. Never write credentials to files.
- `swift test` must pass before you finish (unit + engine integration tests).
- `Scripts/build-app.sh [debug]` produces `build/RDP Manager.app`, ad-hoc signed.
- Launch for UI checks: `open "build/RDP Manager.app" --args -SampleLibraryInMemory [-QuickConnect host:port]`. The window title is the selected session's name, not always "RDP Manager".
- `swift Scripts/render-icon.swift` regenerates the icon.

## Layout
- `Sources/RDPManagerCore`: models, inventory store, persistence, Keychain, import/export, session policy. No UI or RDPKit imports here. Put testable logic here.
- `Sources/RDPManager/Backend`: the only code that touches an engine. `RemoteSession` is engine-neutral, and engines implement `SessionEngine`. `SessionEndMapping` (RDPKit) and `FreeRDPEndMapping` (FreeRDP) are the only places that interpret engine failures. `EngineChoice` in core decides which engine runs.
- `Sources/FreeRDPBridge`: the C API over FreeRDP. Keep FreeRDP types out of Swift.
- `Sources/RDPManager/Backend/SSH`: SSH sessions. `SSHTransport` is the only seam (one implementation, OpenSSH). `SSHEndMapping` and `SSHPromptClassifier`/`SSHSecretPolicy` (core) are the only places that interpret ssh's end and its prompts. `Workspace.sessions` is `[WorkspaceSession]` (RDP or SSH).
- `Sources/RDPManagerAskpass`: the askpass helper. It only relays; never give it logic or Keychain access.
- `Sources/RDPManager/Features/*`: SwiftUI views, one folder per feature.
- Tests use Swift Testing (`import Testing`). Engine tests use `@testable import RDPManager`.

## Rules
- Never store passwords anywhere but the Keychain (`SecretStore`). Never log them. Exports never include them.
- Never set `hideCertificateWarnings` or `legacyCredSSP`, and never auto-trust a certificate. The FreeRDP bridge must keep answering certificates only with accept-once or reject; the app's trust store decides.
- Standard RDP Security and device redirection are opt-in only; never enable them by default or as an automatic fallback.
- Bundled libraries must stay inside `Contents/Frameworks`; `Scripts/build-app.sh` fails if anything references a build-machine path. Keep that check.
- Automatic retries go through `ReconnectPolicy` only: network failures of a session that showed the desktop, and bounded. Never retry authentication failures.
- Status shown in the UI must come from real session state or engine measurements. Never invent metrics or "online" status.
- Keychain calls run off the main actor (`CredentialService`). RDPKit's blocking `run` stays inside `RDPLiveSession`.
- `InventoryStore.mutate` edits a copy, so closures may read the store. Keep it that way, because the exclusivity crash is easy to reintroduce.
- Keep RDPKit pinned with `exact:`. Read its CHANGELOG for breaking changes before bumping.
- Update KNOWN-LIMITATIONS.md and TESTING.md when you change what works or what was verified. Don't mark anything PASS without evidence.
- SSH: start ssh only by exact path with an argument array, never through a shell; validate every value through `SSHCommandBuilder`. Never put secrets in arguments or the environment, never use `StrictHostKeyChecking=no`/`accept-new` or `UserKnownHostsFile=/dev/null`, never accept a host key without the user, never answer a prompt from the Keychain except through `SSHSecretPolicy`. Agent forwarding and Kerberos delegation stay off by default. Imports never bring startup commands, agent forwarding, delegation or SendEnv. Remote output never acts on the Mac without the user (OSC 52 off by default, links only on click).
- SSH tests run against a throwaway local sshd (`SSHLocalServerTests`) with `-F` and a temporary known_hosts; never touch `~/.ssh` in tests.
- Keep SwiftTerm pinned with `exact:`.
- Commit style: imperative subject, with body explaining why.
