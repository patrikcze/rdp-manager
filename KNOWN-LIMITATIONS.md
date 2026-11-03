# Known Limitations

Status as of 0.1.0. "Not verified live" means the code path exists and builds, but has not been exercised against a real Windows host yet. See TESTING.md.

## Not supported by the engine (RDPKit 0.7.0)
- **RD Gateway**: hosts behind a gateway need a VPN. `.rdp` imports warn about gateway settings.
- **Kerberos**: authentication uses NTLM through CredSSP. Domains that disable NTLM cannot be reached.
- **Entra ID (AAD) sign-in, smart cards, Windows Hello**: not available.
- **RemoteApp**: imports warn and open the full desktop instead.
- **Printer, USB, serial, smart card and microphone redirection**: not available.
- **Standard RDP Security (non-TLS)**: refused by design.

## Not implemented in the app yet
- **Signing out of the remote Windows session.** Disconnect leaves the Windows session running on the server, and the UI says so. To sign out, use the Start menu inside the session.
- **Multi-monitor RDP layouts.** A session uses one window. When the server reports several monitors, automatic resizing pauses instead of merging them.
- **Split view of several sessions** and **session thumbnails**.
- **Drive redirection UI.** The engine supports it, but there are no settings for it yet.
- **Ctrl+Alt+End as a shortcut.** Use Session › Send Keys › Ctrl+Alt+Del or the inspector button.
- **Reachability checks.** The sidebar shows no "online" state. Status dots reflect only sessions you opened.
- **App Sandbox.** See SECURITY.md.
- **Keyboard layout follow-up.** The Windows layout is announced from the Mac's input source when connecting. Windows applies it only to new sessions, not to sessions it reconnects you to.

## Not verified live yet
No Windows host was available in the development environment. These paths are implemented but unverified against a server:

- Successful NLA sign-in, rendering, keyboard and pointer input
- Dynamic resolution and HiDPI scaling, and moving between displays
- Clipboard in both directions, remote audio playback
- Certificate trust prompt and changed-certificate detection
- Automatic reconnect after a real network interruption
- Detached session windows and full-screen mode with a live session

Pointer mapping, keyboard translation, codecs, clipboard bridging and certificate evaluation are RDPKit components with their own tests. The app wires them the way RDPKit's reference client does.
