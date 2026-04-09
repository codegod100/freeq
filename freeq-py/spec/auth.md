# Authentication Domain Specification

## Phoenix Requirements

- REQUIREMENT: On app mount, the app MUST FIRST attempt to load stored credentials using load_saved_credentials() BEFORE checking self.app_state.session.authenticated

- REQUIREMENT: On app mount, if stored credentials are found and valid, the app MUST auto-populate the session and skip showing AuthScreen entirely

- REQUIREMENT: On app mount, the on_mount() method MUST call load_saved_credentials() and if it returns valid data, immediately set session.authenticated=True and populate session with stored handle, did, nick, web_token

- REQUIREMENT: The on_mount() method MUST log '[AUTH-MOUNT] Starting on_mount' at the beginning to enable debugging

- REQUIREMENT: The on_mount() method MUST log whether saved credentials were found with '[AUTH-MOUNT] Saved credentials found: {True|False}'

- REQUIREMENT: When auto-login succeeds, the app MUST log '[AUTH-MOUNT] Auto-login complete' so users can verify the flow worked

- REQUIREMENT: The FreeQApp class MUST implement _save_credentials(handle, did, nick, web_token) method that saves credentials to ~/.config/freeq/auth.json

- REQUIREMENT: The _save_credentials() method MUST create the ~/.config/freeq directory if it does not exist

- REQUIREMENT: The _save_credentials() method MUST save a JSON file with fields: handle, did, nick, web_token, timestamp

- REQUIREMENT: On AuthCompleted, the app MUST call _save_credentials() to persist credentials for future auto-login

- REQUIREMENT: The system MUST use AT Protocol OAuth via freeq-auth-broker for authentication

- REQUIREMENT: On app mount, the app MUST check for stored authentication credentials and auto-login if valid credentials exist

- REQUIREMENT: The system MUST persist authentication credentials (web_token, handle, did, nick) to ~/.config/freeq/auth.json after successful login

- REQUIREMENT: Credentials MUST always be saved automatically after successful authentication (no checkbox needed)

- REQUIREMENT: Credentials MUST be saved immediately after successful authentication

- REQUIREMENT: The FreeQApp class MUST implement _save_channels() method that saves joined channels to ~/.config/freeq/session.json

- REQUIREMENT: The _save_channels() method MUST save a JSON file with field 'channels' containing a list of joined channel names (e.g., ["#general", "#help"])

- REQUIREMENT: The FreeQApp class MUST implement _load_channels() method that loads saved channels from ~/.config/freeq/session.json

- REQUIREMENT: On app mount, after authentication succeeds, the app MUST call _load_channels() to restore previously joined channels

- REQUIREMENT: When channels are loaded, the app MUST populate app_state.buffers with a BufferState for each saved channel so they appear in the sidebar immediately

- REQUIREMENT: On app unmount or when channels change, the app MUST call _save_channels() to persist the current channel list

- REQUIREMENT: The session storage directory ~/.config/freeq MUST be created if it does not exist when saving channels

- REQUIREMENT: On app startup, the app MUST load stored credentials from ~/.config/freeq/auth.json and validate the web_token with the broker

- REQUIREMENT: If stored credentials are invalid or expired, the app MUST show AuthScreen for re-authentication

- REQUIREMENT: The stored credentials MUST include: handle, did, nickname, web_token, and timestamp

- REQUIREMENT: The auth storage directory ~/.config/freeq MUST be created if it does not exist

- REQUIREMENT: AuthScreen MUST provide a 'Clear Saved Login' option for users to remove stored credentials

- REQUIREMENT: On app mount, if not authenticated, the app MUST push AuthScreen ModalScreen to cover entire terminal

- REQUIREMENT: AuthScreen MUST display a prominent 'Connect' button with id='connect-button' that is ALWAYS visible when auth status is not 'polling'

- REQUIREMENT: AuthScreen MUST open browser immediately when Connect button pressed using webbrowser.open()

- REQUIREMENT: AuthScreen MUST poll for OAuth completion in background thread and call on_auth_complete when result received

- REQUIREMENT: AuthScreen MUST post AuthCompleted message with handle, did, nick, broker_token on successful authentication

