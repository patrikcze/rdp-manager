# Changelog

## 0.2.0 (unreleased)
- FreeRDP 3.32.2 as a second engine, chosen per connection, with:
  - Kerberos (NTLM fallback or Kerberos only, KDC proxy)
  - opt-in Standard RDP Security
  - redirection of printers (CUPS), smart cards and YubiKeys (PC/SC), microphone and USB devices (by vendor:product ID)
  - text clipboard, remote cursor shapes and dynamic resolution
- Shared folder redirection on both engines.
- Sign Out of Windows (through Run → `logoff`, with confirmation) alongside Disconnect.
- Ctrl+Option+End sends Ctrl+Alt+Del on both engines.
- Settings editor sections for Security, Devices and Engine, with inheritance and an engine summary. The inspector shows the engine, the security layer and redirected devices.
- Self-contained app bundle: FreeRDP, OpenSSL, Kerberos, libusb and cJSON bundled and relinked; license texts included. `Scripts/make-dmg.sh` builds a DMG, signed and notarized with a Developer ID.
- Fix: the main window comes back after restoration or a Dock click when none is open.
- Fix: the inspector shows the TLS version during a live session.
- Fix: typing into the remote session is paced, so Windows no longer drops characters.

## 0.1.0 (unreleased)
- First version: a connection library with nested groups and inheritance, Quick Connect, tabbed and detachable RDP sessions on RDPKit 0.7.0, Keychain credentials and shared credential profiles, certificate trust prompts, bounded reconnect, `.rdp` import, JSON library export and import, an inspector with measured session metrics, and an app icon.
