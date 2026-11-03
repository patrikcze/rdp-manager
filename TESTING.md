# Testing

```bash
swift test                                  # unit + engine integration tests
RDPM_KEYCHAIN_TESTS=1 swift test            # also round-trips a real login-Keychain item
```

## Automated suites

| Suite | What it covers |
|---|---|
| `RDPManagerCoreTests/HostAddressTests` | Quick Connect parsing: host, host:port, IPv4/IPv6, rdp:// prefixes, invalid input |
| `RDPManagerCoreTests/InventoryStoreTests` | nested groups, reorder, move-cycle prevention, delete group keep/delete contents, settings inheritance and its sources, credential deletion clears references, orphaned Keychain accounts, search, persistence round trip with 0600 permissions, newer schema refused |
| `RDPManagerCoreTests/ImportExportTests` | UTF-16 `.rdp` import, warnings for unsupported settings, library export without passwords or history, identifier remapping on import, invalid archives |
| `RDPManagerCoreTests/SessionPolicyTests` | bounded reconnect with backoff, no retry for auth/cert/server failures, credential plans, secret store |
| `RDPEngineIntegrationTests/EngineFailureTests` | **real RDPKit runs**: refused port → network failure, not retried; non-RDP service → "No Remote Desktop service"; silent server → bounded timeout; wrong password → re-prompt, never retried |

Last run (2026-11-03, macOS 27.2, Xcode 27.2, Swift 6.4.2, Apple Silicon): **32 tests passed**.

## Functional test matrix

| Scenario | Result | Evidence / notes |
|---|---|---|
| App builds as `.app`, launches | PASS | `Scripts/build-app.sh`, launched and screenshotted |
| Saved groups/hosts shown, expandable, persist | PASS | sample library screenshot; persistence unit tests |
| Quick Connect opens a tab and asks to sign in | PASS | `-QuickConnect 127.0.0.1:3399` launch, screenshot |
| Unreachable host / wrong service / timeout | PASS | engine integration tests |
| Incorrect password → clear error, no retry loop | PASS (logic) | mapping + policy tests; NOT TESTED live |
| Delete group → predictable handling | PASS | unit tests + confirmation dialog |
| Restart application → profiles restored | PASS | persistence round-trip test |
| Windows Server 2025 connection | NOT TESTED | no host available |
| Windows Server 2022 connection | NOT TESTED | no host available |
| Windows 11 connection | NOT TESTED | no host available |
| Invalid certificate → warning and trust decision | NOT TESTED live | code path in `RemoteSession.received` |
| Multiple sessions independent | NOT TESTED live | separate engine, canvas and state per session by construction |
| Window resize / fullscreen | NOT TESTED live | |
| Keyboard shortcuts (⌘R → Win+R, Czech layout) | NOT TESTED live | RDPKit's input view |
| Clipboard both directions | NOT TESTED live | |
| Network interruption → reconnect | NOT TESTED live | policy unit-tested |
| Credential reuse via shared profile | PASS (logic) | inheritance + plan tests |

## Live testing checklist
1. Enable Remote Desktop on a Windows host (Settings › System › Remote Desktop) with NLA on.
2. `Scripts/build-app.sh && open "build/RDP Manager.app"`
3. Quick Connect to the host, sign in with "Save password" on, and check that the desktop appears and that input works.
4. Resize the window and move it to another display. The remote resolution should follow after about 0.4 s.
5. Copy text both ways, and test ⌘R (Win+R) and Session › Send Keys › Ctrl+Alt+Del.
6. Disable Wi-Fi for 10 s: the tab should show "Reconnecting (1/3)" and recover.
7. Enter a wrong password: you should be asked again, with no loop.
8. Regenerate the server certificate: the app should show "The Certificate Has Changed".

Record results in the matrix above with the Windows build, network type and date.

To check the UI without touching your library, launch with `-SampleLibraryInMemory`. This loads the sample library into memory and uses an in-memory secret store.
