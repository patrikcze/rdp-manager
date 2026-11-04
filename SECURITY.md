# Security Model

RDP Manager is a privileged administration tool: it holds credentials for servers and parses data from them. We assume the network is hostile and the Mac and its user account are trusted.

## Credentials
- Passwords are stored **only** in the macOS login Keychain: generic passwords, service `com.rdpmanager.RDPManager`, accessible `WhenUnlockedThisDeviceOnly`. They never go into the inventory JSON, UserDefaults, exports, logs or diagnostics.
- A typed password is saved only when the user asks **and** the server verified it through NLA before activating the session. A password the server refused is cleared from memory and is never retried automatically.
- Revealing a saved password requires device-owner authentication (Touch ID or the login password) via LocalAuthentication.
- Deleting a connection deletes its own Keychain item. Settings › Remove Unused Passwords deletes items that nothing references.
- Library exports contain no passwords and no connection history.
- A session keeps the password in process memory while the session exists, so Reconnect works without a prompt. Swift `String`s cannot be zeroed reliably; this is a known limitation.

## Server identity
- RDPKit evaluates the TLS chain with the system trust store during the handshake, **before any credential is sent**.
- An untrusted certificate, or one that differs from the certificate the user trusted earlier for that host and port, stops the connection. The user sees the SHA-256 fingerprint and decides. Nothing is accepted automatically, and `hideCertificateWarnings` is never set.
- Trust decisions are stored per host and port (`trusted-certificates.json`, not secret) and can be revoked in Settings.
- NLA is never downgraded silently. **Standard RDP Security** (RC4, no server authentication) is used only when a connection or group explicitly selects it. It then runs on FreeRDP, the editor and the inspector warn about it, and the session shows a notice. Automatic mode offers only NLA and TLS. RDPKit refuses CredSSP versions below 5 (CVE-2018-0886), and its "Connect anyway" escape hatch is not exposed.
- **FreeRDP connections** use the same certificate decision: the bridge answers FreeRDP's callback with "accept once" or "reject", so FreeRDP's own known-hosts store is never used. RDP Manager evaluates the leaf and the chain with macOS trust (SecTrust) and its trust store before any credential is sent.
- **Kerberos** (FreeRDP) gets a service ticket with the user's password through the bundled MIT Kerberos, finding the KDC through DNS or an optional KDC proxy. Kerberos isn't verified against a live domain yet.

## Data from the server
- On RDPKit connections the protocol parser is memory-safe Swift. FreeRDP connections parse in C. FreeRDP is pinned to 3.32.2; follow its security advisories and rebuild with `Scripts/build-freerdp.sh` when bumping.
- **Device redirection is off by default.** Printers, smart cards, microphone, USB devices and the shared folder each need an explicit setting on a connection or group. A redirected smart card or USB device is usable by the remote session while connected; a shared folder can be read, written and deleted by the server.
- Clipboard files downloaded from a server are quarantined by RDPKit's pasteboard bridge.
- Clipboard redirection can be disabled per connection or group. When disabled, the clipboard channel is never joined.

## Local data
- `~/Library/Application Support/RDP Manager/` is created 0700, and `inventory.json` is written atomically as 0600.
- No analytics, telemetry or crash reporting. The only outbound connections are to hosts the user connects to. There is no background scanning or reachability probing.

## Distribution
- Hardened runtime. Developer ID builds have no entitlement exceptions. Ad-hoc builds (local use) disable library validation, because ad-hoc signatures have no team ID and the bundled FreeRDP libraries could not load otherwise.
- Every bundled library (FreeRDP, OpenSSL, Kerberos, libusb, cJSON) is inside `Contents/Frameworks` and signed. The build fails if any binary references a path outside the bundle.
- The app is **not sandboxed** in this version. Sandboxing would need network-client, user-selected-file and Keychain access-group entitlements and testing under them. It is planned before App Store-style distribution.
- RDPKit is pinned to an exact version (0.7.0). Review its changelog and security notes before bumping.

## Reporting
Please report vulnerabilities privately to the maintainer rather than in public issues.
