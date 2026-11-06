# Testing

```bash
swift test                                  # unit + engine integration tests
RDPM_KEYCHAIN_TESTS=1 swift test            # also round-trips a real login-Keychain item
RDPM_LIVE_HOST=… RDPM_LIVE_USER=… RDPM_LIVE_PASSWORD=… swift test --filter LiveFreeRDP
```

Live tests read credentials only from the environment. Never put them in files.

## Automated suites

| Suite | What it covers |
|---|---|
| `RDPManagerCoreTests/HostAddressTests` | Quick Connect parsing: host, host:port, IPv4/IPv6, rdp:// prefixes, invalid input |
| `RDPManagerCoreTests/InventoryStoreTests` | Nested groups, reordering, move-cycle prevention, deleting groups with or without contents, settings inheritance and its sources, credential references, orphaned Keychain accounts, search, persistence (0600 permissions), newer schema refused |
| `RDPManagerCoreTests/ImportExportTests` | `.rdp` import and warnings, library export without passwords, identifier remapping, risky settings removed on library import |
| `RDPManagerCoreTests/UnreadableLibraryTests` | A damaged `inventory.json` is never overwritten; a missing one starts empty and saves |
| `RDPManagerCoreTests/RDPFileExportTests` | `.rdp` export: effective settings, `DOMAIN\user` from profiles, no password or Mac paths, no line injection, safe file names, round trip through the importer |
| `RDPManagerCoreTests/SessionPolicyTests` | Bounded reconnect, no retry for authentication/certificate/server failures, credential plans |
| `RDPManagerCoreTests/EngineChoiceTests` | Which engine each feature selects, forced engines and ignored settings, USB ID normalization, old libraries still decode |
| `RDPEngineIntegrationTests/EngineFailureTests` | Real RDPKit runs against local sockets: refused port, non-RDP service, silent server, wrong password |
| `RDPEngineIntegrationTests/FreeRDPEndMappingTests` | FreeRDP errors → re-prompt, sign-out, reconnect, Standard RDP refusal; PEM chains; wheel encoding; `DOMAIN\user` splitting |
| `RDPEngineIntegrationTests/FreeRDPBridgeSafetyTests` | Real C bridge (no network): clipboard revocation forgets offered text, resize without a channel is refused, desktop size limits, overflow-safe frame sizes |
| `RDPEngineIntegrationTests/CertificatePinTests` | A pinned certificate's replacement is refused as changed even when macOS trusts it; other hosts follow system trust; trust file is 0600/0700 |
| `RDPManagerCoreTests/SSH*Tests` | SSH migration and inheritance, Keychain references, ssh argument safety, log and end mapping, askpass prompt policy, Quick Connect, `~/.ssh/config` import (see docs/SSH-TESTING.md) |
| `RDPEngineIntegrationTests/SSHLocalServerTests` | Real OpenSSH sessions against a throwaway local sshd: host keys, key/agent/passphrase sign-in through askpass, resize, ProxyJump, timeouts, cancel, no leaks |
| `RDPEngineIntegrationTests/LiveFreeRDPTests` | Opt-in: real FreeRDP bridge sign-in (Auto, NLA), pixels arrive, certificate callback runs, wrong password fails authentication |

Last run (2026-11-07, macOS 27.2, Xcode 27.2, Swift 6.4.2, OpenSSH 10.5p1, Apple Silicon): **112 automated tests passed** (69 RDP and core tests from before SSH support, unchanged, plus 43 SSH tests). The 3 live tests passed against a Windows 11 VM on 2026-11-04 and were not rerun after the security fixes.

## Functional test matrix

| Scenario | Result | Evidence |
|---|---|---|
| App builds as `.app` and DMG, launches | PASS | `Scripts/make-dmg.sh`; launched from the mounted DMG with the local FreeRDP build hidden |
| Bundled libraries load from the app | PASS | `vmmap`: FreeRDP, OpenSSL, Kerberos, libusb, cJSON from `Contents/Frameworks` |
| Windows 11, RDPKit engine | PASS | 2026-11-04, Parallels VM, NLA, H.264 desktop (screenshot) |
| Windows 11, FreeRDP engine | PASS | 2026-11-04, NLA sign-in in the app, desktop rendered, Czech layout announced |
| Shared certificate trust across engines | PASS | Certificate trusted earlier on RDPKit accepted by FreeRDP |
| Printer redirection | PASS | `Get-Printer` in the session lists the Mac's HP printer "redirected by session 7", port TS001 |
| Smart card channel | PARTIAL | Session forwards smart card calls to the Mac; no reader attached on the Mac |
| Standard RDP Security | PARTIAL | Windows 11 (requires NLA) refuses it; app explains the refusal. Not tested against a server that allows it |
| Typing through Run (sign-out path) | PASS | Paced Unicode typing ran a full PowerShell command exactly |
| Incorrect password → clear error, no retry loop | PASS | Live FreeRDP test; mapping and policy tests |
| Unreachable host / wrong service / timeout | PASS | Engine integration tests |
| Saved groups/hosts, restart restores | PASS | Persistence tests, screenshots |
| Windows Server 2025 / 2022 | NOT TESTED | No host available |
| Kerberos | NOT TESTED | No domain available |
| USB, microphone | NOT TESTED | |
| Sign Out of Windows | NOT TESTED live | Same Run path as verified typing |
| Invalid/changed certificate prompt | NOT TESTED live | |
| Multiple sessions, resize, full screen | NOT TESTED live | |
| Control+C in a Windows app → Mac clipboard | PASS | 2026-11-04, both engines: Notepad, Control+A then Control+C sent as real macOS key events through the app; text arrived on the Mac clipboard |
| Clipboard Mac → Windows | NOT TESTED live | |
| Network interruption → reconnect | NOT TESTED live | Policy unit-tested |
| Server disconnect racing resize/clipboard (FreeRDP) | NOT TESTED live | Lock design checked against FreeRDP 3.32.2 teardown order; no AddressSanitizer stress run |
| Oversized server desktop (FreeRDP) | NOT TESTED live | Limits unit-tested; no malicious test server |
| Standard RDP confirmation dialog | NOT TESTED live | |

## Live testing checklist
1. `Scripts/build-app.sh && open "build/RDP Manager.app"`
2. Connect on each engine: set the connection's Engine to RDPKit, then to FreeRDP.
3. Resize the window and move it to another display. The resolution should follow after about 0.4 s.
4. Copy text both ways. Test ⌘R (Win+R) and Ctrl+Option+End (Ctrl+Alt+Del).
5. Plug in a YubiKey, enable Smart cards, connect, and run `certutil -scinfo` in the session.
6. Enable Printers and print a test page.
7. Session › Sign Out of Windows… should end with "Signed out".
8. Disable Wi-Fi for 10 s: the tab should show "Reconnecting (1/3)" and recover.
9. Enter a wrong password: you should be asked again, with no loop.

Debug builds accept `-QuickConnect host`, `-Engine rdpKit|freeRDP`, `-Security …`, `-Printers`, `-SmartCards`, `-RunInSession "command"` and `-SimulateKeys "h i ctrl+a ctrl+c"`. The last one posts real macOS key events through the app's input path. With `RDPM_LIVE_USER`/`RDPM_LIVE_PASSWORD` set, they answer the sign-in prompt. These hooks don't exist in release builds.
