# RDP Backend Decision

**Decision:** RDPKit 0.7.0 (pure Swift, MIT), pinned exactly in `Package.swift`.
**Date:** 2026-11-03. **Re-evaluate:** before bumping RDPKit, or when RD Gateway / Kerberos become required.

## Candidates examined

Sources were read directly (shallow clones of each repository's `main` on 2026-11-03), not taken from marketing pages.

| | **RDPKit** (steelbrain/RDPKit) | **FreeRDP 3.x** (FreeRDP/FreeRDP) | **RDPeek** (steelbrain/RDPeek) |
|---|---|---|---|
| What it is | Swift 6 RDP client library + AppKit views | C client library + reference clients | macOS app built on RDPKit |
| Version / activity | 0.7.0 tag; commit 2026-11-02 | 3.32.2 stable (Homebrew) | 1.3.0; commit 2026-11-02 |
| License | MIT | Apache-2.0 | MIT |
| Size | ~40k lines source, ~48k lines tests | very large C codebase + deps | ~6k lines app code |
| Apple Silicon / macOS | Native SwiftPM, macOS 13+ | Builds; Homebrew formula is X11/SDL; Mac client lags | macOS 14+ |
| TLS + cert inspection | SwiftNIO SSL, system trust eval, SHA-256, TOFU store with change detection | Yes (OpenSSL) | Uses RDPKit |
| NLA / CredSSP | Yes, NTLM; refuses CredSSP < 5 (CVE-2018-0886) | Yes, NTLM + Kerberos | — |
| Kerberos | **No** (grep: no implementation) | Yes | — |
| RD Gateway | **No** | Yes (HTTP, RPC, websocket) | — |
| Graphics | RDPGFX 8.0–10.7, AVC420/AVC444 via VideoToolbox, RemoteFX, ClearCodec, planar, NSCodec | Broad, mostly software or FFmpeg | — |
| Rendering on Mac | `AVSampleBufferDisplayLayer`, zero-copy CoreVideo, display-link pacing | App must copy framebuffer into a layer itself | — |
| Dynamic resize / HiDPI | Display Control channel, scale factors | Yes | — |
| Keyboard | Scancode + Unicode, Mac layout → KLID mapping, dead keys, modifier sync on focus loss | App must implement Mac mapping | — |
| Clipboard | Text/HTML/RTF/bitmap/files, pasteboard bridge | Yes | — |
| Audio out / drives | RDPSND; drive redirection | Yes, plus printers, smartcard, USB | — |
| Typed failures | `RDPConnectionFailure` enum, NTSTATUS, termination categories | Error codes | — |
| Security history | Young (2026), no published advisories found; small attack surface in memory-safe Swift | Regular CVE batches in 2024–2025 (memory safety in C parsers) | — |
| Integration effort | Low: Swift APIs, main-thread delivery (`RDPLiveSession`) | High: C shim, callbacks, framebuffer, input mapping, dylib bundling/signing of OpenSSL, FFmpeg… | Reference only |

## Why RDPKit

1. **Verified, not assumed:** the engine-integration tests in `Tests/RDPEngineIntegrationTests` run real RDPKit connection attempts and check its typed failures. Its own test suite (48k lines) covers protocol parsing.
2. **Memory safety** in a privileged admin tool that parses untrusted server data. FreeRDP's recurring C parser CVEs are the main risk we avoid.
3. **Mac-native presentation:** hardware H.264 decode and display-link pacing are built in. FreeRDP would need a custom renderer to match.
4. **Correct security defaults:** it refuses outdated CredSSP, evaluates the certificate *before* credentials are sent, and has a trust-on-first-use store that detects changed certificates.
5. **Distribution:** a single Swift package. There are no C dylibs to bundle, sign and notarize, and no OpenSSL to patch.

## What we give up (documented in KNOWN-LIMITATIONS.md)

- **RD Gateway**: not available. Hosts behind a gateway need a VPN.
- **Kerberos**: NTLM only. Domain accounts still work over NTLM unless the domain disables it.
- **Smart cards, Entra ID / AAD sign-in, RemoteApp, printer/USB redirection**: not available.
- **Maturity**: RDPKit is 0.x. Its API changes between minor versions, so we pin exactly.

## RDPeek

RDPeek is MIT-licensed and built by the same author on RDPKit. We read it as a reference for the RDPKit integration patterns: certificate gating in `onCertificate`, frame presenter wiring, and display-control resizing. `RemoteDesktopCanvas.swift` is adapted from its canvas view, with attribution in the file and in `THIRD-PARTY-NOTICES.md`. RDP Manager uses none of RDPeek's UI, assets or branding.

## The backend seam

The protocol integration lives in `Sources/RDPManager/Backend/`:

- `RemoteSession` owns one RDPKit `RDPLiveSession` and exposes engine-neutral state (`SessionPhase`, `SessionEnd`, `CertificateIssue` from `RDPManagerCore`).
- `SessionEndMapping` is the only place that interprets `RDPConnectionFailure`.
- Views never import RDPKit, except the canvas host.

A second engine (for example a FreeRDP backend for gateway-only hosts) would add a sibling `RemoteSession` implementation that produces the same core types. We deliberately did not build a speculative protocol/plugin layer before there is a second engine.
