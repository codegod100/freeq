# Integration Domain Specification

## Part 1: Abstract System Design

### Application State

```
Entity AppState:
  session: Session
  connection: ConnectionState
  ui: UIState
  buffers: Map[String, BufferState]
  channels: Map[String, ChannelState]

Entity UIState:
  active_buffer_id: String | None
  auth_overlay_visible: Bool
  loading_visible: Bool
  thread_panel_open: Bool
  debug_panel_open: Bool
  unread_counts: Map[String, Int]

Entity BufferState:
  id: String
  name: String
  type: Enum {CHANNEL, QUERY, CONSOLE}
  messages: List[Message]
  unread_count: Int
  scroll_position: Float
```

### Event Loop

```
Loop EventProcessing:
  interval: 50ms
  steps:
    1. Poll IRC client for new events
    2. Route events to handlers
    3. Update AppState
    4. Refresh UI components
    5. Yield control (async)
```

### Event Routing

```
Router EventRouter:
  IRCMessageReceived ->
    - Update buffer messages
    - Increment unread if not active
    - Refresh MessageList
  
  IRCConnected ->
    - Update connection status
    - Auto-join saved channels
    - Hide loading overlay
  
  AuthCompleted ->
    - Update session
    - Hide auth overlay
    - Show main UI
    - Focus input bar
  
  BufferSelected ->
    - Set active_buffer_id
    - Render buffer messages
    - Clear unread count
    - Focus message list
```

### Layout Strategy

```
Layout FreeQLayout:
  regions:
    Header: DOCK_TOP(height: 1)
    Sidebar: PERCENT(25)  # Buffer list
    Main: PERCENT(75) {
      ChatArea: FILL  # Messages
      InputBar: FIXED(3)  # Input
    }
    Footer: DOCK_BOTTOM(height: 1)
  
  overlays:
    AuthScreen: MODAL_FULLSCREEN
    ThreadPanel: MODAL_RIGHT(40%, collapsible)
    EmojiPicker: MODAL_CENTERED
    ContextMenu: INLINE_AT_CURSOR
    DebugPanel: DOCK_BOTTOM(10, overlay)
```

---

## Part 2: Implementation Guidance (Python/Textual)

### Main Application Class

