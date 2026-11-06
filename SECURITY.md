# Security Model

RDP Manager is a privileged administration tool: it holds credentials for servers and parses data from them. We assume the network is hostile and the Mac and its user account are trusted.

## Credentials
- Passwords are stored **only** in the macOS login Keychain: generic passwords, service `com.rdpmanager.RDPManager`, accessible `WhenUnlockedThisDeviceOnly`. They never go into the inventory JSON, UserDefaults, exports, logs or diagnostics.
- A password typed at the **sign-in prompt** is saved only when the user asks **and** the server verified it through NLA before activating the session. A password typed in the **connection editor** or the **Credentials** manager is a deliberate manual save and goes to the Keychain at once, unverified. A password the server refused is cleared from memory and is never retried automatically.
- Revealing a saved password requires device-owner authentication (Touch ID or the login password) via LocalAuthentication.
- Deleting a connection deletes its own Keychain item. Settings › Remove Unused Passwords deletes items that nothing references. It is unavailable while the library can't be read, because an unreadable library would make every password look unused.
- Library exports contain no passwords, key passphrases or keys, and no connection history. SSH key profiles carry the key's path, which may not exist on another Mac.
- A session keeps the password in process memory while the session exists, so Reconnect works without a prompt. Swift `String`s cannot be zeroed reliably; this is a known limitation.

## Server identity
- RDPKit evaluates the TLS chain with the system trust store during the handshake, **before any credential is sent**.
- An untrusted certificate, or one that differs from the certificate the user trusted earlier for that host and port, stops the connection. A certificate the user trusted is a pin: a replacement is refused as changed **even when macOS trusts it** (RDP Manager checks this itself on both engines, because RDPKit's helper skips system-trusted certificates). The user sees the SHA-256 fingerprint and decides. Nothing is accepted automatically, and `hideCertificateWarnings` is never set.
- Trust decisions are stored per host and port (`trusted-certificates.json`, written 0600 in the 0700 folder) and can be revoked in Settings. The in-memory sample mode keeps them in memory only.
- NLA is never downgraded silently. **Standard RDP Security** (RC4, no server authentication) is used only when a connection or group explicitly selects it. It then runs on FreeRDP, the editor and the inspector warn about it, the user must confirm it in a blocking dialog **before any password is read or typed** (once per session tab; automatic reconnects don't ask again), and the session shows a notice. Automatic mode offers only NLA and TLS. RDPKit refuses CredSSP versions below 5 (CVE-2018-0886), and its "Connect anyway" escape hatch is not exposed.
- **FreeRDP connections** use the same certificate decision: the bridge answers FreeRDP's callback with "accept once" or "reject", so FreeRDP's own known-hosts store is never used. RDP Manager evaluates the leaf and the chain with macOS trust (SecTrust) and its trust store before any credential is sent.
- **Kerberos** (FreeRDP) gets a service ticket with the user's password through the bundled MIT Kerberos, finding the KDC through DNS or an optional KDC proxy. The KDCs and the proxy are contacted in addition to the RDP host. Kerberos isn't verified against a live domain yet.

## Imported files
- A library export is someone else's choice of settings. On import, anything that weakens server authentication or opens this Mac to a server is removed and listed in the import message: Standard RDP Security, the shared folder, printers, smart cards, microphone, USB devices and the KDC proxy. The user turns them back on in the editor. Settings that are off are kept.
- `.rdp` files never bring security or device settings; the import message says what is read.

## Data from the server
- On RDPKit connections the protocol parser is memory-safe Swift. FreeRDP connections parse in C. FreeRDP is pinned to 3.32.2; follow its security advisories and rebuild with `Scripts/build-freerdp.sh`, which builds only from an unmodified checkout of the tag plus the patches in `Scripts/freerdp-patches`.
- **Desktop size limit (FreeRDP).** A server may choose the desktop size (up to 65535 × 65535, 17 GB). The bridge allows at most 8192 pixels a side and 8192 × 4608 pixels in all, checked before the framebuffer is created and on every resize; a larger desktop ends the session with "Desktop too large". Graphics-pipeline surfaces get the same limit, and a larger one is refused before it is allocated.
- **Channel lifetime (FreeRDP).** The display and clipboard channels are used only while the bridge's lock is held, and FreeRDP's disconnect and terminate events clear them under the same lock, so a server-initiated disconnect can't free a channel during a resize or clipboard update.
- **Device redirection is off by default.** Printers, smart cards, microphone, USB devices and the shared folder each need an explicit setting on a connection or group. A redirected smart card or USB device is usable by the remote session while connected; a shared folder can be read, written and deleted by the server.
- Clipboard files downloaded from a server are quarantined by RDPKit's pasteboard bridge.
- Clipboard redirection can be disabled per connection or group. When disabled, the clipboard channel is never joined.
- Turning **Share Clipboard** off during a FreeRDP session takes effect in the bridge at once: it forgets the Mac text it offered, withdraws the offer, refuses the server's later requests and stops fetching remote text.

## Local data
- `~/Library/Application Support/RDP Manager/` is created 0700, and `inventory.json` is written atomically as 0600.
- If `inventory.json` exists but can't be read, RDP Manager starts with an empty library and **never writes over the file** during that launch; the sidebar shows why.
- No analytics, telemetry or crash reporting. The only outbound connections are to hosts the user connects to and, for Kerberos, that domain's KDCs (found through DNS) or the configured KDC proxy. There is no background scanning or reachability probing.

## Distribution
- Hardened runtime. Developer ID builds have no entitlement exceptions. Ad-hoc builds (local use) disable library validation, because ad-hoc signatures have no team ID and the bundled FreeRDP libraries could not load otherwise.
- Every bundled library (FreeRDP, OpenSSL, Kerberos, libusb, cJSON) is inside `Contents/Frameworks` and signed. The build fails if any binary references a path outside the bundle.
- The app is **not sandboxed** in this version. Sandboxing would need network-client, user-selected-file and Keychain access-group entitlements and testing under them. It is planned before App Store-style distribution.
- RDPKit is pinned to an exact version (0.7.0). Review its changelog and security notes before bumping.

## SSH
SSH sessions run the macOS OpenSSH client; host keys live in OpenSSH's `known_hosts`, separate from the RDP certificate store. Passwords and key passphrases use the same Keychain service under `ssh-password:<connection>` and `ssh-key-passphrase:<profile>` (SSH password profiles use `credential:<profile>`). The askpass design, host-key handling, terminal output rules, import rules and residual risks are in [docs/SSH-SECURITY.md](docs/SSH-SECURITY.md).

## Reporting
Please report vulnerabilities privately to the maintainer rather than in public issues.
