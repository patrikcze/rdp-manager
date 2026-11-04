# Known Limitations

Status as of 0.2.0. "Not verified live" means the code path exists and builds, but hasn't been exercised against a real server. See TESTING.md.

## Not supported
- **Serial port redirection.** FreeRDP disables it on macOS (its serial layer uses Linux-only ioctls). A macOS port is planned. See RDP-BACKEND-DECISION.md.
- **RD Gateway and RemoteApp.** Not required, so not built. `.rdp` imports warn about them.
- **Entra ID (AAD) sign-in.** FreeRDP supports it, but RDP Manager doesn't yet implement the browser sign-in it needs.
- **Smart card *logon*.** Smart cards and YubiKeys are redirected for use inside Windows, but you can't sign in to Windows with them yet.
- **H.264 on FreeRDP connections.** FreeRDP connections render RemoteFX/progressive in software. RDPKit connections use hardware H.264.
- **Clipboard on FreeRDP connections** is text only. RDPKit connections also carry images, rich text and files.

## Not implemented yet
- **Multi-monitor RDP layouts.** A session uses one window. When the server reports several monitors, automatic resizing pauses.
- **Split view of several sessions** and **session thumbnails**.
- **Reachability checks.** The sidebar shows no "online" state. Status dots reflect only sessions you opened.
- **App Sandbox.** See SECURITY.md.
- **Keyboard layout of reconnected sessions.** The Mac's layout is announced when connecting, and Windows applies it only to new sessions.
- **Intel Macs.** The build is Apple Silicon only.

## Sign-out works through the Run dialog
Session › Sign Out of Windows… opens Run (Win+R), types `logoff` and presses Enter. RDP has no client sign-out message. If policy disables Run, the session stays connected and RDP Manager says so; sign out from the Start menu instead.

## Not verified live yet
Verified against Windows 11 (Parallels VM) on 2026-11-04:

- NLA sign-in and rendering on both engines
- Printer redirection
- Shared trust store
- Typing through Run
- Wrong-password handling

Still unverified:

- **Kerberos** (no domain available), including KDC proxy.
- **Smart card readers and YubiKeys:** the channel is active, but no reader was attached during testing.
- **USB device redirection.**
- **Microphone redirection.**
- **Standard RDP Security against a server that allows it:** Windows 11 refuses it by default, and the refusal message was verified.
- Keyboard and pointer input in depth (shortcuts, Czech layout, dead keys).
- HiDPI scaling when moving between displays.
- Certificate prompt for a changed certificate.
- Automatic reconnect after a real network interruption.
- Detached windows and full screen with a live session.