```python
class FreeQApp(App):
    """Main FreeQ IRC application."""
    
    CSS_PATH = "app.css"
    BINDINGS = [
        Binding("ctrl+c", "quit", "Quit"),
        Binding("ctrl+l", "focus_input", "Focus Input"),
        Binding("ctrl+j", "join_channel", "Join Channel"),
        Binding("ctrl+p", "emoji_picker", "Emoji"),
        Binding("ctrl+r", "reply", "Reply"),
        Binding("ctrl+e", "edit", "Edit"),
        Binding("ctrl+d", "delete", "Delete"),
        Binding("ctrl+t", "toggle_thread", "Thread"),
        Binding("ctrl+n", "next_buffer", "Next Buffer"),
        Binding("ctrl+b", "prev_buffer", "Prev Buffer"),
        Binding("f1", "toggle_debug", "Debug"),
    ]
    
    def __init__(self, broker_url: str = "https://auth.freeq.at"):
        super().__init__()
        self.broker_url = broker_url
        self.app_state = AppState()
        self.irc_client: IRCClient | None = None
        self.thread_manager = ThreadManager()
    
    def compose(self) -> ComposeResult:
        """Compose UI layout."""
        # Docked regions
        yield Header(show_clock=True)
        
        # Main horizontal layout
        with Horizontal(id="main-layout"):
            # Sidebar (25%)
            yield BufferSidebar(
                id="sidebar",
                app_state=self.app_state,
            )
            
            # Main content area (75%)
            with Vertical(id="main-content"):
                yield MessageList(
                    id="message-list",
                    app_state=self.app_state,
                )
                yield InputBar(
                    id="input-bar",
                    app_state=self.app_state,
                )
        
        yield Footer()
        
        # Overlays (all hidden by default)
        yield LoadingOverlay(id="loading-overlay")
        yield ThreadPanel(id="thread-panel", classes="hidden")
        yield EmojiPicker(id="emoji-picker", classes="hidden")
        yield ContextMenu(id="context-menu", classes="hidden")
        yield DebugPanel(id="debug-panel", classes="hidden")
    
    def on_mount(self):
        """Initialize on mount."""
        # Show auth screen if not authenticated
        if not self.app_state.session.authenticated:
            self.push_screen(AuthScreen(broker_url=self.broker_url))
        else:
            # Auto-connect if session exists
            self.connect_to_irc()
    
    async def on_ready(self):
        """Start event processing loop."""
        while True:
            await asyncio.sleep(0.05)  # 50ms tick
            
            if self.irc_client:
                # Poll for IRC events
                events = self.irc_client.poll_events()
                for event in events:
                    self._handle_irc_event(event)
    
    def _handle_irc_event(self, event: IRCEvent):
        """Route IRC event to handler."""
        if isinstance(event, IRCMessageReceived):
            self._on_message(event)
        elif isinstance(event, IRCConnected):
            self._on_connected(event)
        elif isinstance(event, IRCDisconnected):
            self._on_disconnected(event)
    
    def _on_message(self, event: IRCMessageReceived):
        """Handle incoming message."""
        # Determine buffer target
        buffer_id = event.target if event.target.startswith("#") else event.sender
        
        # Add to buffer
        buffer = self.app_state.buffers.get(buffer_id)
        if buffer:
            buffer.messages.append(event.message)
            
            # Increment unread if not active buffer
            if buffer_id != self.app_state.ui.active_buffer_id:
                buffer.unread_count += 1
        
        # Update UI
        self._update_ui_from_state()
    
    def _update_ui_from_state(self):
        """Sync UI components with AppState."""
        # Update sidebar
        sidebar = self.query_one("#sidebar", BufferSidebar)
        sidebar.update_buffers(self.app_state.buffers)
        
        # Update message list
        if active_id := self.app_state.ui.active_buffer_id:
            buffer = self.app_state.buffers.get(active_id)
            message_list = self.query_one("#message-list", MessageList)
            message_list.render_messages(buffer.messages if buffer else [])
        
        # Update header/footer visibility
        if self.app_state.ui.auth_overlay_visible:
            self.query_one(Header).add_class("hidden")
            self.query_one(Footer).add_class("hidden")
        else:
            self.query_one(Header).remove_class("hidden")
            self.query_one(Footer).remove_class("hidden")
```

### Event Handlers

```python
class FreeQApp(App):
    # ...
    
    def on_auth_screen_auth_completed(self, event: AuthCompleted) -> None:
        """Handle successful authentication."""
        # Update session
        self.app_state.session.handle = event.handle
        self.app_state.session.did = event.did
        self.app_state.session.nickname = event.nick
        self.app_state.session.web_token = event.broker_token
        self.app_state.session.authenticated = True
        
        # Update UI state
        self.app_state.ui.auth_overlay_visible = False
        
        # Dismiss auth screen
        self.pop_screen()
        
        # Show main UI
        self._update_ui_from_state()
        
        # Connect to IRC
        self.connect_to_irc()
    
    def on_buffer_sidebar_buffer_selected(self, event: BufferSelected) -> None:
        """Handle buffer switch."""
        old_buffer = self.app_state.ui.active_buffer_id
        new_buffer = event.buffer_id
        
        # Update active buffer
        self.app_state.ui.active_buffer_id = new_buffer
        
        # Clear unread count
        if buffer := self.app_state.buffers.get(new_buffer):
            buffer.unread_count = 0
        
        # Render new buffer
        self._update_ui_from_state()
        
        # Focus message list
        self.query_one("#message-list", MessageList).focus()
    
    def on_input_bar_message_sent(self, event: MessageSent) -> None:
        """Handle user sending a message."""
        if not self.irc_client:
            return
        
        target = self.app_state.ui.active_buffer_id
        if not target:
            return
        
        # Send via IRC
        self.irc_client.send_message(target, event.content)
        
        # Optimistically add to buffer
        msg = Message(
            sender=self.app_state.session.nickname,
            target=target,
            content=event.content,
            timestamp=datetime.now(),
        )
        
        if buffer := self.app_state.buffers.get(target):
            buffer.messages.append(msg)
            self._update_ui_from_state()
    
    def on_message_list_message_selected(self, event: MessageSelected) -> None:
        """Handle message click - show context menu."""
        is_own = event.message.sender == self.app_state.session.nickname
        
        self.push_screen(MessageContextMenu(
            message=event.message,
            is_own_message=is_own,
        ))
```

