# Freeq.WinUI — Feature Parity TODOs

Features present in `freeq-app` (web client) that are not yet implemented in `Freeq.WinUI`.
Grouped by priority. Web reference files are relative to `freeq-app/src/`.

---

## P0 — Core Messaging

- [x] **Message editing** — Up-arrow on empty ComposeBox loads last own message for editing. Edit bar shown with cancel. Submits `+draft/edit=<msgid>` PRIVMSG. Incoming edits update `Content`/`IsEdited` in-place via `INotifyPropertyChanged`. `(edited)` label shown.
  - `Controls/ComposeBox.xaml(.cs)`, `Controls/MessageList.xaml(.cs)`, `Services/IrcClient.cs`, `ViewModels/MainViewModel.cs`, `Models/MessageModel.cs`

- [x] **Message deletion** — Right-click → Delete sends `+draft/delete=<msgid>` TAGMSG. Incoming deletes set `IsDeleted=true` in-place. Deleted messages render as italic dimmed placeholder.
  - `Controls/MessageList.xaml(.cs)`, `Services/IrcClient.cs`, `ViewModels/MainViewModel.cs`

- [x] **Slash commands** — ComposeBox sends slash commands through `MainViewModel.HandleSlashCommand()`:
  `/me`, `/join`, `/part`, `/topic`, `/invite`, `/kick`, `/op`, `/deop`, `/voice`, `/mode`, `/msg`, `/whois`, `/away`, `/pins`, `/raw`, `/help`
  - `ViewModels/MainViewModel.cs`

- [x] **Nick autocomplete** — Tab key in ComposeBox cycles through nicks in the current channel that match the partial word before the caret. Appends `": "` when completing at line start (IRC convention).
  - `Controls/ComposeBox.xaml.cs`

- [x] **Compose box UX improvements**
  - Shift+Enter → inserts newline (`AcceptsReturn=True`; plain Enter still sends)
  - Up-arrow on empty input → begin editing last own message
  - Escape → cancel edit / close autocomplete
  - `Controls/ComposeBox.xaml(.cs)`

- [x] **Typing indicators** — Sends `@+typing=active TAGMSG` on keystroke; auto-stops after 10 s idle or on send. Inbound typing state tracked per-nick per-channel with 10 s auto-expiry. "X is typing…" shown above compose box.
  - `Controls/ComposeBox.xaml(.cs)`, `Services/IrcClient.cs`, `ViewModels/MainViewModel.cs`

---

## P1 — Channel & Navigation

- [x] **Channel browser** — Sidebar `+` flyout → Browse Channels: sends LIST, opens dialog with name/member count/topic, fuzzy filter, join from list.
  - `Controls/Sidebar.xaml.cs`, `Services/IrcClient.cs`, `ViewModels/MainViewModel.cs`, `Models/ChannelListEntry.cs`

- [x] **Channel creation** — Sidebar `+` flyout → New Channel: prompts for name, sends JOIN (server auto-creates).
  - `Controls/Sidebar.xaml`, `Controls/Sidebar.xaml.cs`

- [x] **Channel muting** — Right-click channel in sidebar → Mute/Unmute. Suppresses unread badges. Persisted to `%LOCALAPPDATA%\Freeq\settings.json`.
  - `Controls/Sidebar.xaml`, `Controls/Sidebar.xaml.cs`, `Services/AppSettings.cs`, `ViewModels/MainViewModel.cs`

- [x] **Pinned messages** — Pins button (📌) in TopBar opens dialog; sends `PINS #channel` to server; shows pinned message IDs, pinned-by, and timestamp.
  - `Controls/TopBar.xaml`, `Controls/TopBar.xaml.cs`, `Services/IrcClient.cs`, `Models/PinEntry.cs`

- [x] **Quick switcher** — Ctrl+K opens fuzzy-search dialog over all joined channels and DMs; Enter or double-click to navigate.
  - `MainWindow.xaml.cs`

- [x] **Keyboard channel switching**
  - Alt+1…9, Alt+0 → jump to nth channel in sidebar
  - Alt+Up / Alt+Down → previous/next channel
  - `MainWindow.xaml.cs`, `ViewModels/MainViewModel.cs`

- [x] **Channel topic setting** — TopBar topic text is now a clickable button; opens an edit dialog and sends `TOPIC #channel :new topic`.
  - `Controls/TopBar.xaml`, `Controls/TopBar.xaml.cs`

---

## P2 — User Experience

- [x] **User profile popover** — Clicking a nick or avatar opens a profile dialog with nick, DID, Bluesky handle/link, plus op/deop/voice/devoice actions when the current user is an operator.
  - Web: `UserPopover.tsx`

- [x] **Message reactions** — Supports IRCv3 reactions via `TAGMSG` with `+react` and optional `+reply`; renders reaction bubbles under messages and supports click-to-react/context-menu reactions.
  - Web: `MessageList.tsx`, `EmojiPicker.tsx`, `store.ts`

- [x] **Message search** — Ctrl+F opens a search dialog over local message cache with channel context and jump-to-message behavior.
  - Web: `SearchModal.tsx`

