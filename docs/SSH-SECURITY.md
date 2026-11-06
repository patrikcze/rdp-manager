# SSH Security

RDP Manager's SSH sessions run the macOS OpenSSH client (`/usr/bin/ssh`) on a pseudo-terminal the app owns, and render it with SwiftTerm. This document covers the threat review done for SSH support (2026-11-06) and the risks that remain. The RDP security model is in [SECURITY.md](../SECURITY.md).

Assumptions are the same as for RDP: the network and servers may be hostile; the Mac, its user account and the user's own `~/.ssh` files are trusted.

## Process and arguments
- ssh is started with `posix_spawn` by exact path, with an argument array. No shell is involved and nothing is looked up on `PATH`.
- Every value that becomes an argument is validated so it stays a single OpenSSH option: hosts, users, aliases and jump hosts may not start with `-` or contain whitespace, quotes or shell metacharacters; paths are quoted and may not contain `"` or control characters; `SendEnv` names are plain identifiers. Tests try option and line injection through each field.
- The environment is rebuilt from an allowlist (`HOME USER LOGNAME SHELL TMPDIR SSH_AUTH_SOCK KRB5CCNAME LANG LC_*`, plus variables a connection explicitly sends) with a fixed `PATH`. Nothing of the app's own environment reaches ssh or the server by accident. No secret is ever in arguments or the environment.
- The child gets only the PTY as fds 0–2 (`POSIX_SPAWN_CLOEXEC_DEFAULT`), default signal handlers and an empty mask, in its own session. The app signals only that pid (SIGWINCH on resize, SIGHUP then SIGKILL on disconnect) and always reaps it. The read/write sources keep the process object alive until it is reaped, so no zombie or orphan is left by a closed tab.
- Forced options (the command line beats `~/.ssh/config`): `StrictHostKeyChecking=ask`, `ControlMaster=no` and `ControlPath=none` (a shared master would skip host-key checks and authentication), `PermitLocalCommand=no`, `ForwardX11=no`, `ForwardAgent` and `GSSAPIDelegateCredentials` per connection, off by default, `RequestTTY=force`. The app never uses `StrictHostKeyChecking=no` or `accept-new`, and refuses `UserKnownHostsFile=/dev/null`.

## Prompts and secrets (askpass)
- `SSH_ASKPASS_REQUIRE=force` sends every OpenSSH question to `RDPManagerAskpass`, a ~100-line helper inside the app bundle. It sends the prompt text to the app over a Unix socket in a per-session 0700 folder (socket 0600) and prints the app's answer. It never touches the Keychain and has no logic of its own.
- The app accepts a socket connection only when the peer runs as the same uid (`LOCAL_PEERCRED`), its executable is the bundled helper (`proc_pidpath`), and it descends, within four parents, from the ssh process that session started (`LOCAL_PEERPID`, `proc_pidinfo`). Other processes are disconnected before a byte is read.
- Each prompt is classified (`SSHPromptClassifier`). A saved secret is read from the Keychain and returned only when `SSHSecretPolicy` allows it:
  - a password prompt naming the session's own user (if known) and host;
  - a keyboard-interactive prompt that is exactly `Password:` for that user and host, only when the connection names its user. Only OpenSSH's own `(user@host) ` prefix is read; the server writes the rest of the prompt, and a jump host's server is asked through the same helper, so a forged `(user@target) Password:` later in the text is ignored;
  - a passphrase prompt naming the configured key file;
  - at most once per attempt. A second request means the secret was refused, and the user is asked instead, with a note.
- Everything else goes to the user: unknown host keys, yes/no questions, one-time codes, PINs, unknown prompts (shown as text, answer hidden). Cancelling ends the attempt rather than sending an empty answer.
- So the askpass socket is not a way to read Keychain items: a caller would have to be the bundled helper, running below that session's ssh, asking the exact question that session's secret answers, and only once.
- A typed password or passphrase is saved only when the user ticks "Save in Keychain" **and** OpenSSH then reports success with the matching method (`password`/`keyboard-interactive`, or `publickey` for a passphrase).
- Prompts and answers are never logged. OpenSSH's own log (`-v -E`) goes to a FIFO in the private folder, is parsed in memory, and is never written to disk; debug level 1 contains no passwords or prompts.

