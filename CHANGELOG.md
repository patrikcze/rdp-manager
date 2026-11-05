# Changelog

## 0.3.1 (unreleased)
- Search results show in the main table instead of replacing the sidebar. Swapping the sidebar left stale rows drawn over it, or an empty Connections section, after the search was cleared.
- Fix: the Delete key deleted the selected connection, and its saved password, without asking. Deleting connections now always asks first, from the keyboard and both context menus.

## 0.3.0 (2026-11-05)
First published release. It includes everything planned for 0.2.0, which was never released on its own.

- GitHub Actions: CI runs a secrets scan, script and workflow checks, then builds, tests and packages the DMG on every PR. Pushing a `v*` tag publishes the DMG and its SHA-256 on GitHub Releases, Developer ID signed and notarized when the signing secrets are set.
- The app version comes from git tags (`Scripts/version.sh`); the About panel shows the full version, including pre-release and dev suffixes. `Scripts/tag-release.sh` tags a release after checking `master` and the CHANGELOG.
- Security fixes from the 2026-11-04 review:
  - FreeRDP: clipboard and display calls hold the bridge lock, so a server disconnect can't free a channel mid-call.
  - FreeRDP: server-chosen desktop and graphics surface sizes are capped (8192 a side, 8192 × 4608 pixels); a larger desktop ends the session as "Desktop too large", a larger surface is refused. No force-unwrapped frame allocation.
  - FreeRDP: turning clipboard sharing off forgets the offered Mac text and refuses later server requests.
  - Library import removes Standard RDP Security, the shared folder, printers, smart cards, microphone, USB devices and KDC proxy, and lists what it removed.
  - Standard RDP Security needs a confirmation before any password is used. The connection inspector shows the security layer and what is shared with the server.
  - A certificate the user trusted is a pin on both engines, even against a replacement macOS trusts.
- Fix: an unreadable library is never overwritten, and Remove Unused Passwords is disabled until it can be read.
- Fix: the certificate trust file is owner-only (0600 in a 0700 folder); sample mode keeps trust in memory.
- Fix: `.rdp` import says what it reads instead of "Every setting was imported".
- `Scripts/build-freerdp.sh` builds only from an unmodified FreeRDP checkout.
- FreeRDP 3.32.2 as a second engine, chosen per connection, with:
  - Kerberos (NTLM fallback or Kerberos only, KDC proxy)
  - opt-in Standard RDP Security
  - redirection of printers (CUPS), smart cards and YubiKeys (PC/SC), microphone and USB devices (by vendor:product ID)
  - text clipboard, remote cursor shapes and dynamic resolution
- Shared folder redirection on both engines.
- Sign Out of Windows (through Run → `logoff`, with confirmation) alongside Disconnect.
- Session commands in the right-click menus of the sidebar, the Overview table and the session tabs: Show Session, Reconnect, Disconnect, Send Ctrl+Alt+Del, Sign Out of Windows… and Close Session, with a submenu per session when a connection has several.
- Ctrl+Option+End sends Ctrl+Alt+Del on both engines.
- Settings editor sections for Security, Devices and Engine, with inheritance and an engine summary. The inspector shows the engine, the security layer and redirected devices.
- Self-contained app bundle: FreeRDP, OpenSSL, Kerberos, libusb and cJSON bundled and relinked; license texts included. `Scripts/make-dmg.sh` builds a DMG, signed and notarized with a Developer ID.
- Fix: the main window comes back after restoration or a Dock click when none is open.
- Fix: the inspector shows the TLS version during a live session.
- Fix: typing into the remote session is paced, so Windows no longer drops characters.
- Export as .rdp File… in the sidebar and Overview menus: one connection with its effective settings, readable by Microsoft's clients. No password; the shared folder path, USB devices and Kerberos settings stay out, and the app says so.

## 0.1.0 (not released)
- First version: a connection library with nested groups and inheritance, Quick Connect, tabbed and detachable RDP sessions on RDPKit 0.7.0, Keychain credentials and shared credential profiles, certificate trust prompts, bounded reconnect, `.rdp` import, JSON library export and import, an inspector with measured session metrics, and an app icon.
