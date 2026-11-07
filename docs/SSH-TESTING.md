# SSH Testing

```bash
swift test --filter SSH            # SSH unit and end-to-end tests
swift test                         # everything, RDP included
```

The end-to-end suite starts a throwaway `sshd` as the current user on `127.0.0.1` and a random port, with its own host key, authorized keys and client config in a temporary folder. The client under test gets `-F` and `UserKnownHostsFile` pointing there, so `~/.ssh` is never read or changed. The suite skips itself where `/usr/sbin/sshd` is missing.

## Automated

| Suite | Covers |
|---|---|
| `SSHInventoryTests` | A real schema 1 library loads as RDP with IDs, folders, favorites, settings, history and credential references; newer schemas refused; default ports 3389/22; protocol switch keeps a deliberate port; mixed folders and protocol-aware inheritance (an RDP credential never reaches SSH); key profile users; orphan cleanup keeps SSH passwords and passphrases; stable Keychain account names; exports carry both protocols without secrets; imports drop risky SSH settings; format 1 archives import as RDP |
| `SSHCommandTests` | Forced safety options; opt-in options; option injection through host, user, key path, jump host, alias and SendEnv refused; `/dev/null` known_hosts refused; startup directory quoting; environment allowlist; quieter log through proxies; `ssh -G` queries never carry the command |
| `SSHLogTests` | OpenSSH log messages; hostile log text sanitized and bounded; failures categorized (auth, DNS, refused, timeout, no common algorithm, changed host key, user disconnect, drop after connect, remote exit); reconnect only after a dropped live session |
| `SSHPromptTests` | Real OpenSSH prompts (host key with port, password, passphrase, keyboard-interactive, OTP, PIN, FIDO notice, IP mismatch); saved secrets answer only matching prompts, once; prompt text cleaned |
| `SSHInputTests` | Quick Connect parsing (RDP stays default, `ssh://`, `ssh user@host`, IPv6, injection refused); `~/.ssh/config` import (concrete hosts, wildcards and Match skipped, commands never imported, Include); risky paste; preference clamping and safe defaults |
| `AskpassChannelTests` | An askpass connection made before ssh's pid is known waits in the backlog instead of failing the peer check (it failed the host key and passphrase prompts on a slower CI machine); a connection accepted before the helper wrote its question waits for it (accepted sockets inherit the listener's O_NONBLOCK); closing before accepting releases the socket |
| `SSHLocalServerTests` | Real ssh against a local sshd: unknown host key asked, trusted, recorded with the port, and not asked again; changed host key refused before sign-in; wrong key fails without retry; encrypted key's passphrase answered from the store through the askpass helper (peer checks included); a wrong saved passphrase asks the user; agent keys; resize reaches the server without reconnecting; ProxyJump without debug output in the terminal; remote exit ends without reconnect; disconnecting an interactive shell ends the session; silent server times out; cancel at the host key prompt leaves no descriptors or folders; rejecting the host key sends nothing |

Last run: 2026-11-07, macOS 27.2, OpenSSH 10.5p1, Swift 6.4.2, Apple Silicon. 114 tests pass (72 core, 42 integration), including 13 end-to-end SSH tests. Disconnecting an interactive shell was also checked in a debug build against a local sshd: the tab strip stays in place and the Disconnected bar shows.

## Verified by hand

| Scenario | Result | Evidence |
|---|---|---|
| Mixed RDP and SSH hosts in one group, distinct SSH icon | PASS | Sample library screenshot, 2026-11-07 |
| SSH editor with protocol picker and inherited values | PASS | Screenshot (`-Show ssh-editor`) |
| SSH connection inspector with sources | PASS | Screenshot (`-Show ssh-inspector`) |
| Quick Connect `ssh://user@127.0.0.1:port` opens an in-app terminal tab, green status | PASS | Screenshot of a live zsh prompt with powerline glyphs and true color, local sshd |

## Not verified yet
- **Password and keyboard-interactive sign-in** against a real server (needs PAM, i.e. a root sshd or the Linux test host). The askpass path is the one the passphrase test exercises, and the prompt classification is unit-tested.
- Keychain prompts for SSH secrets with the real login Keychain.
- GSSAPI/Kerberos (no domain available).
- FIDO/security-key sign-in (touch notice and PIN prompts are unit-tested only).
- Typing in depth: Ctrl-C/D/Z/L, Option as Meta, Czech layout and dead keys, function keys, ⌘C/⌘V, find, clear scrollback, font size.
- vim, tmux, htop, large output, Unicode combining characters in a live session.
- Detached window and full screen with a live SSH session; several SSH sessions at once.
- Automatic reconnect after a real network drop.
- Multi-line paste confirmation and OSC 52 setting with a real program.

## Checking the UI against a local sshd (debug builds)
Debug builds read `RDPM_SSH_CONFIG`, `RDPM_SSH_KNOWN_HOSTS` and `RDPM_SSH_KEY` for Quick Connect sessions, so a check never touches `~/.ssh`:

```bash
open -n "build/RDP Manager.app" --env RDPM_SSH_CONFIG=/tmp/t/client_config \
  --env RDPM_SSH_KNOWN_HOSTS=/tmp/t/known_hosts --env RDPM_SSH_KEY=/tmp/t/userkey \
  --args -SampleLibraryInMemory -QuickConnect "ssh://$USER@127.0.0.1:22999"
```

## Live checklist (Linux test host)
Ask before running against the test host; pass credentials through the environment only.
1. New SSH connection, password auth, "Save in Keychain": connect, then reconnect without a prompt.
2. Wrong password: asked again with "not accepted", no loop.
3. Key with passphrase via an SSH key credential.
4. Unknown host: fingerprint card; Don't Connect sends nothing; Trust connects.
5. Change the server's host key: "The Host Key Has Changed", no way around it.
6. `vim`, `tmux`, `htop`, `printf '\e]52;c;aGk=\a'` (refused by default), resize the window, detach the tab, full screen.
7. Ctrl-C in `sleep 100`, Ctrl-D at the prompt, Option keys on a Czech layout.
