# FreeQ UI Components Specification

## Phoenix Requirements

- REQUIREMENT: The main UI layout (sidebar, main content, user list) MUST be hidden during authentication - only the auth screen visible

- REQUIREMENT: When authentication completes, the main UI layout MUST become visible by setting widget.visible = True on all regions

- REQUIREMENT: On AuthCompleted, _populate_default_data() MUST create a NEW buffers dict (not mutate existing) to trigger BufferSidebar.watch_buffers() reactive update

- REQUIREMENT: The _populate_default_data() method MUST use: self.app_state.buffers = {"console": buffer} (new dict) not self.app_state.buffers["console"] = buffer (mutation)

- REQUIREMENT: On AuthCompleted, the app MUST populate app_state.buffers with at least one default buffer (e.g., 'Console' or '#general') so the UI has content to display

- REQUIREMENT: On AuthCompleted, the app MUST set app_state.ui.active_buffer_id to the first available buffer so widgets know which buffer to display

- REQUIREMENT: All widgets (BufferSidebar, MessageList, UserList) MUST react to app_state changes by implementing watch_* methods for their reactive data

- REQUIREMENT: The app MUST call widget.refresh() or update reactive properties after auth completes to trigger widget re-rendering with new data

- REQUIREMENT: BufferSidebar MUST implement watch_buffers() to re-render when buffers change

- REQUIREMENT: When authentication completes, the app MUST explicitly call sidebar.update_buffers(app_state.buffers) to force the sidebar to re-render with the newly populated channel list

- REQUIREMENT: The BufferSidebar MUST be explicitly refreshed after _populate_default_data() is called because the reactive buffers dict reference does not trigger watch_buffers when mutated

- REQUIREMENT: When auto-login completes in on_mount(), the app MUST explicitly call buffer_sidebar.watch_buffers(app_state.buffers) to force sidebar refresh because Textual compose() runs before on_mount() and sidebar was composed with empty buffers

- REQUIREMENT: When AuthCompleted fires, the app MUST explicitly call buffer_sidebar.watch_buffers(app_state.buffers) after _populate_default_data() to ensure sidebar shows populated buffers

- REQUIREMENT: When guest mode starts, the app MUST explicitly call buffer_sidebar.watch_buffers(app_state.buffers) after _populate_default_data() to ensure sidebar shows guest buffers

- REQUIREMENT: MessageList MUST implement watch_messages() or watch the active buffer to re-render when messages change

- REQUIREMENT: UserList MUST implement watch_users() to re-render when users change

- REQUIREMENT: The Header and Footer MUST be hidden during authentication and visible after authentication completes

- REQUIREMENT: Visibility MUST be controlled by Python widget.visible property, NOT CSS display classes - CSS descendant selectors are unreliable in Textual

- REQUIREMENT: The auth screen MUST use ModalScreen for true fullscreen coverage (covers docked Header/Footer widgets)

- REQUIREMENT: On AuthCompleted message, the app MUST update state, pop auth screen, set all region widgets visible=True, and focus input bar

- REQUIREMENT: The _update_ui_from_state method MUST check is_mounted before accessing children to avoid lifecycle errors

- REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs and pass to super().__init__()

- CONSTRAINT: Textual's Input widget does NOT accept a 'multiline' parameter - do NOT pass multiline=True/False to Input()

- CONSTRAINT: All Textual Messages MUST call super().__init__() in their __init__ method

- CONSTRAINT: When importing both Textual's `Message` event class AND a chat `Message` model, Textual's Message MUST be aliased (e.g., `from textual.message import Message as TextualMessage`) to avoid name collision. Event message classes MUST inherit from TextualMessage, NOT the chat Message model.

- CONSTRAINT: The app.py MUST include entry point block `if __name__ == "__main__": run_app()` for `python -m src.generated.app` to work

## Layout Requirements (Fractional Sizing)

- REQUIREMENT: Layout MUST use pure fractional (fr) units for all regions. Sidebar: 1fr, Main content: 4fr, User list: 1fr. This gives message content 4x the space of each sidebar.

- REQUIREMENT: Each sidebar MUST have max-width constraint (e.g., max-width: 25 for sidebar, max-width: 20 for user list) to prevent excessive growth at large terminal sizes while still using fr units.

- REQUIREMENT: MessageList CSS height MUST be '1fr' NOT '100%'. Using height: 100% causes MessageList to take all available space in Vertical container, pushing InputBar out of view. Using height: 1fr allows MessageList to take remaining space while InputBar gets its natural height.