- REQUIREMENT: AuthScreen MUST call self.dismiss() immediately after posting AuthCompleted message to close the modal screen

- REQUIREMENT: On GuestModeRequested, the app MUST populate app_state.buffers with at least one default buffer so UI shows content immediately

- REQUIREMENT: On GuestModeRequested, the app MUST set app_state.ui.active_buffer_id to the first available buffer so widgets know which buffer to display

- REQUIREMENT: On GuestModeRequested, the app MUST populate app_state.channels with a default channel containing a guest user so UserList shows content

- REQUIREMENT: AuthScreen MUST post GuestModeRequested message when guest mode selected

- REQUIREMENT: All event messages MUST inherit from textual.message.Message and call super().__init__()

- REQUIREMENT: AuthScreen MUST dismiss itself after posting completion message (Textual pattern)

## Part 1: Abstract System Design

### Authentication Flows

```
Flow OAuthAuthentication:
  description: "AT Protocol OAuth via browser"
  primary: true
  steps:
    1. User enters handle
    2. App opens browser to broker /auth/login
    3. User authenticates with AT Protocol provider
    4. Broker redirects to local callback with token
    5. App polls for completion
    6. App fetches session details from broker /session
    7. App posts AuthCompleted, shows main UI

Flow GuestMode:
  description: "Connect without authentication"
  steps:
    1. User selects guest mode
    2. App posts GuestModeSelected
    3. App connects to IRC with guest credentials
```

### Domain Model

```
Entity Session:
  attributes:
    authenticated: Bool
    handle: String
    did: String
    nickname: String
    web_token: String  # broker_token for IRC SASL
    channels: List[String]
  
Entity AuthenticationState:
  attributes:
    auth_handle: String
    is_guest: Bool
    broker_url: String
    status: Enum {IDLE, POLLING, SUCCESS, FAILED}
```

### Messages (Domain Events)

```
Event AuthenticationRequested:
  attributes:
    handle: String
    broker_url: String

Event AuthCompleted:
  attributes:
    handle: String
    did: String
    nick: String
    broker_token: String

Event AuthFailed:
  attributes:
    reason: String

Event GuestModeSelected:
  attributes: {}
```

### Invariants

```
Invariant BrokerTokenRequired:
  check: AuthCompleted implies broker_token != ""

Invariant SessionAfterAuth:
  check: AuthCompleted implies session.authenticated == true

Invariant HandleResolution:
  check: AuthCompleted implies session.did != ""
```

---

## Part 2: Implementation Guidance (Python/Textual)

### OAuth Flow Implementation

```python
class BrokerAuthFlow:
    """Broker OAuth flow handler with local HTTP callback server.
    
    Pattern: Broker handles AT Protocol OAuth, TUI receives token via callback.
    """
    
    def __init__(self, broker_url: str = "https://auth.freeq.at"):
        self.broker_url = broker_url.rstrip("/")
        self._servers: dict[str, ThreadingHTTPServer] = {}
        self._results: dict[str, dict] = {}
    
    def start_login(self, handle: str) -> dict[str, Any]:
        """Start login flow - create callback server, get auth URL."""
        server = ThreadingHTTPServer(("127.0.0.1", 0), self._make_handler())
        session_id = f"{server.server_port}-{handle}"
        server.session_id = session_id
        server.results = self._results
        
        callback_url = f"http://127.0.0.1:{server.server_port}/oauth/callback"
        url = (
            f"{self.broker_url}/auth/login"
            f"?handle={quote(handle)}"
            f"&return_to={quote(callback_url)}"
        )
        
        # Start server in background thread
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self._servers[session_id] = server
        
        return {"session_id": session_id, "url": url}
    
    def poll_auth_result(self, session_id: str) -> dict[str, Any] | None:
        """Poll for OAuth completion. Shutdown server on success."""
        result = self._results.pop(session_id, None)
        if result is None:
            return None
        
        # Cleanup server
        server = self._servers.pop(session_id, None)
        if server:
            server.shutdown()
            server.server_close()
        
        return result
    
    def refresh_session(self, broker_token: str) -> dict[str, Any] | None:
        """Call /session endpoint to get user details."""
        try:
            request = Request(
                f"{self.broker_url}/session",
                data=json.dumps({"broker_token": broker_token}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(request, timeout=10) as response:
                return json.loads(response.read().decode())
        except Exception as e:
            logger.error(f"Session fetch failed: {e}")
            return None
```

