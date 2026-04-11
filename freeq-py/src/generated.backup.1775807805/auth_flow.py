# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""OAuth authentication flow for FreeQ TUI.

Implements AT Protocol OAuth via freeq-auth-broker.
"""

import json
import base64
import threading
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.parse import quote, urlparse, parse_qs
from typing import Optional, Dict, Any
from pathlib import Path

from .models import OAUTH_CALLBACK_HTML, OAUTH_SUCCESS_HTML, OAUTH_ERROR_HTML

logger = logging.getLogger(__name__)


class OAuthCallbackHandler(BaseHTTPRequestHandler):
    """Handle OAuth callback from browser."""
    
    def log_message(self, format, *args):
        """Suppress default logging."""
        pass
    
    def do_GET(self) -> None:
        """Handle GET requests."""
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
                if hasattr(self.server, 'results') and hasattr(self.server, 'session_id'):
                    self.server.results[self.server.session_id] = result
            self._serve_success_page()
        
        else:
            # Return 404 for unmatched paths
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
        """Serve minimal HTML page to extract OAuth fragment.
        
        REQUIREMENT: OAuth callback HTML WITHOUT the spinner animation.
        """
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(OAUTH_CALLBACK_HTML.encode())
    
    def _serve_success_page(self) -> None:
        """Serve success HTML page."""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(OAUTH_SUCCESS_HTML.encode())
    
    def _serve_error_page(self, message: str) -> None:
        """Serve error HTML page."""
        self.send_response(400)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(OAUTH_ERROR_HTML.encode())


class BrokerAuthFlow:
    """Broker OAuth flow handler with local HTTP callback server.
    
    Pattern: Broker handles AT Protocol OAuth, TUI receives token via callback.
    """
    
    def __init__(self, broker_url: str = "https://auth.freeq.at"):
        self.broker_url = broker_url.rstrip("/")
        self._servers: Dict[str, HTTPServer] = {}
        self._results: Dict[str, dict] = {}
    
    def start_login(self, handle: str) -> dict[str, Any]:
        """Start login flow - create callback server, get auth URL.
        
        REQUIREMENT: AuthScreen MUST open browser immediately when Connect 
        button pressed using webbrowser.open().
        """
        logger.info(f"[OAuth] Starting login for {handle}")
        
        server = HTTPServer(("127.0.0.1", 0), OAuthCallbackHandler)
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
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self._servers[session_id] = server
        
        logger.info(f"[OAuth] Callback server started on port {server.server_port}")
        
        return {"session_id": session_id, "url": url}
    
    def poll_auth_result(self, session_id: str) -> Optional[dict[str, Any]]:
        """Poll for OAuth completion. Shutdown server on success.
        
        REQUIREMENT: AuthScreen MUST poll for OAuth completion in background 
        thread and call on_auth_complete when result received.
        """
        result = self._results.pop(session_id, None)
        if result is None:
            return None
        
        logger.info(f"[OAuth] Auth completed for {session_id}")
        
        # Cleanup server
        server = self._servers.pop(session_id, None)
        if server:
            server.shutdown()
            server.server_close()
        
        return result
    
    def refresh_session(self, broker_token: str) -> Optional[dict[str, Any]]:
        """Call /session endpoint to get user details."""
        try:
            logger.info(f"[OAuth] Fetching session details")
            
            request = Request(
                f"{self.broker_url}/session",
                data=json.dumps({"broker_token": broker_token}).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urlopen(request, timeout=10) as response:
                result = json.loads(response.read().decode())
                logger.info(f"[OAuth] Session fetched successfully")
                return result
        except Exception as e:
            logger.error(f"[OAuth] Session fetch failed: {e}")
            return None


class SessionManager:
    """Manage session save/restore."""
    
    def __init__(self, session_path: str):
        self.session_path = Path(session_path).expanduser()
    
    def save_session(self, session: 'Session') -> None:
        """Save session to JSON file."""
        from .models import Session
        
        data = {
            "handle": session.handle,
            "did": session.did,
            "nickname": session.nickname,
            "web_token": session.web_token,
            "channels": list(session.channels),
        }
        
        self.session_path.parent.mkdir(parents=True, exist_ok=True)
        self.session_path.write_text(json.dumps(data, indent=2))
    
    def load_session(self) -> Optional['Session']:
        """Load session from JSON file if exists."""
        from .models import Session
        
        if not self.session_path.exists():
            return None
        
        data = json.loads(self.session_path.read_text())
        
        session = Session()
        session.handle = data["handle"]
        session.did = data["did"]
        session.nickname = data["nickname"]
        session.web_token = data["web_token"]
        session.channels = set(data.get("channels", []))
        session.authenticated = True
        
        return session
