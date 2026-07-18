# Plan: Bring iOS app up to parity with web/SDK (catch-up through 2026-04-25)

**Status:** draft, scoped from a survey of the last ~30 days of commits (231 commits across all clients since 2026-03-25).

## Scope window

Last iOS-touching commits in main:

| Date | Commit | What it did |
|------|--------|-------------|
| 2026-04-19 | c4de108 | account-tag → DID-based avatar prefetch (iOS got the FFI field + the prefetch call) |
| 2026-04-07 | 1f83c40 | Build script with `av-native` feature + audio framework deps |
| 2026-04-07 | ce0688b | CallView + speaker icon + voice session integration |
| 2026-04-07 | ad82e64 | CallView UI + AppState AV integration |
| 2026-04-07 | ac11315 | AV FFI tests; Tokio runtime fix for `LocalBroadcast` |
| 2026-04-07 | 5abe33f | `FreeqAv` FFI type for voice via MoQ SFU |
| 2026-03-26 | a19f825 | Keep broker sessions for 14-day login window |

Everything since 2026-04-19 has skipped iOS. The web client and SDK have moved meaningfully forward in that window.

## Confirmed gap inventory

### A. Picked up automatically by rebuilding `FreeqSDK.xcframework`

These are SDK-level commits. They flow into iOS the moment the xcframework is regenerated against the current `freeq-sdk` and `freeq-sdk-ffi`:

1. **Wire-vs-cache stale-state fixes** (1dbcbc4, 2026-04-25) — four classes of bugs where the SDK kept stale state after disconnect/SASL events.
2. **SASL 904 → hard tear-down** (0487e3b, 2026-04-25) — previously the SDK silently registered as guest after auth failure; now it disconnects.
3. **Message signing** (P0 in CLAUDE.md TODO) — SDK auto-generates an ed25519 session keypair after SASL, sends `MSGSIG <pubkey>`, and stamps every PRIVMSG with `+freeq.at/sig`. The FFI exposes `IrcMessage.isSigned`. iOS gets this for free on rebuild.
4. **DPoP nonce retry for SASL** (CLAUDE.md TODO, P1) — server emits a fresh nonce, SDK retries up to 3 times.
5. **`account` field on `IrcMessage`** (already shipped to iOS in c4de108) — used for avatar prefetch.

**Action:** rebuild `FreeqSDK.xcframework` from current `freeq-sdk-ffi` and re-run `uniffi-bindgen` so `Generated/freeq.swift` matches.

### B. iOS code work (the actual catch-up)

1. **Show "signed" badge on messages.**
   - `IrcMessage.isSigned` already arrives over the FFI (`Generated/freeq.swift:1459`).
   - `ChatMessage` struct in `AppState.swift` does not carry it. Add `var isSigned: Bool = false`, populate it in `SwiftEventHandler` when constructing `ChatMessage`, and render a small lock glyph next to the timestamp in `MessageListView.swift` (analogous to the verified DID badge in `FreeqLogo.swift`).

2. **Reaction toggle (unreact).**
   - Wire shape (Apr 25, a431fe5): `TAGMSG <target> +freeq.at/unreact=<emoji> +reply=<msgid>`.
   - Outgoing: in `MessageListView.swift` reactions UI, when the current nick is in the pill's nick set, send `unreact` instead of re-`react`.
   - Incoming: extend the TAGMSG handler in `AppState.swift` (~line 1133) to recognise `+freeq.at/unreact` and remove the sender's nick from `messages[idx].reactions[emoji]`; if the set empties, drop the emoji entry.
   - Mirror logic in `ThreadView.swift` reactions UI.

