"""FreeQ Textual TUI - Authentication Screen

Implements the AuthScreen ModalScreen for AT Protocol OAuth
authentication flow with freeq-auth-broker.

CRITICAL: No loading overlay or progress bar - auth flow goes directly
to Main UI after successful authentication.

CRITICAL REQUIREMENT: The Connect button (id='connect-button') MUST ALWAYS
be visible when auth status is not 'polling'. When polling, it must be hidden.
"""

import threading
import time
import webbrowser
from typing import Optional

from textual.screen import ModalScreen
from textual.widgets import Button, Label, Input, Checkbox
from textual.containers import Vertical, Horizontal
from textual.reactive import reactive
from textual.message import Message
from textual.app import Binding
from textual import on, events

# Configure logging for auth screen
import logging
logger = logging.getLogger(__name__)


# @phoenix-canon: node-bdf09952
class AuthCompleted(Message):
    """Message posted when authentication completes successfully.
    
    Canon: node-bdf09952 - Event message inheriting from textual.message.Message
    Canon: node-507a5d07 - Posted with handle, did, nick, broker_token
    """
    
    def __init__(
        self,
        handle: str,
        did: str,
        nick: str,
        broker_token: str,
    ) -> None:
        super().__init__()  # @phoenix-canon: node-bdf09952
        self.handle = handle
        self.did = did
        self.nick = nick
        self.broker_token = broker_token


# @phoenix-canon: node-bdf09952
class GuestModeRequested(Message):
    """Message posted when guest mode is selected.
    
    Canon: node-bdf09952 - Event message inheriting from textual.message.Message
    Canon: node-e46b05d2 - GuestModeRequested message
    """
    
    def __init__(self) -> None:
        super().__init__()  # @phoenix-canon: node-bdf09952


# @phoenix-canon: node-bdf09952
class AuthFailed(Message):
    """Message posted when authentication fails.
    
    Canon: node-bdf09952 - Event message inheriting from textual.message.Message
    """
    
    def __init__(self, error: str) -> None:
        super().__init__()  # @phoenix-canon: node-bdf09952
        self.error = error


