# Design

## Principles
- **Native first.** SwiftUI with AppKit where it matters, system materials, semantic colors, SF Symbols and SF Pro. Light and dark come from the system. Reduce Motion disables the pulsing status dot.
- **The desktop is the content.** A session fills the area under the tab strip edge to edge, with no margins. The inspector is optional and closed by default. Focus mode (⇧⌘F) hides the sidebar, tabs and inspector, and full screen (⌃⌘F) removes the rest.
- **Truthful state.** Green means the remote desktop is showing. Orange means connecting or reconnecting, yellow means waiting for you (sign-in or certificate), red means failed. There is no "online" indicator, because reachability is never probed.
- **Keyboard-first.** ⌘K Quick Connect, ⌘N new connection, ⇧⌘N new group, Return to connect the selection, ⌫ to delete, ⌘0 Overview, ⌘1…⌘9 sessions, ⇧⌘[ ⇧⌘] cycle tabs, ⌥⌘R reconnect, ⌥⌘D disconnect, ⌥⌘I inspector.

## Layout

```
┌ toolbar: [Quick Connect field]                      [+] [Session ▾] [Focus] [Inspector] ┐
├ sidebar ───────────┬ tab strip: [Overview] [● DC01 ×] [● APP01 ×] ───────────┬ inspector ┤
│ Search             │                                                         │ (optional)│
│ LIBRARY            │   Overview: sortable table of the selected group        │ status    │
│  All / Favorites / │   — or —                                                │ display   │
│  Recent            │   the selected session, edge to edge                    │ perf      │
│ CONNECTIONS        │   (connecting / sign-in / certificate / ended overlays) │ security  │
│  ▾ EMEA            │                                                         │ actions   │
│    ▾ Datacenter    │                                                         │           │
│ SECURITY           │                                                         │           │
│  Credentials       │                                                         │           │
└ [+] ───────────────┴─────────────────────────────────────────────────────────┴───────────┘
```

- **Sidebar.** Smart lists, then the unlimited-depth group tree with persistent expansion state, then Credentials. Rows support drag and drop: onto a group to move into it, onto a host to place items before it. Each row has a context menu (connect, connect all, edit, rename inline, duplicate, favorite, color, delete), double-click and Return connect, and a status dot for the actual session.
- **Overview.** The table layout from the reference screenshot, made quieter: name with host icon and color label, live status, monospaced address, group path, the effective "Sign in as" identity (resolved through inheritance), OS label and last connected. It has a column sort, a local filter, multi-select, and Connect for several hosts at once.
- **Session overlays.** Centered cards on the window background. A material sign-in card prefills the user and domain, and only offers "Save password in Keychain" where saving is possible. The certificate card shows the fingerprint grouped in byte pairs and says that no credentials were sent. The ended card is worded by failure category, with Reconnect as the default action.
- **Editors.** Grouped forms. Every inheritable setting offers "Inherit (value)", so the effective value is always visible. The inspector shows where each effective setting comes from.

## Icon
An original design rendered by `Scripts/render-icon.swift`: a deep blue squircle with two stacked windows (several sessions). The front window shows a remote screen with a pointer (you're in control) and a green "connected" light in its title bar. It uses no third-party marks or Windows logo.
