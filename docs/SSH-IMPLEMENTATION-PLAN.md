# SSH Terminal Support: Implementation Plan

Status: written 2026-11-06 before implementation (milestone A). Sections marked *Outcome* were filled in as milestones landed.

## 1. Current architecture (as reviewed)

- **Core (`RDPManagerCore`)**: `Inventory` (schema 1) holds `Folder`s, `Connection`s and `CredentialProfile`s. `ConnectionSettings` is all-optional and overlays connection → folders → `ResolvedSettings.builtIn`. `InventoryStore` (`@MainActor @Observable`) edits through `mutate`, which edits a copy. `InventoryMigrator` decodes and refuses newer schemas. `LibraryArchive` (format 1) exports without secrets and strips risky settings on import. `SecretStore`/`SecretAccount` (`credential:<uuid>`, `connection:<uuid>`) live in the login Keychain, `WhenUnlockedThisDeviceOnly`, with an attributes-only `hasPassword`. `SessionPhase`, `SessionEnd`, `ReconnectPolicy` and `CredentialPlan` are the session policy.
- **App**: `Workspace.sessions: [RemoteSession]`. `RemoteSession` is RDP-specific: it owns a `SessionEngine` (RDPKit or FreeRDP), certificate trust, Windows actions (Ctrl+Alt+Del, sign-out through Run). The surface `NSView` belongs to the session, so tabs (a `ZStack` of live views) and detached windows re-parent it without reconnecting.
- **UI**: Sidebar keeps one `List` structure (search goes to the Overview). Tab strip, session overlays, inspector, overview table, connection/folder editors with "Inherit (value)" pickers, Credentials table, Quick Connect, Settings.

## 2. Affected components

| Area | Change |
|---|---|
| `Inventory.swift` | `Connection.connectionProtocol` (`rdp`/`ssh`), `Connection.ssh`, `Folder.sshDefaults`, `CredentialProfile.kind` (+ key path/type/fingerprint), tolerant decoding, schema 2 |
| New core `SSH/` | `SSHConnectionSettings`/`ResolvedSSHSettings`, argument builder, log parser and end mapping, askpass prompt classifier, `~/.ssh/config` importer, Quick Connect target parser, terminal preferences |
| `SecretStore.swift` | New namespaces `ssh-password:<connection>` and `ssh-key-passphrase:<profile>`; existing ones unchanged |
| `InventoryStore` | SSH inheritance and sources, orphan detection aware of SSH accounts, search covers SSH user/alias, `usages` covers SSH references |
| `InventoryPersistence`, `LibraryArchive` | v1 → v2 migration; archive format 2 (protocol-aware) still reads format 1; import strips SSH startup commands, agent forwarding, credential delegation, SendEnv |
| `Workspace` | `sessions: [WorkspaceSession]` (enum of `RemoteSession` / `SSHSession`) |
| New backend `SSH/` | PTY process, askpass server, log reader, `SSHSession`, SwiftTerm view |
| Views | Protocol icons, SSH overlays, SSH inspector, protocol column, protocol-aware menus and editor, terminal settings tab |
| New target `RDPManagerAskpass` | Tiny askpass helper bundled in `Contents/MacOS` |
| Scripts | `build-app.sh` copies and signs the helper; bundled-path check unchanged |

## 3. Approach

Additive. RDP types keep their exact semantics: `ConnectionSettings`/`ResolvedSettings` are untouched and simply ignored for SSH connections. SSH settings live in parallel types with their own inheritance chain (`Folder.sshDefaults`), so an RDP credential can never flow into an SSH identity. The workspace wraps both session classes in a small enum with the shared surface (id, title, status, connect/disconnect/close); views switch on the enum only where the protocols differ.

## 4. Data migration

- Schema 1 → 2. A v1 file decodes with defaults: `protocol = rdp`, empty SSH settings, credential kind `rdpPassword`. IDs, folders, favorites, settings, `lastConnectedAt` and credential references are carried as-is (tolerant `init(from:)` on `Connection`, `Folder`, `CredentialProfile`). Saving writes schema 2.
- Newer schemas (≥ 3) are still refused, and nothing is written over them. RDP Manager 0.3.1 refuses schema 2 (it would otherwise drop SSH fields on save).
- Library archive format 2 carries protocol and SSH settings; format 1 archives still import (as RDP).
- Default ports: RDP 3389, SSH 22. A port is shown/stored as entered; the editor only replaces a port that equals the old protocol's default when the protocol changes.

## 5. SSH engine and terminal choice

