<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="RDP Manager icon"></p>

# RDP Manager

A native macOS Remote Desktop manager for administrators who look after many Windows servers. You can organize hosts in nested groups, find any of them instantly, and work in several RDP sessions side by side in tabs or separate windows.

Built with Swift 6, SwiftUI and AppKit on [RDPKit](https://github.com/steelbrain/RDPKit), a pure-Swift RDP engine with hardware H.264 decoding.

## Features
- **Connection library:** unlimited nested groups, drag and drop, inline rename, favorites, recent, color labels, tags, notes, and full-text search across names, hosts, tags and group paths.
- **Inheritance:** groups set defaults (credentials, display, clipboard, audio, reconnect, timeout) that hosts inherit or override. The UI shows where each value comes from.
- **Quick Connect (⌘K):** `host`, `host:port` or an IP address. You can save the connection afterwards.
- **Tabbed sessions:** many concurrent sessions, with state shown in the tabs. Tabs can be reordered, moved to their own window, and shown in focus mode or full screen.
- **Remote desktop:** the resolution follows the window at Retina scale, with H.264/AVC444 decoded by VideoToolbox. Your Mac keyboard layout is announced to Windows, ⌘ acts as the Windows key, and Ctrl+Alt+Del and other keys can be sent from a menu. Clipboard text and files work in both directions, and remote audio can play on the Mac.
- **Security:** passwords stay in the Keychain. Certificates are checked before any credential is sent, and changed certificates are flagged. NLA is always on, and there is no telemetry.
- **Reliability:** bounded automatic reconnect after network drops, never after sign-in or certificate failures. Errors are clear and explain what to do next.
- **Import and export:** Microsoft `.rdp` files (unsupported settings are reported), plus JSON library export and import without passwords.

## Quick start
```bash
Scripts/build-app.sh
open "build/RDP Manager.app"
```
Or open `Package.swift` in Xcode and run the `RDPManager` scheme. See [BUILDING.md](BUILDING.md).

## Status
Version 0.1.0. The app builds, launches and passes 32 automated tests, including real engine runs. **Sign-in to a live Windows host has not yet been verified**; see [TESTING.md](TESTING.md) and [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md). RD Gateway and Kerberos are not supported by the current engine.

## Documentation
[Architecture](ARCHITECTURE.md) · [Design](DESIGN.md) · [Backend decision](RDP-BACKEND-DECISION.md) · [Security](SECURITY.md) · [Testing](TESTING.md) · [Building](BUILDING.md) · [Limitations](KNOWN-LIMITATIONS.md) · [Plan](IMPLEMENTATION-PLAN.md) · [Changelog](CHANGELOG.md) · [Third-party notices](THIRD-PARTY-NOTICES.md)
