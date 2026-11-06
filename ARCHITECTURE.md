# Architecture

```
Package.swift
Sources/
  FreeRDPBridge/             C API over FreeRDP 3 (rm_session_*): connection, GDI frames,
                             input, Display Control, text clipboard, device channels
  RDPManagerAskpass/         OpenSSH askpass helper: relays a prompt over the session's
                             socket and prints the app's answer (bundled in Contents/MacOS)
  RDPManagerCore/            Pure Swift, no UI, no RDP engine — fully unit-tested
    Models/                  Inventory, Folder, Connection (rdp/ssh), CredentialProfile
                             (kind), ConnectionSettings and SSHConnectionSettings
                             (inheritable, separate chains), HostAddress
    SSH/                     ssh argument builder, OpenSSH log parser and SSHEndMapping,
                             askpass prompt classifier and SSHSecretPolicy, Quick Connect
                             targets, ~/.ssh/config importer, terminal preferences
    Persistence/             InventoryStore (@Observable, main actor), JSON file
                             persistence, schema migrator
    Security/                SecretStore protocol, KeychainSecretStore, InMemorySecretStore
    ImportExport/            .rdp importer, LibraryArchive (JSON export without secrets)
    Sessions/                SessionPhase, SessionEnd, CertificateIssue,
                             ReconnectPolicy, CredentialPlan
  RDPManager/                The macOS app (executable target)
    App/                     @main, AppModel, Workspace (open sessions, tabs,
                             windows), commands, sample library
    Backend/                 the only code that touches an RDP engine
      RemoteSession          one connection, engine-neutral: credentials, cert decision,
                             reconnect policy, sign-out, UI state
      SessionEngine          protocol both engines implement (start/stop/input/events)
      RDPKitEngine           RDPKit: H.264 via VideoToolbox, NTLM, clipboard, audio, drives
      RemoteDesktopCanvas    RDPKit video view + input view (AppKit)
      SessionEndMapping      RDPConnectionFailure → SessionEnd / re-prompt
      FreeRDPEngine          FreeRDP: Kerberos, Standard RDP Security, printers,
                             smart cards, microphone, USB; FreeRDPConnection runs the
                             C session on its own thread
      FreeRDPCanvas          framebuffer layer, keyboard/pointer/scroll, remote cursor
      FreeRDPEndMapping      FreeRDP error + Set Error Info → SessionEnd / re-prompt
      CertificateTrustStore  user-trusted certs, shared by both engines
      SSH/                   SSHSession (state, prompts, reconnect), SSHTransport and
                             OpenSSHProcessTransport, PTYProcess (posix_spawn, PTY,
                             reaping), SSHSideChannels (log FIFO, askpass socket, peer
                             checks), SSHTerminalView (SwiftTerm)
      CredentialService      Keychain calls off the main actor
    DesignSystem/            colors, status dot, small shared views
    Features/                Sidebar, Workspace (window, tabs, overview table),
                             Sessions (session view + overlays, detached window),
                             Inspector, Editors, Credentials, QuickConnect, Settings
Tests/
  RDPManagerCoreTests/       unit tests (Swift Testing)
  RDPEngineIntegrationTests/ real RDPKit runs against local sockets, FreeRDP mapping,
                             opt-in live FreeRDP sign-in
ThirdParty/                  FreeRDP source/build/install (not checked in)
Scripts/build-freerdp.sh     builds pinned FreeRDP 3.32.2 with the features used
Scripts/build-app.sh         builds, bundles libraries and signs "RDP Manager.app"
Scripts/make-dmg.sh          drag-to-Applications DMG (signs + notarizes with a Developer ID)
Scripts/render-icon.swift    renders the app icon
```

## Key decisions

**Persistence: one JSON document.** The inventory (folders, connections, credential *metadata*, expansion state) is a few hundred KB even with thousands of hosts. A single atomic, owner-only (0600) JSON file loads in milliseconds and diffs cleanly. It shares a format with export, and migrations are explicit (`InventoryMigrator`). SwiftData would add schema coupling and a store we can't easily inspect. Saves are coalesced (400 ms) and flushed at quit.

**Settings inheritance.** Every inheritable field of `ConnectionSettings` is optional, and nil means inherit. `InventoryStore.resolvedSettings(for:)` overlays connection → nearest folder → … → root folder → `ResolvedSettings.builtIn`. `source(of:for:)` tells the UI where each value came from.

**Credentials.** Identity metadata (user, domain) lives in the inventory. Passwords live only in the Keychain, under `SecretAccount`:

- `credential:<uuid>` for shared profiles
- `connection:<uuid>` for a host's own identity

`CredentialPlan` turns an assignment into "read Keychain, then prompt" or "prompt". Passwords typed at a prompt are saved only after the server verified them over NLA (`credentialsVerifiedBeforeActivation`).

**Engines.** `EngineChoice` (core, tested) picks RDPKit unless a setting needs FreeRDP: Standard RDP Security, Kerberos, printers, smart cards, microphone or USB. A connection may force either engine. Both engines implement `SessionEngine` and report the same events (certificate seen/refused, activated, desktop shown, statistics, ended), so the session controller, prompts and reconnect policy are shared. FreeRDP's C callbacks reach Swift through an opaque pointer to `FreeRDPConnection`, which copies dirty framebuffer rectangles under a lock and coalesces them into one `CGImage` per main-queue turn.

**Sessions.** `RemoteSession` is `@MainActor @Observable`. RDPKit's blocking `run` executes on the engine's own thread inside `RDPLiveSession`. Frames are decoded off the main thread and delivered in order to the main queue. Handlers hold the session weakly through `recipient`, so a closed tab is not kept alive. Each session owns its own canvas, clipboard bridge, audio player and metrics store, so sessions are fully independent.

**State machine.**

```
idle → resolvingCredentials → connecting → connected
            ↓                     ↓   ↘          ↓ network drop (≤3, backoff 2/5/10 s)
   awaitingCredentials ←── wrong/missing password    reconnecting → connected
                                 ↓                        ↓ exhausted
   awaitingCertificateDecision (refused before credentials are sent)
                                 ↓
                               ended(SessionEnd)  ← disconnect / failure / server end
```

`ReconnectPolicy` (core, tested) only ever retries network failures of a session that was showing the desktop. Authentication, certificate, server and client failures never loop.

**Tabs and windows.** `Workspace` keeps sessions in order. The main window renders every tabbed session in a `ZStack` and shows only the selected one, so switching tabs never tears down a connection. The canvas `NSView` belongs to the session, not to SwiftUI. Moving a session to its own window re-parents the canvas into the new window's host view, and closing that window puts it back as a tab.

**SSH sessions.** `SSHSession` (`@MainActor @Observable`) runs `/usr/bin/ssh` through `SSHTransport`; `OpenSSHProcessTransport` is the only implementation. The process runs on a PTY from `posix_spawn` (argument array, no shell, `CLOEXEC_DEFAULT`, own session). macOS gives such a child no controlling terminal, so the PTY layer signals SIGWINCH to that pid after each resize. `ssh -v -E <fifo>` writes OpenSSH's own log to a FIFO in a per-session 0700 folder; `SSHLogParser` turns it into the session's states: connecting → verifying host key → authenticating → connected (OpenSSH's "Entering interactive session", or "Authenticated" through a jump host, where the log is VERBOSE so the jump's ssh stays quiet). `SSH_ASKPASS_REQUIRE=force` routes every prompt to `RDPManagerAskpass`, which relays it to the session's socket; the session checks the peer (same uid, bundled helper, below its own ssh), classifies the prompt, and answers from the Keychain only where `SSHSecretPolicy` allows, otherwise asks the user. PTY reads, writes, the FIFO and the socket share one serial queue; events reach the main actor in order through the main queue. Output goes straight to SwiftTerm's thread-safe `feed`. `SSHEndMapping` (core) interprets how ssh ended; reconnects go through `ReconnectPolicy`.

**Workspace.** `Workspace.sessions` is `[WorkspaceSession]`, an enum over `RemoteSession` and `SSHSession` with the shared surface (id, title, status, surface view, connect/disconnect/close). Views switch on the case only where protocols differ, so menus never offer RDP actions to SSH or the reverse. `SessionStatus` (core) is the protocol-neutral state behind status dots and tables.

**Data model.** Schema 2 adds `Connection.connectionProtocol` and `.ssh`, `Folder.sshDefaults` and `CredentialProfile.kind`; tolerant decoders read schema 1 unchanged. SSH settings inherit through their own folder chain, so RDP settings and credentials never flow into SSH. Keychain accounts add `ssh-password:<connection>` and `ssh-key-passphrase:<profile>`.

**Concurrency.** Swift 6 language mode throughout. UI and session state live on the main actor. Keychain I/O runs in detached tasks because a read can block on the access dialog. The engine runs on its own thread, and `onWireReceive` runs on the SwiftNIO event loop and only records samples.
