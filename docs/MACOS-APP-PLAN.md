# freeq for macOS — Native App Plan

## Philosophy

Build a native macOS app that feels like it belongs next to iMessage, Notes, and Arc. SwiftUI + AppKit hybrid. Not a web view, not Electron, not Tauri. A real Mac citizen.

The app should feel **fast, quiet, and trustworthy** — like infrastructure you forget is running until you need it.

---

## Architecture

### Stack

| Layer | Technology | Notes |
|-------|-----------|-------|
| **UI** | SwiftUI (macOS 14+) | NavigationSplitView, native controls |
| **Platform glue** | AppKit interop | Menu bar, notifications, dock badge, window management |
| **Core logic** | `freeq-sdk` (Rust) via `freeq-sdk-ffi` (UniFFI) | Same SDK as iOS/Android — IRC, SASL, E2EE, media |
| **Persistence** | SwiftData or SQLite (via SDK) | Message history, preferences, session state |
| **Auth** | ASWebAuthenticationSession → auth broker | Same OAuth flow as iOS |

### Reuse from existing codebase

| Component | Source | Reuse level |
|-----------|--------|-------------|
| IRC protocol, SASL, reconnect | `freeq-sdk` | 100% — already cross-platform Rust |
| UniFFI bindings | `freeq-sdk-ffi` | 100% — same `.udl`, same generated Swift |
| E2EE (X3DH + Double Ratchet) | `freeq-sdk` via FFI | 100% — `FreeqE2ee` already in UDL |
| Event model | `FreeqEvent` enum | 100% — same enum, same callback pattern |
| `AppState` pattern | `freeq-ios/Models/AppState.swift` | ~80% — adapt for macOS (no UIKit refs) |
| `ChannelState`, `MemberInfo`, `ChatMessage` | `freeq-ios/Models/AppState.swift` | 95% — models are pure Swift, no iOS deps |
| Avatar cache | `freeq-ios/Models/AvatarCache.swift` | 95% — swap UIImage → NSImage |
| Keychain helper | `freeq-ios/Models/KeychainHelper.swift` | 100% — Security.framework is shared |
| Auth broker flow | `freeq-ios/Models/AppState.swift` | 90% — swap ASWebAuthSession UIKit → AppKit |
| View components | `freeq-ios/Views/*` | 30-50% — need macOS layout rethink |

**Key insight:** The hard work (IRC protocol, SASL, E2EE, message signing) is done. The macOS app is primarily a **UI project** over proven infrastructure.

---

## App Structure

### Window Layout

Three-column `NavigationSplitView` — the classic Mac chat layout:

```
┌──────────┬──────────────────────────────────────┬───────────┐
│ Sidebar  │           Message Area               │  Detail   │
│          │                                      │  Panel    │
│ #general │  ┌─ TopBar: #general · topic ──────┐ │           │
│ #freeq   │  │                                 │ │  Members  │
│ #dev     │  │  [alice] hey everyone           │ │  or       │
│          │  │  [bob]   what's up              │ │  Profile  │
│ ──────── │  │  [chad]  working on the mac app │ │  or       │
│ DMs      │  │                                 │ │  Thread   │
│ zapnap   │  │                                 │ │           │
│ alice    │  │                                 │ │           │
│          │  ├─────────────────────────────────┤ │           │
│          │  │  ComposeBar                     │ │           │
│          │  └─────────────────────────────────┘ │           │
└──────────┴──────────────────────────────────────┴───────────┘
```

- **Sidebar** (220pt): Channels + DMs, unread badges, presence dots, search field
- **Message area** (flex): Top bar + message list + compose bar
- **Detail panel** (260pt, collapsible): Member list (channels), profile panel (DMs), thread view

### Navigation

- `⌘1-9` — switch channels
- `⌘K` — quick switcher (fuzzy search channels/DMs)
- `⌘F` — search messages
- `⌘N` — new DM
- `⌘J` — join channel
- `⌘,` — preferences
- `⌘[` / `⌘]` — prev/next channel
- `⌥↑` / `⌥↓` — prev/next unread

---

## Features (by phase)

### Phase 1 — Core Chat (MVP)

Ship a working client that's better than using the web app.

