# RDP Backend Decision

**Decision (revised 2026-11-04): two engines behind one session controller.**

- **RDPKit 0.7.0** ([steelbrain/RDPKit](https://github.com/steelbrain/RDPKit), pure Swift, MIT) runs every connection it can.
- **FreeRDP 3.32.2** ([FreeRDP/FreeRDP](https://github.com/FreeRDP/FreeRDP), C, Apache-2.0) runs connections that need what only it has: Kerberos, Standard RDP Security, and printer, smart card, microphone and USB redirection.

Both versions are pinned exactly: RDPKit in `Package.swift`, FreeRDP in `Scripts/build-freerdp.sh`.

## Why two engines

The first version used RDPKit alone. The user requires Kerberos, Standard RDP Security, and printer, smart card (YubiKey), USB and serial redirection. RDPKit has none of these, and they can't be added from outside the library. FreeRDP 3 has them, except serial ports on macOS (see below). It costs software rendering, C code and bundled libraries. Keeping RDPKit for everything else preserves hardware H.264, VideoToolbox rendering and its memory-safe parser on most connections.

## Comparison

| | **RDPKit 0.7.0** | **FreeRDP 3.32.2** |
|---|---|---|
| Language / license | Swift 6 / MIT | C / Apache-2.0 |
| Maturity | Young (created 2026-06, single maintainer) | Mature, widely deployed, regular security advisories |
| NLA | NTLM | NTLM and Kerberos (MIT krb5) |
| Standard RDP Security | No (refused) | Yes |
| Graphics on Mac | RDPGFX with AVC420/AVC444 through VideoToolbox, zero-copy | GFX with RemoteFX/progressive, software GDI (no H.264 in our build) |
| Clipboard | Text, HTML, RTF, images, files | Text (our bridge) |
| Audio | Playback | Playback and microphone |
| Drives | Yes | Yes |
| Printers | No | Yes (CUPS: every Mac printer) |
| Smart cards | No | Yes (PC/SC: YubiKey PIV, card readers) |
| USB | No | Yes (urbdrc + libusb, by vendor:product ID) |
| Serial ports | No | **No on macOS** (FreeRDP disables it on Apple) |
| RD Gateway, RemoteApp | No | Yes (not used: not required) |
| Entra ID | No | Yes, with a browser sign-in flow (not built yet) |

## Engine choice

`EngineChoice` in `RDPManagerCore` (unit-tested) decides per connection:

- **Automatic:** RDPKit, unless the resolved settings ask for Standard RDP Security, Kerberos, printers, smart cards, microphone or USB. Then FreeRDP. The editor shows the result and why.
- **Forced:** a connection or group can force either engine. If RDPKit is forced, the session says which settings it ignores.

## Serial ports

FreeRDP's serial channel needs `winpr/comm`. FreeRDP doesn't build it on Apple platforms, because parts of it use Linux-only ioctls. Supporting serial means porting those parts to macOS `termios`/IOKit, which is planned as a patch applied by `Scripts/build-freerdp.sh` (`Scripts/freerdp-patches/`). Until then, serial redirection is unavailable.

## Integration

- **`Sources/FreeRDPBridge`:** a small C API (`rm_session_*`) over FreeRDP. Swift never sees FreeRDP's types. It covers connection, GDI framebuffer, pointer shapes, input, Display Control resize, text clipboard and the device channels.
- **`Backend/SessionEngine`:** the protocol both engines implement. `RemoteSession` keeps credentials, certificate decisions, reconnect policy and UI state for both.
- **Certificates:** one trust store. FreeRDP's own known-hosts store is never used: the bridge always answers "accept once" or "reject". RDP Manager decides with macOS trust (SecTrust, leaf plus chain) and its trust-on-first-use store, before credentials are sent.
- **Packaging:** `Scripts/build-app.sh` copies FreeRDP and its dependencies (OpenSSL 3, MIT Kerberos, libusb, cJSON) into `Contents/Frameworks`, relinks them to `@rpath` and signs them. The app needs nothing installed.

## RDPeek

RDPeek (MIT) was read as a reference for RDPKit integration. `RemoteDesktopCanvas.swift` is adapted from it, with attribution in `THIRD-PARTY-NOTICES.md`.
