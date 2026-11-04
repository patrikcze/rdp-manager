# Implementation Plan

| Phase | Scope | Status |
|---|---|---|
| 0 Research | Toolchain, engine evaluation (RDP-BACKEND-DECISION.md), macOS 15 minimum, licensing | Done |
| 1 RDP foundation | RDPKit session with cert gate, NLA credentials, rendering, input, disconnect | Done; verified live against Windows 11 |
| 2 App shell | Sidebar tree, overview table, tab strip, toolbar, inspector, editors, light/dark | Done |
| 3 Persistence & credentials | JSON inventory with migration, favorites, recent, search, Keychain, shared profiles, inheritance | Done |
| 4 Pro RDP experience | Multiple sessions, full screen/focus mode, dynamic resolution, clipboard, reconnect, typed errors | Implemented; needs live verification |
| 5 Advanced | `.rdp` import, JSON export/import, detachable windows, send-keys menu, metrics inspector | Done (first pass) |
| 6 Quality & release | Tests, docs, icon, signing script | Done for 0.1.0; live matrix pending |
| 7 FreeRDP engine | Kerberos, Standard RDP Security, printers, smart cards, microphone, USB, sign-out, DMG packaging | Done; Kerberos, smart card, USB and microphone await live verification |

## Next (in priority order)
1. Live-verify a YubiKey (smart card redirection), USB, microphone and Kerberos against a domain, then fix what they find.
2. Serial port redirection: port FreeRDP's `winpr/comm` to macOS termios/IOKit as a patch in `Scripts/freerdp-patches/`.
3. Smart card logon and Entra ID sign-in (FreeRDP supports both; needs PIN prompt and browser sign-in UI).
4. H.264 for FreeRDP connections (OpenH264 or a VideoToolbox decoder in the bridge).
5. Multi-monitor layouts, split view and session thumbnails.
6. Explicit reachability checks for a group.
7. App Sandbox with network, USB, smart card, printing and audio-input entitlements.