### State Management

```python
@dataclass
class AppState:
    """Complete application state."""
    session: Session = field(default_factory=Session)
    connection: ConnectionState = field(default_factory=ConnectionState)
    ui: UIState = field(default_factory=UIState)
    buffers: dict[str, BufferState] = field(default_factory=dict)
    channels: dict[str, ChannelState] = field(default_factory=dict)


@dataclass
class Session:
    """User session."""
    authenticated: bool = False
    handle: str = ""
    did: str = ""
    nickname: str = ""
    web_token: str = ""


@dataclass
class UIState:
    """UI state (reactive)."""
    active_buffer_id: str | None = None
    auth_overlay_visible: bool = True
    loading_visible: bool = False
    thread_panel_open: bool = False
    debug_panel_open: bool = False


@dataclass
class BufferState:
    """Channel or query buffer state."""
    id: str = ""
    name: str = ""
    buffer_type: BufferType = BufferType.CHANNEL
    messages: list[Message] = field(default_factory=list)
    unread_count: int = 0
    scroll_position: float = 0.0
```

### Batch Updates

```python
class FreeQApp(App):
    def batch_update(self, updates: list[Callable]):
        """Batch multiple UI updates for efficiency."""
        with self.batch_update():  # Textual batch mode
            for update in updates:
                update()
    
    def add_messages_batch(self, buffer_id: str, messages: list[Message]):
        """Add multiple messages efficiently."""
        buffer = self.app_state.buffers.get(buffer_id)
        if not buffer:
            return
        
        # Update state
        buffer.messages.extend(messages)
        
        # Batch UI update
        message_list = self.query_one("#message-list", MessageList)
        with self.batch_update():
            for msg in messages:
                message_list.mount(MessageWidget(msg))
        
        # Scroll to bottom if at bottom
        if message_list.scroll_y >= message_list.max_scroll_y - 5:
            message_list.scroll_end(animate=False)
```

### Session Persistence

```python
class SessionManager:
    """Manage session save/restore."""
    
    SESSION_FILE = Path.home() / ".config" / "freeq" / "session.json"
    
    def save(self, app_state: AppState):
        """Save session to disk."""
        data = {
            "session": {
                "handle": app_state.session.handle,
                "did": app_state.session.did,
                "nickname": app_state.session.nickname,
                "web_token": app_state.session.web_token,
            },
            "channels": [
                {"name": c.name, "joined": True}
                for c in app_state.channels.values()
                if c.joined
            ],
        }
        
        self.SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
        self.SESSION_FILE.write_text(json.dumps(data, indent=2))
    
    def load(self) -> AppState | None:
        """Load session from disk."""
        if not self.SESSION_FILE.exists():
            return None
        
        data = json.loads(self.SESSION_FILE.read_text())
        
        state = AppState()
        state.session.handle = data["session"]["handle"]
        state.session.did = data["session"]["did"]
        state.session.nickname = data["session"]["nickname"]
        state.session.web_token = data["session"]["web_token"]
        state.session.authenticated = True
        
        for chan in data.get("channels", []):
            state.channels[chan["name"]] = ChannelState(
                name=chan["name"],
                joined=False,  # Will rejoin on connect
            )
        
        return state
```

### Layout Responsiveness

```python
class FreeQApp(App):
    def on_resize(self, event: Resize):
        """Handle terminal resize."""
        width, height = event.size
        
        # Recalculate sidebar width (min 15 chars, max 30%)
        sidebar_width = max(15, min(width // 4, width // 3))
        
        # Update sidebar
        sidebar = self.query_one("#sidebar", BufferSidebar)
        sidebar.styles.width = sidebar_width
        
        # Thread panel: 40% or 60 cols, whichever is smaller
        thread_panel = self.query_one("#thread-panel", ThreadPanel)
        thread_width = min(width * 2 // 5, 60)
        thread_panel.styles.width = thread_width
        
        # Ensure chat area has minimum width
        chat_width = width - sidebar_width - thread_width
        if chat_width < 40:
            # Collapse thread panel if too narrow
            thread_panel.add_class("collapsed")
```