# @phoenix-canon: node-0a5f52d4
class AuthScreen(ModalScreen):
    """Modal screen for AT Protocol OAuth authentication.
    
    Covers the entire terminal with a fullscreen authentication interface.
    Opens browser for OAuth flow and polls for completion.
    
    CRITICAL: No progress bar or loading spinner - direct transition to Main UI.
    
    CRITICAL REQUIREMENT: Connect button (id='connect-button') MUST be:
    - ALWAYS VISIBLE when auth status is NOT polling
    - HIDDEN when auth status IS polling
    - Prominently styled with clear visual hierarchy
    
    Canon: node-0a5f52d4 - AuthScreen ModalScreen on mount
    Canon: node-2848d1ea - ModalScreen for true fullscreen coverage
    Canon: node-2c33febc - Open browser on Connect button
    Canon: node-59dee27c - Poll for OAuth completion in background thread
    Canon: node-507a5d07 - Post AuthCompleted with handle, did, nick, broker_token
    Canon: node-e46b05d2 - Post GuestModeRequested on guest mode
    Canon: node-b782e6c8 - Dismiss after posting completion message
    """
    
    # @phoenix-canon: node-0a5f52d4
    DEFAULT_CSS = """
    AuthScreen {
        align: center middle;
        background: $surface-darken-2;
    }
    
    AuthScreen > #auth-container {
        width: 60;
        height: auto;
        min-height: 20;
        max-height: 30;
        background: $surface-lighten-1;
        border: thick $primary;
        padding: 1 2;
    }
    
    AuthScreen > #auth-container > #auth-title {
        height: 3;
        content-align: center middle;
        text-style: bold;
        color: $primary;
    }
    
    AuthScreen > #auth-container > #auth-subtitle {
        height: 2;
        content-align: center middle;
        color: $text-muted;
    }
    
    AuthScreen > #auth-container > #auth-status {
        height: 3;
        content-align: center middle;
        color: $text;
    }
    
    AuthScreen > #auth-container > #auth-error {
        height: 3;
        content-align: center middle;
        color: $error;
        text-style: bold;
    }
    
    /* Button container - always visible */
    AuthScreen > #auth-container > #auth-buttons {
        height: auto;
        margin: 1 0;
    }
    
    /* Button base styles */
    AuthScreen > #auth-container > #auth-buttons > Button {
        width: 1fr;
        margin: 0 1;
    }
    
    /* CRITICAL: Connect button styling - PROMINENT and ALWAYS VISIBLE when not polling */
    AuthScreen > #auth-container > #auth-buttons > #connect-button {
        background: $success;
        color: $text;
        text-style: bold;
        border: thick $success-lighten-1;
        display: block;
    }
    
    AuthScreen > #auth-container > #auth-buttons > #connect-button:hover {
        background: $success-lighten-1;
        border: thick $success-lighten-2;
    }
    
    /* Hidden state for connect button when polling */
    AuthScreen > #auth-container > #auth-buttons > #connect-button.hidden {
        display: none;
    }
    
    /* Guest button - secondary styling */
    AuthScreen > #auth-container > #auth-buttons > #guest-button {
        background: $surface-darken-1;
        color: $text-muted;
        border: solid $surface;
    }
    
    AuthScreen > #auth-container > #auth-buttons > #guest-button:hover {
        background: $surface;
        color: $text;
    }
    
    AuthScreen > #auth-container > #auth-instructions {
        height: auto;
        margin: 1 0;
        color: $text-muted;
        text-style: italic;
    }
    
    AuthScreen > #auth-container > #auth-url {
        height: 1;
        content-align: center middle;
        color: $primary;
        text-style: underline;
    }
    
    AuthScreen > #auth-container > #handle-input {
        height: 3;
        margin: 1 0;
        border: solid $primary;
        background: $surface;
        padding: 0 1;
    }
    
    AuthScreen > #auth-container > #handle-input:focus {
        border: solid $success;
    }
    
    /* Polling indicator - visible only during polling */
    AuthScreen > #auth-container > #auth-polling {
        height: 2;
        content-align: center middle;
        color: $warning;
        text-style: bold;
        display: none;
    }
    
    AuthScreen > #auth-container > #auth-polling.visible {
        display: block;
    }
    """
    
    # @phoenix-canon: node-0a5f52d4
    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
        Binding("ctrl+c", "quit", "Quit", show=True),
    ]
    
    # @phoenix-canon: node-0a5f52d4
    auth_status: reactive[str] = reactive("Not authenticated")
    is_polling: reactive[bool] = reactive(False)
    error_message: reactive[Optional[str]] = reactive(None)
    handle_value: reactive[str] = reactive("")
    
    # @phoenix-canon: node-c385163a
    def __init__(
        self,
        broker_url: str = "https://auth.freeq.at",
        id: Optional[str] = None,
        classes: Optional[str] = None,
        **kwargs
    ) -> None:
        """Initialize the AuthScreen modal.
        
        Canon: node-c385163a - Widget initialization with id, classes, **kwargs
        """
        super().__init__(id=id, classes=classes, **kwargs)  # @phoenix-canon: node-c385163a
        self._auth_broker_url: str = broker_url
        self._poll_thread: Optional[threading.Thread] = None
        self._stop_polling: threading.Event = threading.Event()
        self._session_id: Optional[str] = None
        self._oauth_url: Optional[str] = None
        self._handle: str = ""
        self._flow = None
    
    # @phoenix-canon: node-0a5f52d4
    def compose(self):
        """Compose the authentication screen layout.
        
        CRITICAL: Connect button MUST be prominently displayed and ALWAYS VISIBLE
        when auth status is not 'polling'.
        
        No progress bar or loading spinner - direct transition to Main UI.
        """
        with Vertical(id="auth-container"):
            # Title
            yield Label("🔐 FreeQ Authentication", id="auth-title")
            
            # Subtitle
            yield Label("Connect with AT Protocol OAuth", id="auth-subtitle")
            
            # Handle input field
            # @phoenix-canon: node-2c33febc
            yield Input(
                placeholder="Enter your handle (e.g., user.bsky.social)",
                id="handle-input",
            )
            
            # Status
            yield Label(self.auth_status, id="auth-status")
            
            # Polling indicator (hidden by default, shown during polling)
            yield Label("⏳ Waiting for browser authentication...", id="auth-polling")
            
            # Error display (hidden by default)
            yield Label("", id="auth-error")
            
            # Instructions
            yield Label(
                "Click 'Connect' to open your browser and authenticate with your AT Protocol identity.",
                id="auth-instructions"
            )
            
            # OAuth URL display
            yield Label("", id="auth-url")
            
            # Buttons - Connect button is ALWAYS yielded and visible when not polling
            with Horizontal(id="auth-buttons"):
                # @phoenix-canon: node-2c33febc
                # CRITICAL: Connect button with id='connect-button' - ALWAYS visible when not polling
                yield Button("🔌 Connect", id="connect-button", variant="primary")
                yield Button("👤 Guest Mode", id="guest-button", variant="default")
    
    # @phoenix-canon: node-43cb8709
    def watch_auth_status(self, status: str) -> None:
        """Watch for auth status changes.
        
        Canon: node-43cb8709 - Check is_mounted before accessing children
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            status_label = self.query_one("#auth-status", Label)
            status_label.update(status)
        except Exception:
            pass
    
    # @phoenix-canon: node-43cb8709
    def watch_error_message(self, error: Optional[str]) -> None:
        """Watch for error message changes.
        
        Canon: node-43cb8709 - Check is_mounted before accessing children
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            error_label = self.query_one("#auth-error", Label)
            if error:
                error_label.update(f"❌ {error}")
                error_label.styles.color = "$error"
            else:
                error_label.update("")
                error_label.styles.color = "$text"
        except Exception:
            pass
    
    # @phoenix-canon: node-43cb8709
    def watch_is_polling(self, is_polling: bool) -> None:
        """Watch for polling state changes.
        
        CRITICAL REQUIREMENT: Connect button MUST be:
        - VISIBLE when NOT polling
        - HIDDEN when polling
        
        Shows polling indicator text when polling.
        
        Canon: node-43cb8709 - Check is_mounted before accessing children
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            # Update polling indicator visibility
            polling_label = self.query_one("#auth-polling", Label)
            if is_polling:
                polling_label.add_class("visible")
            else:
                polling_label.remove_class("visible")
            
            # CRITICAL: Toggle connect button visibility
            # Connect button is VISIBLE when NOT polling, HIDDEN when polling
            connect_button = self.query_one("#connect-button", Button)
            if is_polling:
                connect_button.add_class("hidden")
            else:
                connect_button.remove_class("hidden")
                
        except Exception:
            pass
    
    # @phoenix-canon: node-2c33febc
    @on(Button.Pressed, "#connect-button")
    def on_connect_button(self, event: Button.Pressed) -> None:
        """Handle Connect button press.
        
        Canon: node-2c33febc - Open browser on Connect button
        Canon: node-59dee27c - Poll for OAuth completion in background thread
        """
        logger.info("[AUTH-SCREEN] Connect button pressed")
        self._start_authentication()
    
    # @phoenix-canon: node-e46b05d2
    @on(Button.Pressed, "#guest-button")
    def on_guest_button(self, event: Button.Pressed) -> None:
        """Handle Guest button press.
        
        Canon: node-e46b05d2 - Post GuestModeRequested message
        Canon: node-b782e6c8 - Dismiss after posting message
        """
        self._request_guest_mode()
    
    # @phoenix-canon: node-2c33febc
    @on(events.Key)
    def on_key(self, event: events.Key) -> None:
        """Handle key presses - Enter submits the form."""
        if event.key == "enter":
            logger.info("[AUTH-SCREEN] Enter key pressed, starting authentication")
            self._start_authentication()
    
    # @phoenix-canon: node-2c33febc
    def _start_authentication(self) -> None:
        """Start the OAuth authentication flow.
        
        Opens browser and starts polling for completion.
        No progress bar - simple text status only.
        
        Canon: node-2c33febc - Open browser immediately using webbrowser.open
        Canon: node-59dee27c - Poll for OAuth completion in background thread
        """
        # Get handle from input
        try:
            handle_input = self.query_one("#handle-input", Input)
            handle = handle_input.value.strip()
        except Exception:
            self.error_message = "Input field not found"
            return
        
        if not handle:
            self.error_message = "Please enter your AT Protocol handle (e.g., user.bsky.social)"
            return
        
        if not ("." in handle and len(handle) > 3):
            self.error_message = "Invalid handle format. Use format: user.bsky.social"
            return
        
        self.auth_status = f"Connecting as {handle}..."
        self.error_message = None
        self.is_polling = True  # This triggers watch_is_polling to hide connect button
        
        # Store handle for later
        self._handle = handle
        
        try:
            # Initialize flow
            from ..auth_flow import BrokerAuthFlow
            logger.info(f"[AUTH-SCREEN] Starting OAuth flow for handle: {handle}")
            self._flow = BrokerAuthFlow(self._auth_broker_url)
            result = self._flow.start_login(handle)
            self._session_id = result["session_id"]
            self._oauth_url = result["url"]
            logger.info(f"[AUTH-SCREEN] OAuth session started: {self._session_id}")
            
            # Show URL
            try:
                url_label = self.query_one("#auth-url", Label)
                url_label.update(f"Opening: {self._oauth_url[:50]}...")
            except Exception:
                pass
            
            # Open browser immediately
            # @phoenix-canon: node-2c33febc
            logger.info("[AUTH-SCREEN] Opening browser for OAuth")
            webbrowser.open(self._oauth_url)
            self.auth_status = "Browser opened! Complete auth in browser..."
            
            # Start polling in background thread
            # @phoenix-canon: node-59dee27c
            logger.info("[AUTH-SCREEN] Starting background polling thread")
            self._stop_polling.clear()
            self._poll_thread = threading.Thread(
                target=self._poll_for_completion,
                daemon=True
            )
            self._poll_thread.start()
            
        except Exception as e:
            self.error_message = f"Failed to start OAuth: {e}"
            self.is_polling = False  # This triggers watch_is_polling to show connect button
    
    # @phoenix-canon: node-59dee27c
    def _poll_for_completion(self) -> None:
        """Poll for OAuth completion in background thread.
        
        Runs in a separate thread, calls on_auth_complete when done.
        No progress updates - simple polling only.
        
        Canon: node-59dee27c - Poll in background thread
        Canon: node-507a5d07 - Call on_auth_complete when result received
        """
        max_attempts = 120  # 2 minutes at 1 second intervals
        attempt = 0
        
        logger.info(f"[AUTH-SCREEN] Starting poll loop (max {max_attempts} attempts)")
        
        while not self._stop_polling.is_set() and attempt < max_attempts:
            attempt += 1
            
            # Poll for result
            if self._flow and self._session_id:
                result = self._flow.poll_auth_result(self._session_id)
                
                if result:
                    logger.info(f"[AUTH-SCREEN] Poll success after {attempt} attempts")
                    # Validate broker_token
                    if "broker_token" not in result:
                        logger.error(f"[AUTH-SCREEN] Auth result missing broker_token!")
                        self.app.call_from_thread(
                            lambda: self._on_auth_failed("Auth failed: missing broker_token")
                        )
                        return
                    
                    logger.info(f"[AUTH-SCREEN] Auth complete, posting AuthCompleted message")
                    # Success - update UI on main thread
                    self.app.call_from_thread(
                        lambda: self.on_auth_complete(result)
                    )
                    return
            
            # Wait before next poll
            time.sleep(1)
        
        # Timeout
        if not self._stop_polling.is_set():
            logger.warning(f"[AUTH-SCREEN] Auth timed out after {attempt} attempts")
            self.app.call_from_thread(
                lambda: self._on_auth_failed("Authentication timed out. Please try again.")
            )
    
    # @phoenix-canon: node-507a5d07
    # @phoenix-canon: node-b782e6c8
    def on_auth_complete(self, result: dict) -> None:
        """Handle successful authentication.
        
        Posts AuthCompleted message with all credentials, then dismisses screen.
        Direct transition to Main UI - no loading overlay.
        
        CRITICAL REQUIREMENT: This method MUST call self.dismiss() IMMEDIATELY 
        after posting the AuthCompleted message.
        
        Sequence:
        1. Get session details from broker
        2. Post AuthCompleted message with handle, did, nick, broker_token
        3. Call self.dismiss() to close the auth screen
        
        Canon: node-507a5d07 - Post AuthCompleted with handle, did, nick, broker_token
        Canon: node-b782e6c8 - Dismiss after posting completion message
        """
        self.is_polling = False  # This triggers watch_is_polling to show connect button
        logger.info(f"[AUTH-SCREEN] Auth completion started, result keys: {list(result.keys())}")
        
        # Validate broker_token
        broker_token = result.get("broker_token")
        if not broker_token:
            logger.error("[AUTH-SCREEN] Missing broker_token in auth result!")
            self._on_auth_failed("Missing broker_token in auth result")
            return
        
        # Get session details from broker
        session = None
        if self._flow:
            logger.info("[AUTH-SCREEN] Refreshing session with broker")
            session = self._flow.refresh_session(broker_token)
        
        if not session:
            # Use result data directly if session fetch fails
            logger.warning("[AUTH-SCREEN] Session refresh failed, using result data directly")
            session = {
                "handle": result.get("handle", self._handle),
                "did": result.get("did", ""),
                "nick": result.get("nick", ""),
            }
        
        # Extract session data
        handle = session.get("handle", self._handle)
        did = session.get("did", "")
        nick = session.get("nick", handle.split(".")[0] if "." in handle else handle)
        
        logger.info(f"[AUTH-SCREEN] Posting AuthCompleted: handle={handle}, did={did}, nick={nick}")
        self.auth_status = f"Authenticated as {handle}"
        
        # CRITICAL: Step 1 - Post completion message FIRST
        # @phoenix-canon: node-507a5d07
        self.post_message(AuthCompleted(
            handle=handle,
            did=did,
            nick=nick,
            broker_token=broker_token,
        ))
        logger.info("[AUTH-SCREEN] AuthCompleted message posted")
        
        # CRITICAL: Step 2 - Dismiss screen IMMEDIATELY after posting message
        # This closes the AuthScreen ModalScreen and shows the main UI
        # Direct transition - no loading overlay
        # @phoenix-canon: node-b782e6c8
        logger.info("[AUTH-SCREEN] Dismissing AuthScreen")
        self.dismiss()
    
    # @phoenix-canon: node-e46b05d2
    # @phoenix-canon: node-b782e6c8
    def _request_guest_mode(self) -> None:
        """Request guest mode authentication.
        
        Posts GuestModeRequested message and dismisses screen.
        Direct transition to Main UI - no loading overlay.
        
        CRITICAL REQUIREMENT: This method MUST call self.dismiss() IMMEDIATELY 
        after posting the GuestModeRequested message.
        
        Canon: node-e46b05d2 - Post GuestModeRequested message
        Canon: node-b782e6c8 - Dismiss after posting message
        """
        logger.info("[AUTH-SCREEN] Guest mode requested")
        # Stop any ongoing polling
        self._stop_polling.set()
        
        # Post guest mode message FIRST
        # @phoenix-canon: node-e46b05d2
        self.post_message(GuestModeRequested())
        logger.info("[AUTH-SCREEN] GuestModeRequested message posted")
        
        # Dismiss screen IMMEDIATELY after posting message
        # Direct transition - no loading overlay
        # @phoenix-canon: node-b782e6c8
        logger.info("[AUTH-SCREEN] Dismissing screen for guest mode")
        self.dismiss()
    
    # @phoenix-canon: node-59dee27c
    def _on_auth_failed(self, error: str) -> None:
        """Handle authentication failure."""
        logger.error(f"[AUTH-SCREEN] Auth failed: {error}")
        self.error_message = error
        self.auth_status = "Authentication failed"
        self.is_polling = False  # This triggers watch_is_polling to show connect button
        self.post_message(AuthFailed(error))
    
    # @phoenix-canon: node-0a5f52d4
    def action_close(self) -> None:
        """Close the auth screen (Escape key)."""
        self._stop_polling.set()
        # Don't allow closing without auth - force user to choose
        self.notify("Please choose Connect or Guest Mode", severity="warning")
    
    # @phoenix-canon: node-0a5f52d4
    def action_quit(self) -> None:
        """Quit the application."""
        self._stop_polling.set()
        self.app.exit()
    
    # @phoenix-canon: node-0a5f52d4
    def on_unmount(self) -> None:
        """Clean up when screen is unmounted."""
        self._stop_polling.set()