- REQUIREMENT: MessageList MUST implement incremental message updates in refresh_messages(). Instead of remove_children() + remounting all widgets (which blocks UI for 16+ seconds with 20+ messages), only add NEW message widgets that don't exist yet. Preserve existing widgets and only mount new ones.

- REQUIREMENT: MessageList refresh_messages() MUST batch widget creation for performance. Create all MessageWidget instances first, then mount them in a loop, rather than interleaving creation and mounting.

- REQUIREMENT: MessageList refresh_messages() MUST show ALL messages in the buffer, not just those within visible_range. The visible_range is for virtualization optimization but new messages must always be mounted regardless of scroll position. Use `target_messages = self.messages` not `self.messages[start:end]`.

## Sidebar Display Requirements

- REQUIREMENT: BufferSidebar MUST prevent double ## in channel names. When displaying CHANNEL type buffers, only add # prefix if buffer.name does NOT already start with #. This prevents ##test when buffer.name is already '#test'.

## AuthScreen UX Requirements

- REQUIREMENT: AuthScreen MUST support Enter key to submit auth form. Users can type their handle and press Enter instead of clicking Connect button. Implement @on(events.Key) handler that calls _start_authentication() when event.key == 'enter'.

- REQUIREMENT: AuthScreen MUST NOT show 'Remember Login' checkbox. Credentials MUST always be saved automatically after successful authentication (no checkbox needed). This simplifies UX and reduces user confusion.

## Part 1: Abstract System Design

### UI States (PhoenixUI Theory)

```
State AUTHENTICATING:
  description: "User must complete OAuth authentication"
  blocking: true
  
State CONNECTING:
  description: "Authenticated, establishing IRC connection"
  loading: true
  
State CONNECTED:
  description: "Fully operational, showing chat interface"
  
State DISCONNECTED:
  description: "Connection lost, showing reconnect option"
```

### Regions (Layout Structure)

```
Region Header:
  geometry: DOCK_TOP(height: 1)
  visibility: {AUTHENTICATING: false, CONNECTING: true, CONNECTED: true, DISCONNECTED: true}
  content: [Clock, Title]

Region Sidebar:
  geometry: PERCENT(25)
  visibility: {AUTHENTICATING: false, CONNECTING: true, CONNECTED: true, DISCONNECTED: true}
  content: [BufferList]

Region MainContent:
  geometry: PERCENT(60)
  visibility: {AUTHENTICATING: false, CONNECTING: true, CONNECTED: true, DISCONNECTED: true}
  content: [MessageList, InputBar]

Region UserList:
  geometry: PERCENT(15)
  visibility: {AUTHENTICATING: false, CONNECTING: true, CONNECTED: true, DISCONNECTED: true}
  content: [UserList]

Region Footer:
  geometry: DOCK_BOTTOM(height: 1)
  visibility: {AUTHENTICATING: false, CONNECTING: true, CONNECTED: true, DISCONNECTED: true}
  content: [StatusBar, KeyHints]
```

### Overlays (Modal Layers)

```
Overlay Authentication:
  trigger: state == AUTHENTICATING
  presentation: FULLSCREEN
  dismissable: false
  content: [HandleInput, ConnectButton, GuestButton, CancelButton]

Overlay ThreadPanel:
  trigger: event == ShowThread
  presentation: MODAL_RIGHT(width: 40%)
  dismissable: true

Overlay EmojiPicker:
  trigger: event == OpenEmojiPicker
  presentation: MODAL_CENTERED
  dismissable: true

Overlay ContextMenu:
  trigger: event == ShowContextMenu
  presentation: INLINE_AT_CURSOR
  dismissable: true
```

### Transitions

```
Transition AUTHENTICATING -> CONNECTING:
  on: AuthCompleted
  animation: FADE
  duration: 300ms
  critical_steps:
    1. Update app_state.session.authenticated = True
    2. Update app_state.ui.auth_overlay_visible = False  # CRITICAL
    3. Pop auth screen (ModalScreen) - already dismissed by AuthScreen
    4. Call _update_ui_from_state()  # Sets widget.visible = True
    5. Focus input bar
  
  implementation_note: |
    CRITICAL: Use widget.visible property, NOT CSS classes.
    CSS descendant selectors don't work reliably in Textual.
    Explicitly set visible=True on #main-layout, #sidebar, 
    #main-content, #user-list-panel, Header, Footer.

Transition AUTHENTICATING -> AUTHENTICATING (Guest):
  on: GuestModeRequested
  animation: FADE
  duration: 200ms
  critical_steps:
    1. Update app_state.session.authenticated = True
    2. Update app_state.ui.auth_overlay_visible = False  # CRITICAL
    3. Update app_state.authentication.is_guest = True
    4. Call _update_ui_from_state()
    5. Pop auth screen
```

