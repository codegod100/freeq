# Phoenix UI Theory (PhoenixUI)

A declarative, state-driven UI theory for Phoenix VCS that separates layout structure from rendering behavior.

## Core Concept

UI is declared as a function of application state: `UI = f(State)`
Rather than imperative "show this, hide that", we declare states and their corresponding visual representations.

## Theory Structure

```
PhoenixUI := (States, Regions, Overlays, Transitions, Invariants)
```

### States
Application phases that drive UI presentation:
- `AUTHENTICATING` - User must authenticate
- `CONNECTING` - Authenticated, establishing connection  
- `CONNECTED` - Fully connected, normal operation
- `DISCONNECTED` - Connection lost
- `ERROR` - Error state with user notification

### Regions
Spatial layout areas that exist in all states (but may be invisible):
```
Region := (id, geometry, visibility, content)
  id: String              -- unique identifier
  geometry: Geometry      -- size constraints
  visibility: State -> Bool  -- visibility as function of state
  content: Content        -- what renders inside

Geometry := (width, height, flow)
  width: Percentage | Fixed | Auto
  height: Percentage | Fixed | Auto  
  flow: HORIZONTAL | VERTICAL | DOCK_TOP | DOCK_BOTTOM | OVERLAY

Content := (widgets, layout, data_binding)
```

### Overlays
Modal/interruptive UI layers that capture focus:
```
Overlay := (id, trigger, presentation, content, dismissable)
  trigger: Event | StateChange  -- what shows the overlay
  presentation: FULLSCREEN | MODAL | TOAST | INLINE
  dismissable: Bool | Event    -- how it can be closed
```

### Transitions
Valid state changes and their UI effects:
```
Transition := (from, to, animation, duration)
  from: State
  to: State
  animation: FADE | SLIDE | INSTANT
  duration: Milliseconds
```

### Invariants
Constraints that must hold across all states:
```
Invariant := (description, predicate)
  description: String
  predicate: (State, UI) -> Bool
```

## FreeQ Textual TUI Application

### States
```
State AUTHENTICATING:
  description: "User must complete OAuth authentication"
  
State CONNECTING:
  description: "Authenticated, establishing IRC connection"
  
State CONNECTED:
  description: "Fully operational, showing chat interface"
  
State DISCONNECTED:
  description: "Connection lost, showing reconnect option"
```

### Regions

```
Region Header:
  id: "header"
  geometry:
    width: 100%
    height: FIXED(1)
    flow: DOCK_TOP
  visibility:
    AUTHENTICATING: false
    CONNECTING: true
    CONNECTED: true
    DISCONNECTED: true
  content:
    widgets: [Clock, Title]
    layout: HORIZONTAL

Region Footer:
  id: "footer"
  geometry:
    width: 100%
    height: FIXED(1)
    flow: DOCK_BOTTOM
  visibility:
    AUTHENTICATING: false
    CONNECTING: true
    CONNECTED: true
    DISCONNECTED: true
  content:
    widgets: [StatusBar, KeyHints]
    layout: HORIZONTAL

Region Sidebar:
  id: "sidebar"
  geometry:
    width: PERCENT(25)
    height: FILL
    flow: VERTICAL
  visibility:
    AUTHENTICATING: false
    CONNECTING: true
    CONNECTED: true
    DISCONNECTED: true
  content:
    widgets: [BufferList]
    layout: VERTICAL
    data_binding: app_state.buffers

Region MainContent:
  id: "main-content"
  geometry:
    width: PERCENT(60)
    height: FILL
    flow: VERTICAL
  visibility:
    AUTHENTICATING: false
    CONNECTING: true
    CONNECTED: true
    DISCONNECTED: true
  content:
    widgets: [MessageList, InputBar]
    layout: VERTICAL_SPLIT(1fr, 3)

Region UserList:
  id: "user-list"
  geometry:
    width: PERCENT(15)
    height: FILL
    flow: VERTICAL
  visibility:
    AUTHENTICATING: false
    CONNECTING: true
    CONNECTED: true
    DISCONNECTED: true
  content:
    widgets: [UserList]
    layout: VERTICAL
```

### Overlays

