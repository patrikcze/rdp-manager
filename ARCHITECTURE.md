# Architecture

```
Package.swift
Sources/
  RDPManagerCore/            Pure Swift, no UI, no RDP engine — fully unit-tested
    Models/                  Inventory, Folder, Connection, CredentialProfile,
                             ConnectionSettings (inheritable), HostAddress
    Persistence/             InventoryStore (@Observable, main actor), JSON file
                             persistence, schema migrator
    Security/                SecretStore protocol, KeychainSecretStore, InMemorySecretStore
    ImportExport/            .rdp importer, LibraryArchive (JSON export without secrets)
    Sessions/                SessionPhase, SessionEnd, CertificateIssue,
                             ReconnectPolicy, CredentialPlan
  RDPManager/                The macOS app (executable target)
    App/                     @main, AppModel, Workspace (open sessions, tabs,
                             windows), commands, sample library
    Backend/                 RDPKit integration — the only code that touches the engine
      RemoteSession          one connection: lifecycle, credentials, cert gate,
                             reconnect, resize, clipboard, audio, metrics
      RemoteDesktopCanvas    RDPKit video view + input view (AppKit)
      SessionEndMapping      RDPConnectionFailure → SessionEnd / re-prompt
      CertificateTrustStore  user-trusted certs (RDPKit TOFU identifiers)
      CredentialService      Keychain calls off the main actor
    DesignSystem/            colors, status dot, small shared views
    Features/                Sidebar, Workspace (window, tabs, overview table),
                             Sessions (session view + overlays, detached window),
                             Inspector, Editors, Credentials, QuickConnect, Settings
Tests/
  RDPManagerCoreTests/       unit tests (Swift Testing)
  RDPEngineIntegrationTests/ real RDPKit runs against local sockets
Scripts/build-app.sh         builds and signs "RDP Manager.app"
Scripts/render-icon.swift    renders the app icon
```

## Key decisions

**Persistence: one JSON document.** The inventory (folders, connections, credential *metadata*, expansion state) is a few hundred KB even with thousands of hosts. A single atomic, owner-only (0600) JSON file loads in milliseconds and diffs cleanly. It shares a format with export, and migrations are explicit (`InventoryMigrator`). SwiftData would add schema coupling and a store we can't easily inspect. Saves are coalesced (400 ms) and flushed at quit.

**Settings inheritance.** Every inheritable field of `ConnectionSettings` is optional, and nil means inherit. `InventoryStore.resolvedSettings(for:)` overlays connection → nearest folder → … → root folder → `ResolvedSettings.builtIn`. `source(of:for:)` tells the UI where each value came from.

**Credentials.** Identity metadata (user, domain) lives in the inventory. Passwords live only in the Keychain, under `SecretAccount`:

- `credential:<uuid>` for shared profiles
- `connection:<uuid>` for a host's own identity

`CredentialPlan` turns an assignment into "read Keychain, then prompt" or "prompt". Passwords typed at a prompt are saved only after the server verified them over NLA (`credentialsVerifiedBeforeActivation`).

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

**Concurrency.** Swift 6 language mode throughout. UI and session state live on the main actor. Keychain I/O runs in detached tasks because a read can block on the access dialog. The engine runs on its own thread, and `onWireReceive` runs on the SwiftNIO event loop and only records samples.