3. **AV session lifecycle via `+freeq.at/av-state` TAGMSGs.**
   - Today `startOrJoinVoice` blindly waits 2 s then polls a REST endpoint for the session id (`AppState.swift:226-244`). Web replaced this with the server's own `av-state=started` TAGMSG carrying `+freeq.at/av-id` and `+freeq.at/av-actor`.
   - Add `@Published var activeAvSessions: [String: String] = [:]` and `pendingAvStart: Set<String>`.
   - In the TAGMSG handler, on `av-state=started` populate `activeAvSessions[channel]`; if we triggered the start (we're in `pendingAvStart` and the actor is us), call `startCall` immediately. On `av-state=ended` clear the entry and tear down our own call if we were in it.
   - Send `+freeq.at/av-join` (with `av-id`) when entering an existing call; send `+freeq.at/av-leave` on `leaveCall()`. Mirror what `freeq-app/src/irc/client.ts:254-275` does.
   - Drop the 2-second `asyncAfter` polling fallback once the TAGMSG path is wired.

4. **Auto-end stale AV sessions / restart bridge on rejoin.**
   - Web fixes ecd1c8f (REST polling for session discovery) and 30c1add (bridge cleanup on disconnect / restart on join). Verify iOS does the right thing when:
     - A call is active, the device backgrounds, then returns.
     - Network drops mid-call.

5. **Inbound PIN/UNPIN propagation.**
   - iOS sends `PIN <channel> <msgid>` (`MessageListView.swift:326`) but there's no handler for the inbound `pinAdded` / `pinRemoved` event that the SDK emits. Today the user only sees their own pin if `PinnedMessagesView` re-fetches over REST.
   - Add `case .pinAdded` / `.pinRemoved` to `SwiftEventHandler` (mirror `freeq-app/src/irc/client.ts:467`) and update `ChannelState.pins`.

6. **CHATHISTORY auto-fetch on scroll-up.**
   - `MessageListView.swift` shows messages but the `BEFORE timestamp` query in `AppState.swift:568` is only invoked manually. Hook it to a scroll-position listener so swiping up loads older history. (Not a regression, but the UX is now standard on web.)

7. **Sort-merge CHATHISTORY into live messages.**
   - `appendIfNew` already inserts in timestamp order (`AppState.swift:55-69`). Confirm batch ingestion (`batches`) feeds through the same path — if batches dump straight to `messages.append(...)`, the Apr 22 fix from web (4c62529) needs to be replicated.

### C. UX polish features iOS lacks (from web, lower priority)

Each of these is a separate, optional task — list here so we can decide which to do:

- **Speaker icon next to channel name** when an AV session is active (web 994369c). iOS has the icon in `TopBarView` but it's tied to `isInCall`, not the channel-level `activeAvSessions`.
- **Inline call panel** replacing the modal `CallView` (web 236d551). Big UX change; defer until the lifecycle/protocol work in B.3 is solid.
- **Quick switcher** (Cmd+K equivalent on iPad keyboard).
- **Slash commands autocomplete** (`/pins`, `/me`, `/topic`, `/nick`). Right now `ComposeView.swift:545-561` parses slash commands but offers no completion menu.
- **Markdown rendering / format toolbar** in the compose box.
- **Bookmarks panel** (web `BookmarksPanel.tsx`).

### D. iOS-only sanity items

- **Unstash and review the WIP multi-profile picker.** The autostashed working tree (in the parent repo) added a production/staging/custom server picker in `SettingsTab.swift` plus `ServerConfig.Profile`. This worktree intentionally drops it so we boot to production unconditionally; if we ever want a staging toggle it should be a debug-build-only switch (`#if DEBUG`), not a user-visible setting.
- **Verify deleted views were intentional.** The same stash deletes `ChatView.swift` and `TopBarView.swift`. Whatever consolidated them needs to either land here or be re-applied off this worktree.
- **Bump `FreeqSDK.xcframework` build pipeline.** Confirm the build script in `1f83c40` still works after the SDK upgrade and that `Generated/freeq.swift` regenerates cleanly.

## Suggested phasing

| Phase | What | Why first |
|-------|------|-----------|
| 1 | Rebuild `FreeqSDK.xcframework` against current SDK; regenerate `freeq.swift`; smoke-test connect/SASL/PRIVMSG | Unlocks signing, SASL fixes, stale-state fixes — foundation everything else depends on |
| 2 | B.1 (signed badge), B.2 (unreact), B.5 (inbound PIN) | Small, high-visibility, no protocol risk |
| 3 | B.3 + B.4 (AV lifecycle TAGMSGs, leave/join, stale cleanup) | Removes the 2-second polling hack and brings AV behavior in line with web |
| 4 | B.6 + B.7 (CHATHISTORY) | Quality-of-life; needs scroll-position plumbing |
| 5 | C.* polish, prioritized by usage | Optional |

## Open questions

- Do we want signing on by default in the iOS build (it is for web)? Assumed yes — iOS gets it on Phase 1 rebuild.
- Should the staging/custom server picker (currently stashed) come back as a `#if DEBUG`-only Settings toggle? Worth answering before Phase 2.
- Any iOS App Store submission constraints we need to think about before adding camera/mic UI changes in C?

## Pre-work landed in this worktree

- `freeq-ios/freeq/Models/AppState.swift` — `init()` no longer reads the legacy `freeq.server` `UserDefaults` key. The app now always boots against `ServerConfig.ircServer` (= `irc.freeq.at:6667`) and proactively clears any stale value, so devices that previously ran a staging build silently move back to production on next launch.