## Keychain and keys
- Same service (`com.rdpmanager.RDPManager`), same `WhenUnlockedThisDeviceOnly`, all calls off the main actor. New accounts: `ssh-password:<connection>` and `ssh-key-passphrase:<profile>`; SSH password profiles use the existing `credential:<profile>`. RDP and SSH passwords of one connection are separate items, so switching a connection's protocol never reuses one as the other.
- Private keys stay in their files; only the path is stored. Type and fingerprint come from `ssh-keygen -l` on the public part, without a passphrase.
- **Keychain-held private keys are not supported.** OpenSSH can only use keys from files or an agent. Supplying one would need a temporary key file (refused) or an agent implementation inside the app (out of scope).
- Remove Unused Passwords keeps every account a connection or profile still refers to, RDP and SSH alike.

## Host keys
- OpenSSH's `known_hosts` (hashed entries, `@cert-authority`, `@revoked`, custom ports as `[host]:port`) is the SSH trust store, separate from the RDP certificate store.
- An unknown key stops OpenSSH before authentication; the app shows the fingerprint and sends nothing until the user trusts it. Trusting answers `yes`, and OpenSSH records the key.
- A changed key ends the connection before authentication with "The Host Key Has Changed", naming the old `known_hosts` entry. There is no bypass in the app; the user removes the old key with `ssh-keygen -R` after checking.
- Other OpenSSH yes/no questions (a host key that differs from the one for its IP address) are shown verbatim and default to No.

## Agent forwarding, Kerberos and ProxyJump
- Agent forwarding is off unless a connection or group turns it on; the editor and inspector warn when it is on. Kerberos delegation is off unless set.
- GSSAPI uses whatever ticket is in the user's credential cache; the app never assumes a macOS login provides one.
- ProxyJump hosts are checked with the same host-key prompts. Their inner ssh reads `~/.ssh/config` but not the app's `-o` options; that is OpenSSH's behaviour.

## Terminal output
- SwiftTerm parses everything the server sends, in memory-safe Swift. It is pinned to 1.99.2.
- OSC 52 clipboard writes are refused unless the user turns on "Allow remote programs to set the clipboard"; reads are always refused. The Kitty clipboard protocol is not offered.
- Links open only when the user clicks them, and only `http`/`https`.
- Window titles are sanitized and shortened before display. The bell plays only per the setting.
- Pasting several lines into a program without bracketed paste asks first (Settings › Terminal).
- No session recording, transcript or scrollback is saved; scrollback is bounded (1,000–100,000 lines).

## Imports
- Library imports drop SSH startup commands and directories, agent forwarding, Kerberos delegation and SendEnv, and list what they dropped. Key paths and jump hosts are kept (a jump host still goes through host-key checks).
- `~/.ssh/config` import parses only; nothing is executed. Wildcard `Host` patterns and `Match` blocks (including `Match exec`) are skipped. `ProxyCommand`, `LocalCommand`, `RemoteCommand`, `KnownHostsCommand`, `StrictHostKeyChecking`, `UserKnownHostsFile`, `ForwardAgent`, `SendEnv`, forwardings and similar lines are not imported, and the affected hosts are listed. `Include` is followed only for regular files inside the home folder, at most 8 deep, each once.

## Residual risks
- **Your own `~/.ssh/config` applies.** OpenSSH still reads it when connecting, so a `ProxyCommand`, `LocalCommand` (blocked by `PermitLocalCommand=no`), `Match exec` or `UserKnownHostsFile /dev/null` you configured yourself takes effect for matching hosts. A program started from your config could also run the askpass helper below the session's ssh and ask a matching question. Anything that can edit `~/.ssh/config` can already run code as you.
- **`StrictHostKeyChecking=ask` replaces a stricter `yes`** from your config: an unknown key is shown for review instead of refused outright. It is still never accepted without your click.
- **Passwords in memory.** Answers pass through Swift `String`s, which can't be zeroed reliably; the askpass buffers are cleared after use.
- **Through a jump host or proxy** the log level is VERBOSE (so the jump's ssh doesn't print debug output into the terminal); the inspector then has no host key fingerprint or cipher, and a session counts as live once authentication succeeds.
- **A crashed app** leaves its per-session 0700 folder (an empty socket and FIFO) in `$TMPDIR`.
- **SwiftTerm** is a large parser of untrusted input. It is pinned exactly and must be reviewed before bumping.
- **Supply chain:** SwiftTerm's manifest also resolves swift-argument-parser, swift-png and h. They are fetched at build time but not linked into the app.
