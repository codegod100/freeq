# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build the main app (unpackaged, for development)
dotnet build Freeq.WinUI/Freeq.WinUI.csproj

# Run directly (unpackaged mode — WindowsPackageType=None)
dotnet run --project Freeq.WinUI/Freeq.WinUI.csproj

# Build MSIX package (requires MSBuild / Visual Studio)
msbuild "Freeq.WinUI (Package)/Freeq.WinUI (Package).wapproj" /p:Configuration=Release /p:Platform=x64
```

No test project exists in this repository.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health

## Architecture

This is a WinUI 3 desktop IRC client for the Freeq platform. It targets `.NET 8` with `net8.0-windows10.0.19041.0` and uses **CommunityToolkit.Mvvm** source generators (`[ObservableProperty]`, `[RelayCommand]`).

### Data flow

```
MainWindow (XAML)
  └── MainViewModel          ← single ViewModel; owns all state
        └── IrcClient        ← WebSocket IRC connection (background threads → events)
```

`MainWindow` wires up all Controls by calling `Control.Bind(_vm)`, subscribes to UI events from Controls, and delegates to `_vm` commands. All `IrcClient` events fire on background threads; `MainViewModel` always marshals them back to UI via `_dispatcher.TryEnqueue()`.

### Key files

| File | Purpose |
|------|---------|
| `Services/IrcClient.cs` | WebSocket IRC client. Parses IRCv3 messages, manages CAP negotiation, SASL `ATPROTO-CHALLENGE`, and a `ConcurrentQueue` send loop. |
| `Services/OAuthCallbackServer.cs` | AT Protocol OAuth via the freeq auth broker (`auth.freeq.at`). Starts a local `HttpListener`, opens the browser, waits for the OAuth callback, decodes the base64url payload. |
| `ViewModels/MainViewModel.cs` | All application state. Per-channel message and member dictionaries (`_messagesByChannel`, `_membersByChannel`) are keyed case-insensitively. Pending joins before `001` are queued in `_pendingJoinChannels`. |
| `Controls/ConnectDialog.xaml.cs` | Two-mode connect UI: AT Protocol (OAuth flow) and guest (nick only). Emits `ConnectRequest` via event. |

### Models

- `ChannelModel` — name, kind (`Channel`/`DirectMessage`), topic, unread/mention counts
- `MemberModel` — nick, DID (populated via `extended-join` / `ACCOUNT` / `WHO`), role (`@`/`%`/`+`), `IsVerified` = DID present
- `MessageModel` — id, nick, content, timestamp

### SASL / Auth flow

1. `ConnectDialog` calls `OAuthCallbackServer.StartLogin(handle)` → opens browser to `auth.freeq.at`
2. Callback returns `OAuthResult` with `did`, `pds_url`, `web_token`
3. `MainWindow.OnConnectRequested` calls `_vm.SetSaslCredentials(token, did, pdsUrl, "web-token")`
4. `IrcClient.HandleCap` requests `sasl` cap when token is present
5. On `AUTHENTICATE` challenge from server, `HandleAuthenticate` encodes a JSON payload `{did, method, signature, pds_url}` as base64url and sends it back (chunked at 400 bytes if needed)
6. `903` → `CAP END` → `001` → state transitions to `Authenticated`

### IRCv3 capabilities negotiated

`message-tags`, `server-time`, `batch`, `multi-prefix`, `echo-message`, `account-notify`, `extended-join`, `away-notify`, `draft/chathistory` — plus `sasl` when a token is available.

### Debug logging

`OAuthLog.Write(...)` appends to `%LOCALAPPDATA%\Freeq\oauth-debug.log` and `Debug.WriteLine`. Covers all connection, SASL, and OAuth state transitions.