**Connection & Auth**
- [ ] Connect via WebSocket (TLS) to `irc.freeq.at`
- [ ] AT Protocol OAuth via ASWebAuthenticationSession → auth broker
- [ ] SASL `web-token` authentication (same as iOS)
- [ ] Auto-reconnect with exponential backoff
- [ ] Session persistence (broker token in Keychain)
- [ ] Guest mode (no auth)

**Channels**
- [ ] Join/part channels
- [ ] Channel list with unread counts + mention badges
- [ ] Member list with presence (online/away), DID verification badges
- [ ] Topic display + inline editing
- [ ] Channel modes display

**Messaging**
- [ ] Send/receive PRIVMSG
- [ ] Rich message rendering: markdown-lite (bold, italic, code, links)
- [ ] Inline link previews (unfurl Open Graph)
- [ ] Bluesky post embeds (detect `bsky.app/profile/…/post/…` links)
- [ ] Image/media display inline (from uploads)
- [ ] Message timestamps (hover to see full, show periodically in flow)
- [ ] Nick coloring (consistent hash-based)

**DMs**
- [ ] DM list in sidebar (from CHATHISTORY TARGETS)
- [ ] Rich profile panel (avatar, handle, bio, Bluesky stats, DID)
- [ ] Presence from shared channels
- [ ] Offline messaging indicator ("messages will be saved")

**History**
- [ ] CHATHISTORY LATEST on join
- [ ] Scroll-to-top loads older messages (CHATHISTORY BEFORE)
- [ ] Unread markers ("new messages since you left")

**Compose**
- [ ] Multi-line input (Shift+Enter for newline, Enter to send)
- [ ] Slash commands (`/join`, `/part`, `/nick`, `/me`, `/topic`, `/msg`)
- [ ] `@mention` autocomplete (Tab or popup)
- [ ] Channel autocomplete (`#` trigger)
- [ ] Emoji picker (native macOS character viewer integration + shortcode `:smile:`)
- [ ] Typing indicators (send + display)

### Phase 2 — Delight

The features that make it feel like a premium Mac app.

**Message Actions**
- [ ] Edit messages (`+draft/edit`)
- [ ] Delete messages (`+draft/delete`)
- [ ] Reply to messages (`+draft/reply`)
- [ ] Reactions via TAGMSG (`+draft/react`)
- [ ] Pin/unpin messages
- [ ] Bookmark messages (local)
- [ ] Copy message text / Copy link to message
- [ ] Right-click context menu (native NSMenu)

**E2EE**
- [ ] Per-DM encryption via `FreeqE2ee` (X3DH + Double Ratchet)
- [ ] 🔒 badge on encrypted conversations
- [ ] Safety number display + comparison
- [ ] Key export/import for multi-device

**Media**
- [ ] Drag-and-drop file upload (images, files)
- [ ] Paste image from clipboard
- [ ] Image lightbox (click to expand, arrow keys to navigate)
- [ ] File attachment display with download

**Search**
- [ ] `⌘F` full-text search (local messages + server FTS when available)
- [ ] Search within channel or globally
- [ ] Jump to message in context from search result

**Threads**
- [ ] Thread view in detail panel
- [ ] Thread indicator on parent message
- [ ] Thread unread counts

**macOS Integration**
- [ ] Native notifications (UNUserNotificationCenter) with reply action
- [ ] Dock badge for unread count
- [ ] Menu bar presence indicator (optional "status item" mode)
- [ ] Spotlight integration (search messages via Spotlight)
- [ ] Share extension (share links/text to a channel)
- [ ] Handoff with iOS app (continue conversation)
- [ ] Touch Bar support (if applicable — emoji picker, channel switcher)
- [ ] System appearance (auto light/dark mode following system)
- [ ] Keyboard-driven — every action reachable without mouse

### Phase 3 — Power User

**Multiple Servers**
- [ ] Server list in sidebar (tree: server → channels)
- [ ] Per-server identity + auth
- [ ] Cross-server DM routing

**Customization**
- [ ] Custom themes (accent color, font size, density)
- [ ] Per-channel notification settings (all/mentions/none)
- [ ] Mute channels/DMs
- [ ] Favorites / channel ordering