### HTTP Callback Server Implementation

```python
class OAuthCallbackHandler(BaseHTTPRequestHandler):
    """Handle OAuth callback from browser."""
    
    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        
        if parsed.path == "/oauth/callback":
            # Serve HTML page that extracts fragment and calls /oauth/complete
            self._serve_callback_page()
        
        elif parsed.path == "/oauth/complete":
            # Receive token from JavaScript, store for polling
            query = parse_qs(parsed.query)
            oauth_payload = query.get("oauth", [None])[0]
            if oauth_payload:
                result = self._decode_oauth_payload(oauth_payload)
                self.server.results[self.server.session_id] = result
            self._serve_success_page()
        
        else:
            # CRITICAL: Return 404 for unmatched paths
            self.send_error(404)
    
    def _decode_oauth_payload(self, payload: str) -> dict:
        """Decode base64url OAuth payload."""
        # Replace base64url chars with standard base64
        payload = payload.replace("-", "+").replace("_", "/")
        # Add padding
        padding = "=" * ((4 - len(payload) % 4) % 4)
        decoded = base64.b64decode(payload + padding)
        return json.loads(decoded.decode())
    
    def _serve_callback_page(self) -> None:
        """Serve minimal HTML page to extract OAuth fragment."""
        html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>FreeQ Authentication</title>
            <style>
                body { font-family: sans-serif; text-align: center; padding: 2rem; }
            </style>
        </head>
        <body>
            <h2>Completing authentication...</h2>
            <p>Please wait while we finish the login process.</p>
            <script>
                (function() {
                    var hash = window.location.hash;
                    if (hash.startsWith('#oauth=')) {
                        var oauthData = hash.slice(7);
                        fetch('/oauth/complete?oauth=' + encodeURIComponent(oauthData))
                            .then(function(r) { 
                                if (r.ok) {
                                    document.body.innerHTML = '<h2>✓ Authenticated!</h2><p>You can close this tab.</p>';
                                } else {
                                    throw new Error('Server error');
                                }
                            })
                            .catch(function(e) {
                                document.body.innerHTML = '<h2>✗ Error</h2><p>' + e.message + '</p>';
                            });
                    } else {
                        document.body.innerHTML = '<h2>✗ No OAuth data</h2>';
                    }
                })();
            </script>
        </body>
        </html>
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(html.encode())
```

### UI Integration Pattern

```python
class AuthScreen(ModalScreen):
    """Authentication screen - handles full OAuth flow."""
    
    @on(Button.Pressed, "#connect-btn")
    def on_connect(self):
        """Start OAuth flow and poll for completion."""
        handle = self.query_one("#handle-input", Input).value.strip()
        if not handle:
            self.update_status("Please enter a handle", error=True)
            return
        
        self.update_status(f"Starting OAuth for @{handle}...")
        
        # Initialize flow
        self.flow = BrokerAuthFlow(self.broker_url)
        result = self.flow.start_login(handle)
        self.session_id = result["session_id"]
        
        # Open browser
        import webbrowser
        webbrowser.open(result["url"])
        
        self.update_status("Browser opened! Complete auth in browser...")
        
        # Start polling in background thread
        self.start_polling()
    
    def start_polling(self):
        """Poll for OAuth completion in background thread."""
        import threading
        import time
        
        def poll():
            for _ in range(120):  # 2 minute timeout
                time.sleep(1)
                result = self.flow.poll_auth_result(self.session_id)
                
                if result:
                    # Validate broker_token
                    if "broker_token" not in result:
                        self.app.call_from_thread(
                            lambda: self.update_status("Auth failed: missing token", error=True)
                        )
                        return
                    
                    # Success - update UI on main thread
                    self.app.call_from_thread(lambda: self.on_auth_complete(result))
                    return
            
            # Timeout
            self.app.call_from_thread(
                lambda: self.update_status("Authentication timed out", error=True)
            )
        
        threading.Thread(target=poll, daemon=True).start()
    
    def on_auth_complete(self, result):
        """Handle successful authentication."""
        # Get session details
        session = self.flow.refresh_session(result["broker_token"])
        if not session:
            self.update_status("Failed to fetch session", error=True)
            return
        
        # Post success message to app
        self.app.post_message(AuthCompleted(
            handle=session.get("handle", ""),
            did=session.get("did", ""),
            nick=session.get("nick", ""),
            broker_token=result["broker_token"]
        ))
        
        # Dismiss auth screen
        self.dismiss()


class FreeQApp(App):
    """Main app - handles auth completion."""
    
    def on_auth_screen_auth_completed(self, event: AuthCompleted) -> None:
        """Handle successful authentication."""
        # Update session state
        self.app_state.session.handle = event.handle
        self.app_state.session.did = event.did
        self.app_state.session.nickname = event.nick
        self.app_state.session.web_token = event.broker_token
        self.app_state.session.authenticated = True
        
        # CRITICAL: Update UI visibility state
        self.app_state.ui.auth_overlay_visible = False
        
        # Remove auth screen
        self.pop_screen()
        
        # Refresh UI - shows main layout
        self._update_ui_from_state(self.app_state)
        
        # Focus input bar
        try:
            input_bar = self.query_one("#input-bar", InputBar)
            input_bar.focus()
        except (NoMatches, ScreenStackError):
            pass
```