```
Overlay Authentication:
  id: "auth-overlay"
  trigger: State == AUTHENTICATING
  presentation: FULLSCREEN
  dismissable: false
  content:
    layout: CENTERED
    widgets: [Title, Description, HandleInput, ConnectButton, GuestButton, CancelButton]
  backdrop: SOLID_COLOR(darken-2)

Overlay Loading:
  id: "loading-overlay"
  trigger: State == CONNECTING
  presentation: FULLSCREEN
  dismissable: false
  content:
    layout: CENTERED
    widgets: [Spinner, StatusText]

Overlay ThreadPanel:
  id: "thread-panel"
  trigger: Event == ShowThread
  presentation: MODAL
  dismissable: true
  content:
    layout: RIGHT_SIDE(40%)
    widgets: [ThreadTree, CloseButton]

Overlay EmojiPicker:
  id: "emoji-picker"
  trigger: Event == OpenEmojiPicker
  presentation: MODAL
  dismissable: true
  content:
    layout: CENTERED
    widgets: [EmojiGrid, SearchInput]
```

### Transitions

```
Transition AUTHENTICATING -> CONNECTING:
  animation: FADE
  duration: 300ms
  effect: Hide auth-overlay, Show loading-overlay

Transition CONNECTING -> CONNECTED:
  animation: FADE
  duration: 200ms
  effect: Hide loading-overlay, Show main UI

Transition CONNECTED -> DISCONNECTED:
  animation: INSTANT
  duration: 0ms
  effect: Show reconnect banner in Footer
```

### Invariants

```
Invariant SingleFullscreenOverlay:
  description: "Only one fullscreen overlay visible at a time"
  predicate: count(overlays.where(presentation == FULLSCREEN && visible)) <= 1

Invariant AuthFirst:
  description: "Cannot reach CONNECTED without passing AUTHENTICATING"
  predicate: !session.authenticated implies regions.main.visibility == false

Invariant OverlayOnTop:
  description: "Overlays always render above regions"
  predicate: all overlays have higher z-index than regions

Invariant InitialStateApplied:
  description: "UI state must be applied on application mount"
  predicate: on_mount() calls update_ui_from_state(initial_state)
```

## Theory Morphisms (Lenses)

### To Textual TUI (Python)

```
lens PhoenixUI -> TextualTUI:
  State -> App subclass state machine
  Region -> Widget with reactive visibility
  Overlay -> ModalScreen for FULLSCREEN, layer:overlay for partial
  
  CRITICAL: For true fullscreen (covering Header/Footer):
    - Use ModalScreen, not widget with layer:overlay
    - ModalScreen covers entire terminal including docked widgets
    - Regular overlay widgets cannot cover docked Header/Footer
  
  map Geometry:
    DOCK_TOP -> textual.widgets.Header
    DOCK_BOTTOM -> textual.widgets.Footer
    HORIZONTAL -> textual.containers.Horizontal
    VERTICAL -> textual.containers.Vertical
    FULLSCREEN -> textual.screen.ModalScreen
    OVERLAY -> layer: overlay CSS (for non-fullscreen overlays)
    
  map Visibility:
    State -> Boolean reactive on widgets
    # CRITICAL: Use widget.visible property, NOT CSS display
    # CSS descendant selectors are unreliable in Textual
    implementation: |
      sidebar.visible = (state != AUTHENTICATING)
      main_content.visible = (state != AUTHENTICATING)
      user_list.visible = (state != AUTHENTICATING)
      header.visible = (state != AUTHENTICATING)
      footer.visible = (state != AUTHENTICATING)
    
  map Transition:
    State change -> watch() method
    Animation -> CSS transition or textual animation
    Screen change -> push_screen() / pop_screen() / switch_screen()
    
  map Event:
    User action -> Message class with super().__init__()
    Event handler -> on_{event_name}() method
```

### To Web React

```
lens PhoenixUI -> ReactWeb:
  State -> React useState or Redux store
  Region -> Component with conditional render
  Overlay -> Portal or modal component
  
  map Geometry:
    DOCK_TOP -> fixed header
    DOCK_BOTTOM -> fixed footer
    HORIZONTAL -> flex row
    VERTICAL -> flex column
    OVERLAY -> z-index layer
```

## Code Generation Template

Given this theory, a Phoenix code generator produces:

1. **State Management**: Classes/dataclasses for each State with transitions
2. **Region Widgets**: Each region becomes a widget with `visibility()` method
3. **Overlay Widgets**: Each overlay becomes a modal/overlay component
4. **Main App**: Composes regions and overlays, watches state changes
5. **CSS**: Generated from geometry and visibility specifications