### State Visibility Rules (MUST be implemented)

```python
# CRITICAL: Use Textual's reactive 'visible' property, NOT CSS display
# CSS descendant selectors are unreliable in Textual

Rule MainLayoutVisibility:
  method: _update_ui_from_state()
  implementation: |
    # Get widgets and set visible property directly
    main_layout = self.query_one("#main-layout", Horizontal)
    sidebar = self.query_one("#sidebar", BufferSidebar)
    main_content = self.query_one("#main-content", Vertical)
    user_list = self.query_one("#user-list-panel", UserList)
    
    # Show main UI only when auth overlay is hidden
    show_main = not state.ui.auth_overlay_visible
    
    main_layout.visible = show_main
    sidebar.visible = show_main
    main_content.visible = show_main
    user_list.visible = show_main
    
    # Header/Footer visibility
    try:
        self.query_one(Header).visible = show_main
        self.query_one(Footer).visible = show_main
    except: pass
```

### CSS Rules (Simplified - no descendant selectors)

```css
/* Main layout - always composed, visibility controlled by Python */
FreeQApp > #main-layout {
    width: 100%;
    height: 100%;
    layout: horizontal;
}

/* Regions - always composed, visibility controlled by Python */
FreeQApp > #main-layout > #sidebar {
    width: 25%;
    height: 100%;
    border-right: solid $primary;
}

FreeQApp > #main-layout > #main-content {
    width: 60%;
    height: 100%;
}

FreeQApp > #main-layout > #user-list-panel {
    width: 15%;
    height: 100%;
    border-left: solid $primary;
}
```

### Invariants

```
Invariant SingleFullscreenOverlay:
  check: count(overlays.where(presentation == FULLSCREEN && visible)) <= 1

Invariant AuthBeforeMainUI:
  check: !authenticated implies !main_layout.visible

Invariant InitialStateApplied:
  check: on_mount() calls update_ui_from_state(initial_state)
```

---

## Part 2: Implementation Guidance (Textual TUI)

### State Machine Implementation

```python
class AppState(Enum):
    AUTHENTICATING = "authenticating"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"

class FreeQApp(App):
    state = reactive(AppState.AUTHENTICATING)
    
    def watch_state(self, state: AppState):
        """React to state changes."""
        self._update_ui_from_state()
```

### Fullscreen Overlay Pattern (ModalScreen)

```python
# CRITICAL: Use ModalScreen for true fullscreen (covers Header/Footer)
# Regular widgets with layer:overlay CANNOT cover docked widgets

class AuthScreen(ModalScreen):
    """Authentication screen - truly fullscreen."""
    
    DEFAULT_CSS = """
    AuthScreen {
        align: center middle;
        background: $surface-darken-2;
    }
    """
    
    @on(Button.Pressed, "#connect-btn")
    def on_connect(self):
        # Start OAuth and poll for completion
        flow = BrokerAuthFlow(self.broker_url)
        result = flow.start_login(handle)
        
        import webbrowser
        webbrowser.open(result["url"])  # Open browser immediately
        
        # Poll in background thread
        self.start_polling(result["session_id"])
    
    def on_auth_complete(self, result):
        """Handle successful auth."""
        self.app.post_message(AuthCompleted(...))
        self.dismiss()  # Remove auth screen


class AuthCompleted(Message):
    """Auth completed successfully."""
    def __init__(self, handle: str, did: str, nick: str, broker_token: str):
        super().__init__()  # REQUIRED for Textual messages
        self.handle = handle
        self.did = did
        self.nick = nick
        self.broker_token = broker_token
```

### Auth Completion Flow (CORRECT Textual Pattern)

Textual's screen stack and message system require this exact sequence:

```python
# File: screens/auth_screen.py - Post message, then dismiss

class AuthScreen(ModalScreen):
    def on_auth_complete(self, result):
        """OAuth complete - post message then dismiss."""
        session = self.flow.refresh_session(result["broker_token"])
        
        # Post message FIRST (queued for processing)
        self.app.post_message(AuthCompleted(
            handle=session.get("handle", ""),
            did=session.get("did", ""),
            nick=session.get("nick", ""),
            broker_token=result["broker_token"]
        ))
        
        # CRITICAL: Dismiss screen immediately after posting message
        # This closes the AuthScreen ModalScreen and returns to main UI
        self.dismiss()


class AuthCompleted(Message):
    """Auth completed successfully."""
    def __init__(self, handle: str, did: str, nick: str, broker_token: str):
        super().__init__()  # REQUIRED for Textual messages
        self.handle = handle
        self.did = did
        self.nick = nick
        self.broker_token = broker_token
```

### Auth Handler in Main App

```python
# File: app.py - Handler for AuthCompleted

class FreeQApp(App):
    def on_auth_screen_auth_completed(self, event: AuthCompleted):
        """Handle auth completion.
        
        CRITICAL SEQUENCE:
        1. Update session state
        2. Update UI state (auth_overlay_visible = False)
        3. Update UI widgets (_update_ui_from_state)
        4. Mark as connected
        5. Focus input
        """
        # 1. Update SESSION state
        self.app_state.session.authenticated = True
        self.app_state.session.handle = event.handle
        self.app_state.session.did = event.did
        self.app_state.session.nickname = event.nick
        self.app_state.session.web_token = event.broker_token
        
        # 2. Update UI state (CRITICAL: this controls main layout visibility)
        self.app_state.ui.auth_overlay_visible = False
        
        # 3. Sync UI widgets with new state
        # This adds 'visible' class to #main-layout
        self._update_ui_from_state(self.app_state)
        
        # 4. Mark connection as ready
        self.app_state.connection.connected = True
        self._update_ui_from_state(self.app_state)
        
        # 5. Focus input bar after refresh
        self.call_after_refresh(self._focus_input)
    
    def _focus_input(self):
        try:
            self.query_one("#input-bar", InputBar).focus()
        except (NoMatches, ScreenStackError):
            pass
```

### Main Layout CSS Visibility (CRITICAL FIX)

The main layout AND all its children must become visible together. CSS descendant selectors ensure children show when parent has `.visible`:

```python
# File: app.py - CSS string

CSS = """
/* Main layout container - hidden by default */
FreeQApp > #main-layout {
    display: none;
    width: 100vw;
    height: 100vh;
}

/* When visible: show container with horizontal layout */
FreeQApp > #main-layout.visible {
    display: block;
    layout: horizontal;
}

/* Children are hidden by default (inside hidden parent) */
FreeQApp > #main-layout > #sidebar,
FreeQApp > #main-layout > #main-content,
FreeQApp > #main-layout > #user-list-panel {
    display: none;
}

/* CRITICAL: When parent has .visible, children become visible */
FreeQApp > #main-layout.visible > #sidebar,
FreeQApp > #main-layout.visible > #main-content,
FreeQApp > #main-layout.visible > #user-list-panel {
    display: block;
}
"""
```

**Why this matters**: In the previous implementation, only `#main-layout` got the `visible` class, but its children (`#sidebar`, `#main-content`, `#user-list-panel`) had their own `display: none` that wasn't being overridden. The descendant selector pattern ensures all children become visible when the parent is visible.

### Docked Header/Footer Layout Pattern (CRITICAL)

When using docked Header and Footer widgets, the main layout MUST account for their space or they will overlap:

```python
# File: app.py - CSS string

CSS = """
/* Docked header at top */
FreeQApp > Header {
    dock: top;
    height: 1;
}

/* Docked footer at bottom */
FreeQApp > Footer {
    dock: bottom;
    height: 1;
}

/* Main layout must reserve space for docked header/footer */
FreeQApp > #main-layout {
    width: 100vw;
    height: 100vh;
    /* CRITICAL: Reserve space for docked header (height: 1) and footer (height: 1) */
    margin-top: 1;
    margin-bottom: 1;
}

/* Children fill the parent height, NOT 100vh */
FreeQApp > #main-layout.visible > #sidebar {
    height: 100%;  /* NOT 100vh - fills parent after margins */
    width: 25%;
}

FreeQApp > #main-layout.visible > #main-content {
    height: 100%;  /* NOT 100vh */
    width: 60%;
}

FreeQApp > #main-layout.visible > #user-list-panel {
    height: 100%;  /* NOT 100vh */
    width: 15%;
}
"""
```