- [x] **Message context menu** — Right-click menu includes copy text, copy message ID, edit/delete, quick reactions, bookmark, and share-to-Bluesky actions.
  - Web: `MessageContextMenu.tsx`

- [x] **Reconnect / identity-loss banner** — Dismissible reconnect/identity-loss banner added at top of window.
  - Web: `ReconnectBanner.tsx`

- [x] **MOTD display** — MOTD is parsed from numerics, shown in dismissible banner, and mirrored to server buffer once per session.
  - Web: `MotdBanner.tsx`

- [x] **Away status UI** — Sidebar footer away toggle implemented with optional message; member list shows away markers from `away-notify` updates.
  - Web: `SlashCommands.tsx`, `MemberList.tsx`

- [x] **Toast / snackbar notifications** — In-app toast/snackbar added for message and moderation actions.
  - Web: `Toast.tsx`

- [x] **Windows toast notifications** — Mention toasts added when app window is not foreground, with AppNotification fallback path.
  - Web: `lib/notifications.ts` (browser Notification API equivalent)

- [x] **Taskbar badge** — Mention count updates window title and attempts badge updates via `BadgeNotification`/`BadgeUpdater` with safe fallback for unpackaged runtime.

---

## P3 — Rich Media & Content

- [x] **File / image upload** — ComposeBox supports attach button, drag-and-drop, and clipboard file paste; uploads to `/api/v1/upload` and sends resulting URL.
  - Web: `ComposeBox.tsx`, `FileDropOverlay.tsx`

- [x] **Image lightbox** — Inline image previews open a full-size dialog with zoom slider.
  - Web: `ImageLightbox.tsx`

- [x] **Link previews** — Fetches OpenGraph metadata from `/api/v1/og` and renders compact preview cards.
  - Web: `LinkPreview.tsx`

- [x] **Bluesky post embeds** — Detects `bsky.app/profile/.../post/...` links and renders lightweight embedded post cards.
  - Web: `BlueskyEmbed.tsx`

- [x] **Markdown rendering** — Message renderer parses markdown syntax (bold, italic, inline code, fenced code, links) and renders rich text.
  - Web: `MarkdownRenderer.tsx`

- [x] **Rich text compose toolbar** — ComposeBox has Bold/Italic/Code/Link formatting controls that wrap selected text.
  - Web: `FormatToolbar.tsx`

- [x] **Audio / video / voice message playback** — Detects media URLs and renders inline `MediaPlayerElement` playback controls.
  - Web: `MessageList.tsx`

---

## P4 — Settings & Preferences

- [x] **Settings panel** — TopBar gear opens a settings dialog with persisted preferences.
  - Web: `SettingsPanel.tsx`

- [x] **Theme toggle** — Added light/dark/system theme options with runtime resource-dictionary switching.
  - Web: `SettingsPanel.tsx`, `store.ts`

- [x] **Message density** — Cozy/Default/Compact modes now alter message spacing and compact avatar visibility.
  - Web: `SettingsPanel.tsx`, `store.ts`

- [x] **Show/hide join-part messages** — Global toggle implemented; join/part system lines can be suppressed.
  - Web: `SettingsPanel.tsx`, `store.ts`

- [x] **External media loading** — Global toggle controls automatic inline loading of external media and previews.
  - Web: `SettingsPanel.tsx`, `store.ts`

- [x] **Notification preferences** — Settings now control mention Windows toasts and notification sounds.
  - Web: `SettingsPanel.tsx`

- [x] **Keyboard shortcuts reference** — `Ctrl+/` opens a keyboard shortcut overlay.
  - Web: `KeyboardShortcuts.tsx`

---

## P5 — Moderation & Advanced IRC

- [x] **Channel settings panel** — Ops can open a panel (from TopBar) to manage: topic, modes, join policy, bans, invites.
  - Web: `ChannelSettingsPanel.tsx`

- [x] **Audit timeline** — View a chronological log of governance events (kicks, bans, mode changes, pins) for a channel.
  - Web: `AuditTimeline.tsx`

- [x] **Ban / invite management** — UI to view, add, and remove channel bans (`+b`) and invite exceptions (`+I`).
  - Web: `ChannelSettingsPanel.tsx`

- [x] **Message bookmarks** — Bookmark any message; view bookmarks in a panel. Store bookmarks locally.
  - Web: `BookmarksPanel.tsx`, `MessageContextMenu.tsx`

- [x] **Coordination cards** — Render structured task/event messages (those carrying coordination metadata) as rich cards instead of plain text.
  - Web: `CoordinationCards.tsx`

- [x] **E2EE indicators** — Show a lock icon in TopBar for encrypted channels (+E mode). Show E2EE status in DM headers. Offer safety number comparison in user popover.
  - Web: `TopBar.tsx`, `UserPopover.tsx`

---

## Out of Scope (web/mobile-only)

These features exist in `freeq-app` but don't apply to a native Windows desktop client:

- PWA / service worker / install prompt
- Mobile responsive layout and swipe gestures
- Virtual keyboard avoidance
- Browser Notification API (replaced by WinRT toasts above)
