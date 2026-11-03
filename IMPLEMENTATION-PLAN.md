# Implementation Plan

| Phase | Scope | Status |
|---|---|---|
| 0 Research | Toolchain, engine evaluation (RDP-BACKEND-DECISION.md), macOS 15 minimum, licensing | Done |
| 1 RDP foundation | RDPKit session with cert gate, NLA credentials, rendering, input, disconnect | Implemented; engine failure paths tested; **live sign-in not yet verified** |
| 2 App shell | Sidebar tree, overview table, tab strip, toolbar, inspector, editors, light/dark | Done |
| 3 Persistence & credentials | JSON inventory with migration, favorites, recent, search, Keychain, shared profiles, inheritance | Done |
| 4 Pro RDP experience | Multiple sessions, full screen/focus mode, dynamic resolution, clipboard, reconnect, typed errors | Implemented; needs live verification |
| 5 Advanced | `.rdp` import, JSON export/import, detachable windows, send-keys menu, metrics inspector | Done (first pass) |
| 6 Quality & release | Tests, docs, icon, signing script | Done for 0.1.0; live matrix pending |

## Next (in priority order)
1. Run the live test checklist (TESTING.md) against Windows Server 2025, Windows Server 2022 and Windows 11, then fix what it finds.
2. Session sign-out (logoff) and a configurable Ctrl+Alt+End shortcut.
3. Drive redirection settings (the engine supports it).
4. Split view of two sessions, and session thumbnails in the Overview.
5. Sandbox the app (network client, user-selected files), then notarized releases.
6. When required: a FreeRDP-based backend for RD Gateway and Kerberos hosts, behind the existing `RemoteSession` seam.
