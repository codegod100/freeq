# @phoenix-canon: IU-517684c6 - Requirements Domain
# @phoenix-canon: IU-c40ae5a5 - Definitions Domain
# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Main FreeQ TUI application.

Generated Textual TUI app with all 34 IUs.
"""

import logging
from typing import Optional, Dict

from textual.app import App
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.widgets import Header, Footer
from textual.screen import ModalScreen
from textual.reactive import reactive
from textual.message import Message
from textual import on, work
from textual.worker import get_current_worker

from .models import (
    AppState,
    Session,
    UIState,
    ConnectionStateData,
    BufferState,
    ChannelState,
    Message,
    User,
    Thread,
    AppUIState,
    BufferType,
)

from .screens.auth_screen import AuthScreen, AuthCompleted, GuestModeRequested, AuthFailed
from .widgets import (
    BufferSidebar,
    MessageList,
    InputBar,
    UserList,
    CommandEntered,
    MessageSent,
)


# Setup logger
logger = logging.getLogger(__name__)


# @phoenix-canon: IU-517684c6
class RequirementsWidget:
    """Main widget for Requirements Domain."""
    pass


# @phoenix-canon: IU-c40ae5a5
class DefinitionsWidget:
    """Main widget for Definitions Domain."""
    pass


# @phoenix-canon: IU-a4bef590
class PhoenixWidget:
    """Main widget for Phoenix Domain."""
    pass


# @phoenix-canon: node-0a5f52d4
class FreeQApp(App):
    """Main FreeQ IRC application.
    
    REQUIREMENT: On app mount, if not authenticated, the app MUST push 
    AuthScreen ModalScreen to cover entire terminal.
    
    REQUIREMENT: The auth flow goes directly from AuthScreen to Main UI
    without any intermediate loading overlay.
    
    CRITICAL REQUIREMENT: When authentication completes and AuthScreen dismisses,
    the main UI MUST NOT be blank. The _update_ui_from_state() method MUST
    explicitly set visible=True and display='block' on ALL UI regions.
    """
    
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
    
    /* Main layout - hidden by default during auth */
    FreeQApp > #main-layout {
        width: 100vw;
        height: 100vh;
        margin-top: 1;
        margin-bottom: 1;
        layout: horizontal;
        display: none;
    }
    
    /* When visible: show container with horizontal layout */
    FreeQApp > #main-layout.visible {
        display: block;
    }
    
    /* Sidebar (25%) */
    FreeQApp > #main-layout > #sidebar {
        width: 25%;
        height: 100%;
        border-right: solid $primary;
    }
    
    /* Main content area (60%) */
    FreeQApp > #main-layout > #main-content {
        width: 60%;
        height: 100%;
    }
    
    /* User list panel (15%) */
    FreeQApp > #main-layout > #user-list-panel {
        width: 15%;
        height: 100%;
        border-left: solid $primary;
    }
    
    /* When parent has visible class, children are visible */
    FreeQApp > #main-layout.visible > #sidebar,
    FreeQApp > #main-layout.visible > #main-content,
    FreeQApp > #main-layout.visible > #user-list-panel {
        display: block;
    }
    
    /* Hide children by default when parent is hidden */
    FreeQApp > #main-layout > #sidebar,
    FreeQApp > #main-layout > #main-content,
    FreeQApp > #main-layout > #user-list-panel {
        display: none;
    }
    """
    
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
        Binding("ctrl+q", "quit", "Quit"),
    ]
    
    # Reactive state
    state = reactive(AppUIState.AUTHENTICATING)
    
    def __init__(
        self,
        broker_url: str = "https://auth.freeq.at",
        session_path: str = None,
        web_token: str = None,
    ):
        """Initialize main app."""
        super().__init__()
        self.broker_url = broker_url
        self.session_path = session_path or "~/.config/freeq/session.json"
        
        # Initialize state
        self.app_state = AppState()
        
        # Try to restore session
        if web_token:
            self.app_state.session.web_token = web_token
            self.app_state.session.authenticated = True
    
    def compose(self):
        """Compose UI layout.
        
        No loading overlay - auth flow goes directly from AuthScreen to Main UI.
        """
        # Docked regions
        yield Header(show_clock=True)
        
        # Main horizontal layout
        with Horizontal(id="main-layout"):
            # Sidebar (25%) - contains actual BufferSidebar widget
            with Vertical(id="sidebar"):
                yield BufferSidebar(app_state=self.app_state)
            
            # Main content area (60%) - contains MessageList and InputBar
            with Vertical(id="main-content"):
                yield MessageList(app_state=self.app_state)
                yield InputBar(app_state=self.app_state)
            
            # User list panel (15%) - contains actual UserList widget
            with Vertical(id="user-list-panel"):
                yield UserList(app_state=self.app_state)
        
        yield Footer()
    
    # @phoenix-canon: node-0a5f52d4
    def on_mount(self):
        """Initialize on mount.
        
        REQUIREMENT: On app mount, the app MUST FIRST attempt to load stored 
        credentials using load_saved_credentials() BEFORE checking session state.
        
        REQUIREMENT: If stored credentials are found and valid, auto-populate 
        the session and skip showing AuthScreen entirely.
        
        REQUIREMENT: No loading overlay - direct transition from AuthScreen to Main UI.
        """
        # @phoenix-canon: node-00609785
        # FIRST: Try to load saved credentials and auto-login
        logger.info("[AUTH-MOUNT] Starting on_mount, checking for saved credentials...")
        saved_creds = self.load_saved_credentials()
        logger.info(f"[AUTH-MOUNT] load_saved_credentials returned: {saved_creds is not None}")
        
        if saved_creds:
            # Auto-login with saved credentials
            logger.info("[AUTH-MOUNT] Saved credentials found, attempting auto-login")
            self.app_state.session.handle = saved_creds.get("handle", "")
            self.app_state.session.did = saved_creds.get("did", "")
            self.app_state.session.nickname = saved_creds.get("nick", "")
            self.app_state.session.web_token = saved_creds.get("web_token", "")
            self.app_state.session.authenticated = True
            logger.info(f"[AUTH-MOUNT] Session set: handle={self.app_state.session.handle}, auth={self.app_state.session.authenticated}")
            
            # Populate default data for auto-login
            self._populate_default_data(
                saved_creds.get("handle", ""),
                saved_creds.get("nick", "")
            )
            logger.info("[AUTH-MOUNT] Default data populated")
            
            # Explicitly refresh sidebar to show populated buffers
            # REQUIREMENT: When auto-login completes in on_mount(), the app MUST
            # explicitly call buffer_sidebar.watch_buffers() to force sidebar refresh
            try:
                sidebar = self.query_one("#sidebar", Vertical)
                buffer_sidebar = sidebar.query_one("BufferSidebar")
                buffer_sidebar.watch_buffers(self.app_state.buffers)
                logger.info("[AUTH-MOUNT] Sidebar explicitly refreshed with buffers")
            except Exception as e:
                logger.warning(f"[AUTH-MOUNT] Could not refresh sidebar: {e}")
            
            # Load saved channels from session
            # REQUIREMENT: On app mount, after authentication succeeds, the app
            # MUST call _load_channels() to restore previously joined channels
            loaded_channels = self._load_channels()
            if loaded_channels:
                # Refresh sidebar again to show loaded channels
                try:
                    sidebar = self.query_one("#sidebar", Vertical)
                    buffer_sidebar = sidebar.query_one("BufferSidebar")
                    buffer_sidebar.watch_buffers(self.app_state.buffers)
                    logger.info(f"[AUTH-MOUNT] Sidebar refreshed with {len(loaded_channels)} loaded channels")
                except Exception as e:
                    logger.warning(f"[AUTH-MOUNT] Could not refresh sidebar after loading channels: {e}")
            
            # Show main UI directly (no auth screen)
            self.app_state.ui.auth_overlay_visible = False
            self.state = AppUIState.CONNECTED
            self._update_ui_from_state()
            logger.info("[AUTH-MOUNT] Auto-login complete, main UI should be visible")
        elif not self.app_state.session.authenticated:
            # No saved credentials, show auth screen
            logger.info("[AUTH-MOUNT] No saved credentials found OR load failed, showing AuthScreen")
            self.push_screen(AuthScreen(broker_url=self.broker_url))
            
            # Hide main layout initially
            # @phoenix-canon: node-00609785
            # Main UI layout (sidebar, main content, user list) 
            # MUST be hidden during authentication - only the auth screen visible
            self.app_state.ui.auth_overlay_visible = True
            self._update_ui_from_state()
        else:
            # Auto-connect if session exists
            self.state = AppUIState.CONNECTED
            self.app_state.ui.auth_overlay_visible = False
            self._update_ui_from_state()
    
    # @phoenix-canon: node-2c760e46
    @on(AuthCompleted)
    def on_auth_screen_auth_completed(self, event: AuthCompleted) -> None:
        """Handle auth completion from AuthScreen.
        
        REQUIREMENT: On AuthCompleted message, the app MUST update state, 
        pop auth screen, set all region widgets visible=True, and focus input bar.
        
        NOTE: The AuthScreen already dismissed itself via self.dismiss() before
        posting this message. We only need to update state and show main UI.
        
        CRITICAL SEQUENCE:
        1. Update session state with auth data
        2. Update UI state (auth_overlay_visible = False)
        3. Sync UI widgets with new state (_update_ui_from_state)
        4. Mark connection as ready
        5. Focus input bar
        
        REQUIREMENT: No loading overlay - direct transition to Main UI.
        
        CRITICAL: Main UI must be fully visible after auth completes.
        """
        logger.info("[AUTH] AuthCompleted event received - starting UI transition")
        
        # 1. Update session state
        self.app_state.session.handle = event.handle
        self.app_state.session.did = event.did
        self.app_state.session.nickname = event.nick
        self.app_state.session.web_token = event.broker_token
        self.app_state.session.authenticated = True
        logger.info(f"[AUTH] Session updated - handle={event.handle}, did={event.did}, nick={event.nick}")
        
        # 1a. Save credentials for auto-login on next startup
        # REQUIREMENT: On AuthCompleted, the app MUST call _save_credentials()
        saved = self._save_credentials(
            handle=event.handle,
            did=event.did,
            nick=event.nick,
            web_token=event.broker_token,
        )
        if saved:
            logger.info("[AUTH] Credentials saved for auto-login")
        else:
            logger.warning("[AUTH] Failed to save credentials")
        
        # 1b. Populate default buffers and channels so UI has content to display
        self._populate_default_data(event.handle, event.nick)
        logger.info("[AUTH] Default buffers and channels populated")
        
        # Explicitly refresh sidebar to show populated buffers
        # REQUIREMENT: When AuthCompleted fires, the app MUST explicitly call
        # buffer_sidebar.watch_buffers() after _populate_default_data()
        try:
            sidebar = self.query_one("#sidebar", Vertical)
            buffer_sidebar = sidebar.query_one("BufferSidebar")
            buffer_sidebar.watch_buffers(self.app_state.buffers)
            logger.info("[AUTH] Sidebar explicitly refreshed with populated buffers")
        except Exception as e:
            logger.warning(f"[AUTH] Could not refresh sidebar: {e}")
        
        # 1c. Save channels along with credentials
        self._save_channels()
        logger.info("[AUTH] Channels saved to session")
        
        # 1d. Load any previously saved channels
        loaded_channels = self._load_channels()
        if loaded_channels:
            logger.info(f"[AUTH] Loaded {len(loaded_channels)} previously saved channels")
        
        # 2. Update UI state (CRITICAL)
        # @phoenix-canon: node-77eff8b8
        # Visibility MUST be controlled by Python widget.visible property
        self.app_state.ui.auth_overlay_visible = False
        logger.info("[AUTH] auth_overlay_visible set to False")
        
        # 3. Sync UI widgets with new state
        logger.info("[AUTH] Calling _update_ui_from_state() to make main UI visible")
        self._update_ui_from_state()
        
        # 4. Mark connection as ready
        self.state = AppUIState.CONNECTED
        self.app_state.connection.status = "connected"
        logger.info("[AUTH] Connection state set to CONNECTED")
        
        # 5. Focus input bar after refresh
        # @phoenix-canon: node-ed81a1ef
        # When authentication completes, the main UI layout MUST become 
        # visible by setting widget.visible = True on all regions
        self.call_after_refresh(self._focus_input)
        logger.info("[AUTH] Input focus scheduled via call_after_refresh")
    
    def load_saved_credentials(self) -> Optional[Dict]:
        """Load credentials from ~/.config/freeq/auth.json.
        
        REQUIREMENT: On app startup, load stored credentials from
        ~/.config/freeq/auth.json and validate web_token.
        
        Returns:
            Dict with credentials if file exists and is valid, None otherwise
        """
        import json
        from pathlib import Path
        
        auth_path = Path.home() / ".config" / "freeq" / "auth.json"
        
        if not auth_path.exists():
            logger.info("[AUTH] No saved credentials file found")
            return None
        
        try:
            with open(auth_path, 'r') as f:
                data = json.load(f)
            
            # Validate required fields
            required_fields = ['handle', 'did', 'nick', 'web_token']
            for field in required_fields:
                if field not in data:
                    logger.warning(f"[AUTH] Saved credentials missing field: {field}")
                    return None
            
            logger.info(f"[AUTH] Loaded saved credentials for handle: {data.get('handle')}")
            return data
            
        except json.JSONDecodeError as e:
            logger.warning(f"[AUTH] Invalid JSON in credentials file: {e}")
            return None
        except Exception as e:
            logger.warning(f"[AUTH] Failed to load credentials: {e}")
            return None
    
    def _save_credentials(self, handle: str, did: str, nick: str, web_token: str) -> bool:
        """Save credentials to ~/.config/freeq/auth.json.
        
        REQUIREMENT: The FreeQApp class MUST implement _save_credentials() method
        that saves credentials to ~/.config/freeq/auth.json.
        
        REQUIREMENT: The _save_credentials() method MUST create the ~/.config/freeq
        directory if it does not exist.
        
        REQUIREMENT: On AuthCompleted, the app MUST call _save_credentials() to
        persist credentials for future auto-login.
        
        Args:
            handle: AT Protocol handle (e.g., user.bsky.social)
            did: Decentralized identifier
            nick: Nickname for IRC
            web_token: Authentication token from broker
            
        Returns:
            True if saved successfully, False otherwise
        """
        import json
        from pathlib import Path
        from datetime import datetime
        
        try:
            # Create directory if it doesn't exist
            auth_dir = Path.home() / ".config" / "freeq"
            auth_dir.mkdir(parents=True, exist_ok=True)
            
            # Prepare credentials data
            data = {
                "handle": handle,
                "did": did,
                "nick": nick,
                "web_token": web_token,
                "timestamp": datetime.now().isoformat(),
            }
            
            # Write to file
            auth_path = auth_dir / "auth.json"
            with open(auth_path, 'w') as f:
                json.dump(data, f, indent=2)
            
            logger.info(f"[AUTH] Credentials saved for handle: {handle}")
            return True
            
        except Exception as e:
            logger.warning(f"[AUTH] Failed to save credentials: {e}")
            return False
    
    def _save_channels(self) -> bool:
        """Save joined channels to ~/.config/freeq/session.json.
        
        REQUIREMENT: The FreeQApp class MUST implement _save_channels() method
        that saves joined channels to ~/.config/freeq/session.json.
        
        REQUIREMENT: The _save_channels() method MUST save a JSON file with
        field 'channels' containing a list of joined channel names.
        
        REQUIREMENT: On app unmount or when channels change, the app MUST call
        _save_channels() to persist the current channel list.
        
        Returns:
            True if saved successfully, False otherwise
        """
        import json
        from pathlib import Path
        
        try:
            # Create directory if it doesn't exist
            session_dir = Path.home() / ".config" / "freeq"
            session_dir.mkdir(parents=True, exist_ok=True)
            
            # Get channel names from buffers
            channels = [
                buf.name for buf in self.app_state.buffers.values()
                if buf.buffer_type == BufferType.CHANNEL and buf.name != "console"
            ]
            
            # Prepare session data
            data = {"channels": channels}
            
            # Write to file
            session_path = session_dir / "session.json"
            with open(session_path, 'w') as f:
                json.dump(data, f, indent=2)
            
            logger.info(f"[AUTH] Saved {len(channels)} channels to session: {channels}")
            return True
            
        except Exception as e:
            logger.warning(f"[AUTH] Failed to save channels: {e}")
            return False
    
    def _load_channels(self) -> list:
        """Load saved channels from ~/.config/freeq/session.json.
        
        REQUIREMENT: The FreeQApp class MUST implement _load_channels() method
        that loads saved channels from ~/.config/freeq/session.json.
        
        REQUIREMENT: On app mount, after authentication succeeds, the app MUST
        call _load_channels() to restore previously joined channels.
        
        REQUIREMENT: When channels are loaded, the app MUST populate
        app_state.buffers with a BufferState for each saved channel so they
        appear in the sidebar immediately.
        
        Returns:
            List of channel names, empty list if no saved channels
        """
        import json
        from pathlib import Path
        
        session_path = Path.home() / ".config" / "freeq" / "session.json"
        
        if not session_path.exists():
            logger.info("[AUTH] No saved session file found")
            return []
        
        try:
            with open(session_path, 'r') as f:
                data = json.load(f)
            
            channels = data.get("channels", [])
            
            # Create buffers for each saved channel
            for channel_name in channels:
                if channel_name not in self.app_state.buffers:
                    from datetime import datetime
                    channel_buffer = BufferState(
                        id=channel_name.replace("#", "").replace("&", ""),
                        name=channel_name,
                        buffer_type=BufferType.CHANNEL,
                        messages=[],
                        unread_count=0,
                        scroll_position=0.0,
                    )
                    # Add to buffers dict
                    new_buffers = dict(self.app_state.buffers)
                    new_buffers[channel_name] = channel_buffer
                    self.app_state.buffers = new_buffers
            
            logger.info(f"[AUTH] Loaded {len(channels)} channels from session: {channels}")
            return channels
            
        except json.JSONDecodeError as e:
            logger.warning(f"[AUTH] Invalid JSON in session file: {e}")
            return []
        except Exception as e:
            logger.warning(f"[AUTH] Failed to load channels: {e}")
            return []
    
    def _populate_default_data(self, handle: str, nick: str) -> None:
        """Populate default buffers and channels so UI shows content after auth.
        
        REQUIREMENT: On AuthCompleted, the app MUST populate app_state.buffers
        with at least one default buffer (e.g., 'Console' or '#general') so UI
        has content to display immediately.
        
        REQUIREMENT: On AuthCompleted, the app MUST set app_state.ui.active_buffer_id
        to the first available buffer so widgets know which buffer to display.
        
        REQUIREMENT: On AuthCompleted, the app MUST populate app_state.channels
        with at least one default channel containing the authenticated user so
        UserList shows content.
        """
        from datetime import datetime
        
        # Create welcome message
        welcome_msg = Message(
            id="welcome-1",
            sender="System",
            target="console",
            content=f"Welcome to FreeQ, {nick}! You are now authenticated as {handle}",
            timestamp=datetime.now(),
        )
        
        # Create Console buffer with welcome message
        console_buffer = BufferState(
            id="console",
            name="Console",
            buffer_type=BufferType.CHANNEL,
            messages=[welcome_msg],
            unread_count=0,
            scroll_position=0.0,
        )
        
        # Add buffer to app_state - MUST create new dict to trigger reactive update
        # REQUIREMENT: Use self.app_state.buffers = {...} not buffers["key"] = ...
        self.app_state.buffers = {"console": console_buffer}
        
        # Set active buffer
        self.app_state.ui.active_buffer_id = "console"
        
        # Create user for self
        self_user = User(
            nick=nick.split(".")[0] if "." in nick else nick,
            atproto_handle=handle,
        )
        
        # Create Console channel with user list
        console_channel = ChannelState(
            name="Console",
            topic="System console and welcome channel",
            users=[self_user],
        )
        
        # Add channel to app_state - MUST create new dict to trigger reactive update
        self.app_state.channels = {"console": console_channel}
        
        logger.info(f"[AUTH] Default data populated: console buffer/channel with {len([welcome_msg])} message(s) and {len([self_user])} user(s)")
    
    @on(GuestModeRequested)
    def on_auth_screen_guest_mode_requested(self, event: GuestModeRequested) -> None:
        """Handle guest mode from AuthScreen.
        
        NOTE: The AuthScreen already dismissed itself via self.dismiss() before
        posting this message. We only need to update state and show main UI.
        
        REQUIREMENT: No loading overlay - direct transition to Main UI.
        
        CRITICAL: Main UI must be fully visible after guest mode starts.
        """
        logger.info("[GUEST] GuestModeRequested event received - starting UI transition")
        
        # Update session state
        self.app_state.session.authenticated = True
        self.app_state.session.is_guest = True
        logger.info("[GUEST] Session updated - guest mode enabled")
        
        # Update UI state
        self.app_state.ui.auth_overlay_visible = False
        logger.info("[GUEST] auth_overlay_visible set to False")
        
        # Populate default buffers for guest mode
        self._populate_default_data("guest", "Guest")
        logger.info("[GUEST] Default buffers populated for guest mode")
        
        # Explicitly refresh sidebar to show populated buffers
        # REQUIREMENT: When guest mode starts, the app MUST explicitly call
        # buffer_sidebar.watch_buffers() after _populate_default_data()
        try:
            sidebar = self.query_one("#sidebar", Vertical)
            buffer_sidebar = sidebar.query_one("BufferSidebar")
            buffer_sidebar.watch_buffers(self.app_state.buffers)
            logger.info("[GUEST] Sidebar explicitly refreshed for guest mode")
        except Exception as e:
            logger.warning(f"[GUEST] Could not refresh sidebar: {e}")
        
        # Sync UI
        logger.info("[GUEST] Calling _update_ui_from_state() to make main UI visible")
        self._update_ui_from_state()
        
        # Mark connection as ready
        self.state = AppUIState.CONNECTED
        logger.info("[GUEST] Connection state set to CONNECTED")
        
        # Focus input
        self.call_after_refresh(self._focus_input)
        logger.info("[GUEST] Input focus scheduled via call_after_refresh")
    
    @on(AuthFailed)
    def on_auth_screen_auth_failed(self, event: AuthFailed) -> None:
        """Handle auth failure from AuthScreen."""
        logger.warning(f"[AUTH] AuthFailed event received: {event.error}")
        # Could show error notification or retry option
        pass
    
    @on(CommandEntered)
    def on_command_entered(self, event: CommandEntered) -> None:
        """Handle command entered by user.
        
        REQUIREMENT: When user types a command (starts with /), the app MUST
        parse and execute the command appropriately.
        """
        command = event.command
        logger.info(f"[COMMAND] Command entered: {command}")
        
        # Parse command and args
        if command.startswith("/"):
            parts = command[1:].split(None, 1)
            cmd = parts[0].lower() if parts else ""
            args = parts[1] if len(parts) > 1 else ""
            
            if cmd == "join" and args:
                channel = args.strip()
                logger.info(f"[COMMAND] Joining channel: {channel}")
                
                # Create buffer for the channel
                from .models import BufferState, BufferType
                if channel not in self.app_state.buffers:
                    buffer_state = BufferState(
                        id=channel,
                        name=channel,
                        buffer_type=BufferType.CHANNEL,
                        messages=[],
                        unread_count=0
                    )
                    self.app_state.buffers[channel] = buffer_state
                    logger.info(f"[COMMAND] Created buffer for {channel}")
                    
                    # Refresh sidebar to show new channel
                    try:
                        sidebar = self.query_one("#sidebar", Vertical)
                        buffer_sidebar = sidebar.query_one("BufferSidebar")
                        buffer_sidebar.watch_buffers(self.app_state.buffers)
                        logger.info(f"[COMMAND] Sidebar refreshed with {channel}")
                    except Exception as e:
                        logger.warning(f"[COMMAND] Could not refresh sidebar: {e}")
                
                # Switch to the channel
                self.app_state.ui.active_buffer_id = channel
                logger.info(f"[COMMAND] Switched active buffer to {channel}")
                
                # Save channels to session
                self._save_channels()
            else:
                logger.warning(f"[COMMAND] Unknown command: {cmd}")
    
    @on(MessageSent)
    def on_message_sent(self, event: MessageSent) -> None:
        """Handle message sent by user.
        
        REQUIREMENT: When user sends a message, the app MUST add it to the
        active buffer's messages.
        """
        logger.info(f"[MESSAGE] Message sent: {event.content[:50]}...")
        
        active_buffer_id = self.app_state.ui.active_buffer_id
        if not active_buffer_id or active_buffer_id not in self.app_state.buffers:
            logger.warning("[MESSAGE] No active buffer to send message to")
            return
        
        # Create message
        from .models import Message as ChatMessage
        from datetime import datetime
        
        msg = ChatMessage(
            id=f"local_{datetime.now().timestamp()}",
            sender=self.app_state.session.nickname or "You",
            content=event.content,
            timestamp=datetime.now()
        )
        
        # Add to buffer
        buffer = self.app_state.buffers[active_buffer_id]
        buffer.messages.append(msg)
        logger.info(f"[MESSAGE] Added message to {active_buffer_id}")
    
    # @phoenix-canon: node-43cb8709
    def _update_ui_from_state(self) -> None:
        """Sync UI components with AppState.
        
        REQUIREMENT: The _update_ui_from_state method MUST check is_mounted 
        before accessing children to avoid lifecycle errors.
        
        REQUIREMENT: Visibility MUST be controlled by Python widget.visible 
        property, NOT CSS display classes.
        
        REQUIREMENT: The Header and Footer MUST be hidden during authentication 
        and visible after authentication completes.
        
        CRITICAL REQUIREMENT: When authentication completes and AuthScreen dismisses,
        the main UI MUST NOT be blank. This method MUST explicitly set visible=True
        and display='block' on ALL UI regions:
        - #main-layout
        - #sidebar
        - #main-content
        - #user-list-panel
        - Header
        - Footer
        
        The #main-layout container MUST have both visible=True AND styles.display='block'
        to ensure it's rendered properly.
        
        Explicit logging verifies each widget is being made visible.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            logger.warning("[UI] _update_ui_from_state called before mounted - skipping")
            return
        
        # @phoenix-canon: node-77eff8b8
        # Visibility MUST be controlled by Python widget.visible property
        show_main = not self.app_state.ui.auth_overlay_visible
        logger.info(f"[UI] _update_ui_from_state called - show_main={show_main}, auth_overlay_visible={self.app_state.ui.auth_overlay_visible}")
        
        try:
            # Query all main UI widgets
            main_layout = self.query_one("#main-layout", Horizontal)
            sidebar = self.query_one("#sidebar", Vertical)
            main_content = self.query_one("#main-content", Vertical)
            user_list = self.query_one("#user-list-panel", Vertical)
            
            if show_main:
                # CRITICAL: Make ALL UI regions visible with both visible=True AND display='block'
                # This ensures the main UI is NOT blank after auth completes
                
                # 1. Main layout - CRITICAL: needs BOTH visible=True AND styles.display='block'
                main_layout.visible = True
                main_layout.styles.display = "block"
                main_layout.add_class("visible")
                logger.info("[UI] #main-layout: visible=True, styles.display='block', class 'visible' added")
                
                # 2. Sidebar
                sidebar.visible = True
                sidebar.styles.display = "block"
                logger.info("[UI] #sidebar: visible=True, styles.display='block'")
                
                # 3. Main content
                main_content.visible = True
                main_content.styles.display = "block"
                logger.info("[UI] #main-content: visible=True, styles.display='block'")
                
                # 4. User list panel
                user_list.visible = True
                user_list.styles.display = "block"
                logger.info("[UI] #user-list-panel: visible=True, styles.display='block'")
                
            else:
                # Hide main UI (auth overlay is visible)
                main_layout.visible = False
                main_layout.styles.display = "none"
                main_layout.remove_class("visible")
                logger.info("[UI] #main-layout: visible=False, styles.display='none'")
                
                sidebar.visible = False
                sidebar.styles.display = "none"
                logger.info("[UI] #sidebar: visible=False")
                
                main_content.visible = False
                main_content.styles.display = "none"
                logger.info("[UI] #main-content: visible=False")
                
                user_list.visible = False
                user_list.styles.display = "none"
                logger.info("[UI] #user-list-panel: visible=False")
            
        except Exception as e:
            logger.error(f"[UI] ERROR querying main UI widgets: {e}", exc_info=True)
        
        # Header/Footer visibility
        # @phoenix-canon: node-c8d3e822
        # The Header and Footer MUST be hidden during authentication 
        # and visible after authentication completes
        try:
            header = self.query_one(Header)
            footer = self.query_one(Footer)
            
            if show_main:
                header.visible = True
                header.styles.display = "block"
                logger.info("[UI] Header: visible=True, styles.display='block'")
                
                footer.visible = True
                footer.styles.display = "block"
                logger.info("[UI] Footer: visible=True, styles.display='block'")
            else:
                header.visible = False
                header.styles.display = "none"
                logger.info("[UI] Header: visible=False")
                
                footer.visible = False
                footer.styles.display = "none"
                logger.info("[UI] Footer: visible=False")
                
        except Exception as e:
            logger.error(f"[UI] ERROR setting Header/Footer visibility: {e}", exc_info=True)
        
        logger.info(f"[UI] _update_ui_from_state completed - main UI should be {'VISIBLE' if show_main else 'HIDDEN'}")
    
    def _focus_input(self):
        """Focus input bar."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            logger.warning("[UI] _focus_input called before mounted - skipping")
            return
        
        try:
            # Query the InputBar widget and focus its input
            input_bar = self.query_one("InputBar")
            input_bar.focus_input()
            logger.info("[UI] Focus set to InputBar")
        except Exception as e:
            logger.error(f"[UI] ERROR focusing input bar: {e}", exc_info=True)
    
    def on_unmount(self) -> None:
        """Save channels when app closes.
        
        REQUIREMENT: On app unmount or when channels change, the app MUST
        call _save_channels() to persist the current channel list.
        """
        logger.info("[APP] App unmounting, saving channels...")
        self._save_channels()
    
    # Action handlers
    def action_quit(self):
        """Quit application."""
        logger.info("[APP] Quit action triggered")
        self.exit()
    
    def action_focus_input(self):
        """Focus input bar."""
        self._focus_input()
    
    def action_join_channel(self):
        """Join channel action."""
        pass
    
    def action_emoji_picker(self):
        """Open emoji picker."""
        pass
    
    def action_reply(self):
        """Reply to message."""
        pass
    
    def action_edit(self):
        """Edit message."""
        pass
    
    def action_delete(self):
        """Delete message."""
        pass
    
    def action_toggle_thread(self):
        """Toggle thread panel."""
        pass
    
    def action_next_buffer(self):
        """Switch to next buffer."""
        pass
    
    def action_prev_buffer(self):
        """Switch to previous buffer."""
        pass
    
    def action_toggle_debug(self):
        """Toggle debug panel."""
        pass


# Convenience function
def run_app(**kwargs):
    """Run the FreeQ TUI application."""
    app = FreeQApp(**kwargs)
    app.run()


# @phoenix-canon: node-5b3f1747
# REQUIREMENT: The app.py MUST include entry point block for 
# `python -m src.generated.app` to work
if __name__ == "__main__":
    run_app()