### Session Persistence Pattern

```python
class SessionManager:
    """Manage cached sessions."""
    
    def __init__(self, session_path: str):
        self.session_path = Path(session_path)
    
    def save_session(self, session: Session) -> None:
        """Save session to JSON file."""
        data = {
            "handle": session.handle,
            "did": session.did,
            "nickname": session.nickname,
            "web_token": session.web_token,
            "channels": list(session.channels.keys()),
        }
        self.session_path.write_text(json.dumps(data))
    
    def load_session(self) -> Session | None:
        """Load session from JSON file if exists."""
        if not self.session_path.exists():
            return None
        
        data = json.loads(self.session_path.read_text())
        return Session(
            handle=data["handle"],
            did=data["did"],
            nickname=data["nickname"],
            web_token=data["web_token"],
            authenticated=True,
        )
```

### CLI Integration

```python
class FreeQApp(App):
    def __init__(
        self,
        broker_url: str = "https://auth.freeq.at",
        session_path: str | None = None,
        web_token: str | None = None,
    ):
        self.broker_url = broker_url
        self.session_path = session_path or "~/.config/freeq/session.json"
        
        # Try to restore session
        if web_token:
            self.app_state.session.web_token = web_token
            self.app_state.session.authenticated = True
```

### Logging Requirements

```python
import logging

logger = logging.getLogger(__name__)

class BrokerAuthFlow:
    def start_login(self, handle: str):
        logger.info(f"[OAuth] Starting login for {handle}")
        # ...
    
    def poll_auth_result(self, session_id: str):
        logger.debug(f"[OAuth] Polling attempt {attempt} for {session_id}")
        # ...
        if result:
            logger.info(f"[OAuth] Auth completed for {session_id}")
        # ...
    
    def refresh_session(self, broker_token: str):
        try:
            # ...
            logger.info(f"[OAuth] Session fetched successfully")
        except Exception as e:
            logger.error(f"[OAuth] Session fetch failed: {e}")
            return None
```

### Error Handling Patterns

```python
# AuthFailed posted on:
# 1. Timeout (120 polling attempts)
# 2. Missing broker_token in result
# 3. /session endpoint failure
# 4. Invalid handle format
# 5. Network error during flow start
# 6. Callback server error

class AuthScreen(ModalScreen):
    def on_auth_complete(self, result):
        # Validate before posting success
        if "broker_token" not in result:
            logger.error("[OAuth] Missing broker_token in result")
            self.update_status("Authentication failed: invalid token", error=True)
            self.app.post_message(AuthFailed(reason="missing broker_token"))
            return
        
        session = self.flow.refresh_session(result["broker_token"])
        if not session:
            logger.error("[OAuth] Failed to fetch session from /session")
            self.update_status("Failed to fetch user details", error=True)
            self.app.post_message(AuthFailed(reason="session_fetch_failed"))
            return
        
        # Success path
        self.app.post_message(AuthCompleted(...))
```