**Why this matters**: Docked widgets (Header, Footer) are positioned ABOVE the normal layout flow. If the main layout uses `height: 100vh`, it will extend under the docked widgets. The margins ensure the main layout is positioned BETWEEN the docked header and footer. Children should use `height: 100%` to fill the parent, NOT `height: 100vh` which would ignore the parent's margins.

### Explicit Display Control Pattern

When CSS descendant selectors fail due to specificity issues, explicitly set display in Python:

```python
def _update_ui_from_state(self, state: AppState) -> None:
    """Update UI with explicit display control."""
    
    if not state.ui.auth_overlay_visible:
        # Force children visible (CSS specificity fallback)
        try:
            sidebar = self.query_one("#sidebar", BufferSidebar)
            sidebar.styles.display = "block"
        except (NoMatches, ScreenStackError):
            pass
        
        try:
            main_content = self.query_one("#main-content", Vertical)
            main_content.styles.display = "block"
        except (NoMatches, ScreenStackError):
            pass
        
        try:
            user_list = self.query_one("#user-list-panel", UserList)
            user_list.styles.display = "block"
        except (NoMatches, ScreenStackError):
            pass
        
        # Force full layout refresh
        self.refresh(layout=True)
```

### Widget Initialization Pattern

Widgets should have visible content and borders:

```python
class BufferSidebar(Static):
    DEFAULT_CSS = """
    BufferSidebar {
        width: 100%;
        height: 100%;
        border: solid $primary;  /* Visible for debugging */
    }
    """
    
    def on_mount(self) -> None:
        """Initialize with default content."""
        # Ensure visible content exists
        if not self.app_state.buffers:
            self.app_state.buffers["console"] = BufferState(...)
        self.update_buffers(list(self.app_state.buffers.values()))
```

### Message Event Pattern

```python
# All event messages MUST inherit from Message + call super().__init__()
class AuthenticationRequested(Message):
    def __init__(self, handle: str, broker_url: str, session_id: str = ""):
        super().__init__()  # REQUIRED
        self.handle = handle
        self.broker_url = broker_url
        self.session_id = session_id

# Handler naming: on_{sender}_{event_type}
def on_auth_screen_authentication_requested(self, event):
    """Handle auth request from AuthScreen."""
    self.app_state.authentication.auth_handle = event.handle
```

### Partial Overlay Pattern (CSS layer:overlay)

```python
# For non-fullscreen overlays (emoji picker, context menu):
# Use layer:overlay CSS, NOT ModalScreen

class EmojiPicker(Static):
    DEFAULT_CSS = """
    EmojiPicker {
        layer: overlay;
        display: none;  /* Hidden by default */
    }
    EmojiPicker.visible {
        display: block;
    }
    """
    
    def show(self):
        self.add_class("visible")
    
    def hide(self):
        self.remove_class("visible")
```

### Background Polling Pattern

```python
# For long-running operations (OAuth, network):
# Poll in background thread, update UI on main thread

def start_polling(self, session_id: str):
    """Poll for OAuth completion in background thread."""
    import threading
    import time
    
    def poll():
        for _ in range(120):  # 2 minute timeout
            time.sleep(1)
            result = self.flow.poll_auth_result(session_id)
            if result:
                # Update UI on main thread
                self.app.call_from_thread(
                    lambda: self.on_auth_complete(result)
                )
                return
        # Timeout
        self.app.call_from_thread(
            lambda: self.update_status("Timed out", error=True)
        )
    
    threading.Thread(target=poll, daemon=True).start()
```

### Region Widget Pattern

```python
class SidebarWidget(Static):
    """Sidebar region with reactive visibility."""
    
    visible = reactive(True)
    
    def compose(self):
        yield BufferList()
    
    def watch_visible(self, visible: bool):
        """React to visibility changes."""
        self.styles.display = "block" if visible else "none"

### Application Entry Point Pattern (REQUIRED)

For `python -m src.generated.app` to work, app.py MUST include:

```python
# At the end of app.py:
def run_app(**kwargs):
    """Run the FreeQ TUI application."""
    app = FreeQApp(**kwargs)
    app.run()

# CRITICAL: Entry point for `python -m src.generated.app`
if __name__ == "__main__":
    run_app()
```

Without this block, the app will exit immediately when run with `-m`.
```