Example generated structure (Python/Textual):
```python
class FreeQApp(App):
    # State machine
    state: Reactive[AppState] = reactive(AppState.AUTHENTICATING)
    
    # Regions - always composed, visibility state-driven
    def compose(self) -> ComposeResult:
        yield Header(visible=self.state.show_header)
        with Horizontal(visible=self.state.show_main):
            yield Sidebar(visible=self.state.show_sidebar)
            yield MainContent(visible=self.state.show_main_content)
            yield UserList(visible=self.state.show_userlist)
        yield Footer(visible=self.state.show_footer)
        
        # Partial overlays - composed but visibility toggled
        if self.state == AppState.CONNECTING:
            yield LoadingOverlay()
    
    def on_mount(self):
        # Fullscreen overlays use ModalScreen for true coverage
        if not self.session.authenticated:
            self.push_screen(AuthScreen())


# ModalScreen for true fullscreen (covers Header/Footer)
class AuthScreen(ModalScreen):
    def compose(self):
        with Container():
            yield Label("Authentication")
            yield Input(id="handle")
            yield Button("Connect", id="connect")
    
    @on(Button.Pressed, "#connect")
    def on_connect(self):
        handle = self.query_one("#handle", Input).value.strip()
        if not handle:
            self.update_status("Please enter a handle", error=True)
            return
        
        # IMMEDIATE: Open browser for OAuth
        from generated.widgets.authentication import BrokerAuthFlow
        self.flow = BrokerAuthFlow(self.broker_url)
        result = self.flow.start_login(handle)
        
        import webbrowser
        webbrowser.open(result["url"])  # Open browser immediately
        
        self.update_status("Browser opened! Complete authentication...")
        
        # POLL for completion in background thread
        self.start_polling(result["session_id"])
    
    def start_polling(self, session_id: str):
        """Poll for OAuth completion."""
        import threading
        import time
        
        def poll():
            for _ in range(120):  # 2 minute timeout
                time.sleep(1)
                result = self.flow.poll_auth_result(session_id)
                if result:
                    # SUCCESS - update UI on main thread
                    self.app.call_from_thread(lambda: self.on_auth_complete(result))
                    return
            # TIMEOUT
            self.app.call_from_thread(
                lambda: self.update_status("Authentication timed out", error=True)
            )
        
        threading.Thread(target=poll, daemon=True).start()
    
    def on_auth_complete(self, result):
        """Handle successful auth - dismiss screen and notify app."""
        self.update_status("Authentication successful!")
        
        session = self.flow.refresh_session(result["broker_token"])
        if session:
            self.app.post_message(AuthCompleted(
                handle=session.get("handle"),
                did=session.get("did"),
                nick=session.get("nick"),
                broker_token=result["broker_token"]
            ))
            self.dismiss()  # Remove auth screen


# Event messages - CRITICAL: inherit from Message
class AuthenticationRequested(Message):
    def __init__(self, handle: str, broker_url: str, session_id: str = ""):
        super().__init__()  # REQUIRED for Textual message system
        self.handle = handle
        self.broker_url = broker_url
        self.session_id = session_id


class AuthCompleted(Message):
    """Auth completed successfully."""
    def __init__(self, handle: str, did: str, nick: str, broker_token: str):
        super().__init__()
        self.handle = handle
        self.did = did
        self.nick = nick
        self.broker_token = broker_token


# App-side handler - CRITICAL: Update UI visibility state
class FreeQApp(App):
    def on_auth_screen_auth_completed(self, event) -> None:
        """Handle successful authentication."""
        # Update session
        self.app_state.session.authenticated = True
        self.app_state.session.handle = event.handle
        
        # CRITICAL: Hide auth overlay to show main UI
        # This makes #main-layout.visible CSS active
        self.app_state.ui.auth_overlay_visible = False
        
        # Remove auth screen and refresh UI
        self.pop_screen()
        self._update_ui_from_state(self.app_state)
```

## Benefits

1. **Declarative**: UI is function of state, not sequence of commands
2. **Verifiable**: Invariants can be checked at compile/runtime
3. **Portable**: Same theory lenses to different UI frameworks
4. **Testable**: States and transitions can be tested independently
5. **Composable**: Regions and overlays compose without interference