**Advanced**
- [ ] IRC raw console (`/raw` or hidden panel)
- [ ] Connection inspector (latency, caps, server info)
- [ ] Message signing verification display (🔒 badge from `+freeq.at/sig`)
- [ ] OPER commands (for server admins)
- [ ] Channel settings panel (modes, bans, invite list)
- [ ] Export chat history (plain text / JSON)

---

## Data Flow

```
┌────────────────────────────────────────────────────┐
│                    SwiftUI Views                    │
│  Sidebar · MessageList · ComposeBar · MemberList   │
└──────────────────────┬─────────────────────────────┘
                       │ @EnvironmentObject / @Observable
                       ▼
┌────────────────────────────────────────────────────┐
│                   AppState                          │
│  channels: [ChannelState]                          │
│  dmBuffers: [ChannelState]                         │
│  connectionState: ConnectionState                  │
│  authenticatedDID: String?                         │
│  + all UI-facing state                             │
└──────────────────────┬─────────────────────────────┘
                       │ EventHandler callback (on_event)
                       ▼
┌────────────────────────────────────────────────────┐
│              freeq-sdk-ffi (UniFFI)                │
│  FreeqClient · FreeqE2ee                           │
│  Rust → Swift generated bindings                   │
└──────────────────────┬─────────────────────────────┘
                       │
                       ▼
┌────────────────────────────────────────────────────┐
│              freeq-sdk (Rust)                       │
│  IRC · SASL · TLS · E2EE · Media · OAuth          │
└────────────────────────────────────────────────────┘
```

The `EventHandler` callback dispatches `FreeqEvent` to `AppState` on the main actor. Same pattern as iOS but with macOS lifecycle.

---

## Key Design Decisions

### 1. SwiftUI-first, AppKit where needed

SwiftUI for all views. AppKit for:
- `NSMenu` context menus (richer than SwiftUI)
- `NSPasteboard` for drag-and-drop
- `NSStatusItem` for menu bar mode
- `NSSharingServicePicker` for share actions
- Window management (multi-window support)

### 2. macOS 14+ (Sonoma)

Minimum target: macOS 14. Gets us:
- `@Observable` macro (cleaner than `@ObservableObject`)
- `NavigationSplitView` with column customization
- `Inspector` modifier for the detail panel
- Improved SwiftUI performance
- `SwiftData` if we want it

**Decision: Use `@Observable` (not `@ObservableObject`)**. Migrate the iOS `AppState` pattern from `ObservableObject` to `@Observable` macro. Cleaner, more performant, no `@Published` wrappers.

### 3. Native text rendering

Use `AttributedString` for message rendering:
- Bold, italic, code spans → NSFont traits
- Links → clickable, hover underline
- @mentions → accent color, clickable
- Code blocks → monospace background

No web views. No markdown-to-HTML. Pure native text.

### 4. Multi-window support

- Main chat window
- Detachable thread windows (pop out a thread into its own window)
- Detachable DM windows
- Preferences window (`Settings` scene)

### 5. Shared Swift package

Extract models + state into a Swift package shared between iOS and macOS:

```
freeq-swift/
  Sources/
    FreeqCore/
      Models/        ← ChatMessage, ChannelState, MemberInfo
      State/         ← AppState (platform-agnostic core)
      Auth/          ← BrokerAuth, KeychainHelper
    FreeqMac/        ← macOS-specific views
    FreeqiOS/        ← iOS-specific views (existing)
```

This is optional for Phase 1 (just copy + adapt from iOS) but the right long-term move.

---

## Project Setup

### Directory structure