| Option | Verdict |
|---|---|
| **System OpenSSH (`/usr/bin/ssh`) on a PTY** | **Chosen.** Full `~/.ssh/config` (Include, Match, ProxyJump, IdentityAgent, CertificateFile), ssh-agent (launchd's `SSH_AUTH_SOCK`, 1Password/Secretive via `IdentityAgent`), FIDO/sk keys, OpenSSH certificates, GSSAPI (Heimdal in macOS), `known_hosts` including hashed entries and `@cert-authority`. Apple ships and patches it (OpenSSH 10.5p1 on macOS 27.2); nothing to bundle or notarize. Signed platform binary under SIP. |
| SwiftNIO SSH | A protocol toolkit: no ssh_config, no agent, no ProxyJump, no GSSAPI, no FIDO, no known_hosts parser, limited key types. We would reimplement OpenSSH's client behaviour and its security decisions. Rejected. |
| libssh / libssh2 | C libraries to bundle, sign and patch ourselves; partial ssh_config support (libssh), no ProxyJump/agent parity with OpenSSH, extra CVE surface parsing untrusted data in-process. Rejected. |
| **SwiftTerm** (terminal) | **Chosen.** MIT, actively maintained (several releases per month), AppKit `TerminalView` with xterm emulation, 256/true color, Unicode width tables, alternate screen, bracketed paste, mouse reporting, built-in find bar, OSC 8 links, OSC 52 behind a delegate. Pinned **exactly 1.99.2** (2026-10-29), which includes the fix for hidden terminals redrawing when shown again (1.99.1). Compiled statically into the app, so nothing is added to `Contents/Frameworks`. Its manifest also declares swift-argument-parser, swift-docc-plugin and swift-png, which SwiftPM resolves; none of them are linked into the macOS app. |

Transport abstraction: one protocol, `SSHTransport` (start/write/resize/stop and events). Only `OpenSSHProcessTransport` implements it. No plugin framework.

### How the process runs
- `posix_spawn` of the exact path `/usr/bin/ssh` with an argument array (no shell), `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`, the PTY slave opened by path as fds 0–2, window size set on the slave before spawn. *Outcome:* macOS does not make the PTY the child's controlling terminal (only TIOCSCTTY does, which `posix_spawn` can't); the early check was misled by `/bin/sh` acquiring one itself. Resizes therefore signal SIGWINCH to the child explicitly.
- Minimal, rebuilt environment: `HOME USER LOGNAME SHELL PATH TMPDIR LANG/LC_CTYPE SSH_AUTH_SOCK KRB5CCNAME` (if set), plus `SSH_ASKPASS`, `SSH_ASKPASS_REQUIRE=force` and the askpass socket path. No secrets.
- `ssh -v -E <fifo>` writes OpenSSH's own log to a FIFO in a private 0700 temp folder, read in memory only and never written to disk. It gives truthful phases ("Connection established", "Server host key", "Authenticated to … using …", "Entering interactive session"), the host key fingerprint, the negotiated KEX/cipher (measured, shown in the inspector) and failure reasons. Debug level 1 never contains passwords or prompts.
- Reading on a dedicated dispatch source, writing on a serial queue, bounded buffers (output chunks are coalesced; the terminal's scrollback has a fixed limit). The session owns the pid: terminate with SIGHUP, then SIGKILL after a grace period, always reaped. Only that pid is signalled.
- Forced options (command line beats config): `StrictHostKeyChecking=ask`, `ForwardAgent` per setting (default `no`), `ForwardX11=no`, `PermitLocalCommand=no`, `GSSAPIDelegateCredentials` per setting (default `no`), `ControlPath=none` (multiplexing would skip host-key and auth and make the state untrustworthy), `RequestTTY=force`. Never `StrictHostKeyChecking=no`, never `UserKnownHostsFile=/dev/null`.

## 6. Security architecture

- **Askpass**: `SSH_ASKPASS_REQUIRE=force` routes every OpenSSH prompt (host key confirmation, password, passphrase, keyboard-interactive, FIDO PIN/touch notice) to `RDPManagerAskpass`. The helper only relays the prompt text to the app over a per-session Unix socket (0700 folder) and prints the app's answer; it has no Keychain access and no logic. The app accepts a connection only when the peer (via `LOCAL_PEERPID`/`LOCAL_PEERCRED`) has our uid, runs the bundled helper executable, and descends from the ssh process this session spawned (≤ 4 parent steps, for ProxyJump's inner ssh). Each prompt is classified; a stored secret is released only for a prompt that matches the session's own target and secret (password prompt for the expected user@host; passphrase prompt naming the configured key file), at most once per attempt. Anything else goes to the user. Unknown prompts are shown as text, never answered automatically. The askpass service is therefore not a generic Keychain oracle.
- **Host keys**: OpenSSH `known_hosts` is the trust store (separate from RDP's certificate store). Unknown key → askpass confirm prompt → app card with the SHA-256 fingerprint; "Trust and Connect" answers `yes`, which makes OpenSSH record it. A changed key makes OpenSSH stop before authentication ("REMOTE HOST IDENTIFICATION HAS CHANGED"); the app shows it as a security event with the offending `known_hosts` line, and offers no bypass. Custom ports are recorded by OpenSSH as `[host]:port`.
- **Terminal output**: OSC 52 clipboard writes and reads are refused (SwiftTerm delegate no-ops) unless the user enables "Allow remote programs to set the clipboard" (write only, never read). Links open only on the user's ⌘-click and only for http/https. Titles are sanitized and length-limited. Bell follows the setting. No session recording or transcript files.
- **Imports**: library imports and `~/.ssh/config` imports never bring startup commands/directories, agent forwarding, credential delegation or SendEnv. `ProxyCommand`, `LocalCommand`, `RemoteCommand`, `Match exec`, `PermitLocalCommand` lines are ignored and reported.

## 7. Credential and key management

- Credential profiles gain `kind`: `rdpPassword` (existing, default), `sshPassword`, `sshKey` (path in `~/.ssh`, key type and SHA-256 fingerprint read by `ssh-keygen -l`, optional passphrase in the Keychain). Profiles of the wrong kind are not offered by the other protocol's editor.
- New Keychain accounts: `ssh-password:<connection uuid>` and `ssh-key-passphrase:<profile uuid>`. `sshPassword` profiles use the existing `credential:<uuid>`. Same service, same accessibility, same off-main-actor `CredentialService`, attribute-only `hasPassword`.
- Agent: an authentication method (no secret), using `SSH_AUTH_SOCK` or a per-connection `IdentityAgent`.
- **Managed (Keychain-held) private keys are not supported**: OpenSSH reads keys only from files or an agent. Feeding one would need a temporary key file or our own agent implementation; the first is forbidden, the second is out of scope. Documented.
- Remove Unused Passwords keeps every account an SSH connection or profile references.

## 8. Integration and regression risks

| Risk | Mitigation |
|---|---|
| Old library mis-decoded or lost | Tolerant decoders, fixture test of a real v1 file, newer schema refused |
| RDP behaviour drift | RDP types untouched; full RDP suite stays green; `RemoteSession` unchanged apart from nothing |
| Sidebar stale rows | One `List` structure kept; only row content changes |
| Main-actor I/O | PTY read/write, FIFO and socket on background queues; Keychain through `CredentialService` |
| Orphans / fd leaks | `CLOEXEC_DEFAULT`, all fds closed on stop, process reaped, test counts open fds |
| ssh log format changes | Parser matches stable OpenSSH messages and degrades to "Connecting…" + exit code |
| Swift 6 concurrency | Background classes are `Sendable` with locks; UI classes `@MainActor @Observable` |

## 9. Milestones

A review + plan · B embedded shell (PTY, I/O, resize, disconnect) · C protocol-aware inventory, migration, editor, Quick Connect · D mixed workspace · E Keychain, keys, agent, askpass · F ssh config import, ProxyJump, forwarding controls, GSSAPI, terminal settings, find, clipboard · G security review, tests, packaging, docs.

## 10. Acceptance criteria

- `swift build`, `swift test` and `Scripts/make-dmg.sh` pass; the bundled-path check passes.
- A v1 library loads unchanged as RDP; Keychain IDs unchanged.
- SSH hosts can be created and appear beside RDP hosts; double-click opens a terminal tab in the workspace.
- Sessions of both protocols coexist and stay connected while hidden or detached.
- Key, agent and encrypted-key auth verified against a local throwaway sshd; host keys enforced (unknown prompts, changed refused).
- Password authentication through the Keychain verified end-to-end where a password server is available, otherwise marked unverified.
- Docs list exactly what was verified.

## 11. Outcome (2026-11-07)

Milestones A–G landed on branch `feature/ssh-terminal`. Deviations from the plan:
- SIGWINCH is sent explicitly (see §5).
- Through a jump host or proxy (asked of `ssh -G`), the log level is VERBOSE instead of `-v`, because ProxyJump's inner ssh inherits `-v` and printed its debug log into the terminal. Sessions then count as connected at "Authenticated".
- Automatic reconnect defaults to off for SSH.
- Password and keyboard-interactive sign-in are implemented and unit-tested but not verified against a server (needs PAM). See docs/SSH-TESTING.md.
