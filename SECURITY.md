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
- NLA is never downgraded. Servers that offer only Standard RDP Security are refused. CredSSP versions below 5 (CVE-2018-0886) are refused, and the "Connect anyway" escape hatch RDPKit offers is intentionally not exposed.

## Data from the server
- The protocol parser is memory-safe Swift (RDPKit).
- Clipboard files downloaded from a server are quarantined by RDPKit's pasteboard bridge.
- Clipboard redirection can be disabled per connection or group. When disabled, the clipboard channel is never joined.

## Local data
- `~/Library/Application Support/RDP Manager/` is created 0700, and `inventory.json` is written atomically as 0600.
- No analytics, telemetry or crash reporting. The only outbound connections are to hosts the user connects to. There is no background scanning or reachability probing.

## Distribution
- Hardened runtime, no entitlement exceptions.
- The app is **not sandboxed** in this version. Sandboxing would need network-client, user-selected-file and Keychain access-group entitlements and testing under them. It is planned before App Store-style distribution.
- RDPKit is pinned to an exact version (0.7.0). Review its changelog and security notes before bumping.

## Reporting
Please report vulnerabilities privately to the maintainer rather than in public issues.