```
freeq-macos/
  freeq-macos.xcodeproj
  freeq-macos/
    App.swift                    ← @main, WindowGroup + Settings
    AppState.swift               ← @Observable state (adapted from iOS)
    Models/
      ChatMessage.swift
      ChannelState.swift
      MemberInfo.swift
      KeychainHelper.swift
      AvatarCache.swift
    Auth/
      BrokerAuth.swift           ← OAuth flow via ASWebAuthenticationSession
    Views/
      MainView.swift             ← NavigationSplitView (3-column)
      Sidebar/
        SidebarView.swift
        ChannelRow.swift
        DMRow.swift
        QuickSwitcher.swift
      Chat/
        ChatView.swift           ← TopBar + MessageList + ComposeBar
        TopBarView.swift
        MessageListView.swift
        MessageBubble.swift      ← Individual message rendering
        ComposeBar.swift
        TypingIndicator.swift
      Detail/
        DetailPanel.swift        ← Switches between MemberList / Profile / Thread
        MemberListView.swift
        DMProfilePanel.swift
        ThreadView.swift
      Settings/
        SettingsView.swift
        AppearanceSettings.swift
        NotificationSettings.swift
        AccountSettings.swift
      Shared/
        UserAvatar.swift
        LinkPreview.swift
        BlueskyEmbed.swift
        ImageLightbox.swift
        EmojiPicker.swift
  Generated/
    freeq.swift                  ← UniFFI-generated Swift bindings
  Libraries/
    libfreeq_sdk_ffi.a           ← Universal static lib (arm64 + x86_64)
```

### Build setup

1. Build `freeq-sdk-ffi` for macOS:
   ```bash
   # Build universal macOS static lib
   cargo build --release --target aarch64-apple-darwin -p freeq-sdk-ffi
   cargo build --release --target x86_64-apple-darwin -p freeq-sdk-ffi
   lipo -create \
     target/aarch64-apple-darwin/release/libfreeq_sdk_ffi.a \
     target/x86_64-apple-darwin/release/libfreeq_sdk_ffi.a \
     -output freeq-macos/Libraries/libfreeq_sdk_ffi.a

   # Generate Swift bindings
   cargo run -p uniffi-bindgen generate \
     freeq-sdk-ffi/src/freeq.udl \
     --language swift \
     --out-dir freeq-macos/Generated/
   ```

2. Xcode project links `libfreeq_sdk_ffi.a` + bridging header
3. Same pattern as the iOS build (already working)

---

## What Makes This "Best of Class"

| Quality | How |
|---------|-----|
| **Fast** | Native SwiftUI + Rust core. No web runtime. Sub-100ms app launch. |
| **Keyboard-first** | Every action has a shortcut. Quick switcher. Vim-style navigation optional. |
| **Beautiful** | SF Symbols, native blur/vibrancy, system font, follows accent color. |
| **Trustworthy** | E2EE with safety numbers. Message signing badges. DID verification. |
| **Mac-native** | Notifications with reply. Dock badge. Menu bar mode. Spotlight. Handoff. Multi-window. |
| **Quiet** | No electron memory hog. No web view battery drain. Sits in the background like Mail.app. |
| **Offline-resilient** | Persisted history. Auto-reconnect. Offline compose queue. |

---

## Estimated Effort

| Phase | Scope | Estimate |
|-------|-------|----------|
| Phase 1 — Core Chat | Connection, auth, channels, DMs, history, compose | 2-3 weeks |
| Phase 2 — Delight | Edit/delete/reply, E2EE, media, search, macOS integration | 2-3 weeks |
| Phase 3 — Power User | Multi-server, customization, advanced features | 2-3 weeks |

Phase 1 is fast because we're reusing the entire SDK + FFI + auth flow. The iOS `AppState.swift` (900 lines) handles all the IRC ↔ UI bridging — most of it ports directly. The views are new but SwiftUI macOS layouts are straightforward with `NavigationSplitView`.

---

## Open Questions

1. **App Store vs direct distribution?** Direct (Developer ID signed + notarized) is simpler for v1. App Store later for auto-updates + discoverability.
2. **Shared Swift package now or later?** Copy from iOS for Phase 1, extract shared package for Phase 2.
3. **Menu bar mode?** Lightweight "always running" mode (like Slack's menu bar) — Phase 2 or 3.
4. **Catalyst vs native?** Pure native. Catalyst would be faster but the result is always mediocre on Mac. We want best-of-class.

---

## References

- `freeq-sdk/` — Core Rust SDK (IRC, SASL, E2EE)
- `freeq-sdk-ffi/` — UniFFI bindings (`.udl` + Rust wrapper)
- `freeq-ios/` — iOS app (SwiftUI, same FFI layer)
- `freeq-app/` — Web client (React, feature reference)
- `freeq-android/` — Android app (Jetpack Compose, same FFI)
- `freeq-windows-core/` + `freeq-windows-app/` — Windows app (C# + Rust FFI)
