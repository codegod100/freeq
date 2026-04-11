# @phoenix-canon: IU-517684c6 - Requirements Domain
# @phoenix-canon: IU-c40ae8a5 - Definitions Domain
# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Data models for FreeQ TUI application.

Generated data classes for all 34 Implementation Units.
All classes use @dataclass(slots=True) for memory efficiency.
"""

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum, auto
from typing import Optional, Dict, List, Set, Tuple, Any
from collections import OrderedDict


# ============================================================================
# Enums
# ============================================================================

# @phoenix-canon: node-1f540d2c
class AppUIState(Enum):
    """Application UI states."""
    AUTHENTICATING = "authenticating"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"


# @phoenix-canon: node-8330b04e
class BufferType(Enum):
    """Buffer types for channels, queries, and console."""
    CHANNEL = auto()
    QUERY = auto()
    CONSOLE = auto()


# @phoenix-canon: node-6ab64ae1
class ConnectionStatus(Enum):
    """IRC connection status."""
    DISCONNECTED = auto()
    CONNECTING = auto()
    NEGOTIATING = auto()
    CONNECTED = auto()


# @phoenix-canon: node-03ef4d25
class AuthenticationStatus(Enum):
    """Authentication flow status."""
    IDLE = auto()
    POLLING = auto()
    SUCCESS = auto()
    FAILED = auto()


# @phoenix-canon: node-09daab1c
class AvatarSource(Enum):
    """Source of avatar data."""
    FETCHED = auto()
    GENERATED = auto()
    DEFAULT = auto()


class ColorMode(Enum):
    """Terminal color mode capabilities."""
    TRUECOLOR = auto()
    ANSI256 = auto()
    ANSI16 = auto()


# ============================================================================
# Requirements Domain Models
# ============================================================================

# @phoenix-canon: IU-517684c6
@dataclass(slots=True)
class RequirementsState:
    """Data model for Requirements Domain.
    
    Implements requirements functionality with 4 requirements.
    """
    configuration: Dict[str, Any] = field(default_factory=dict)
    data_inputs: List[Any] = field(default_factory=list)
    processed_results: List[Any] = field(default_factory=list)
    limitations_respected: bool = True


# ============================================================================
# Definitions Domain Models
# ============================================================================

# @phoenix-canon: IU-c40ae8a5
@dataclass(slots=True)
class DefinitionsState:
    """Data model for Definitions Domain.
    
    Implements definitions functionality with 1 requirement.
    """
    terms: Dict[str, str] = field(default_factory=dict)
    type_safety: bool = True
    valid_transitions: bool = True


# ============================================================================
# Phoenix Domain Models
# ============================================================================

# @phoenix-canon: IU-a4bef590
@dataclass(slots=True)
class PhoenixState:
    """Data model for Phoenix Domain.
    
    Implements phoenix functionality with 16 critical requirements.
    """
    session: 'Session' = field(default_factory=lambda: Session())
    connection: 'ConnectionState' = field(default_factory=lambda: ConnectionState())
    ui: 'UIState' = field(default_factory=lambda: UIState())
    buffers: Dict[str, 'BufferState'] = field(default_factory=dict)
    channels: Dict[str, 'ChannelState'] = field(default_factory=dict)
    authentication: 'AuthenticationState' = field(default_factory=lambda: AuthenticationState())


# ============================================================================
# Session Models
# ============================================================================

# @phoenix-canon: node-507a5d07
@dataclass(slots=True)
class Session:
    """User session data.
    
    REQUIREMENT: AuthScreen MUST post AuthCompleted message with 
    handle, did, nick, broker_token on successful authentication.
    """
    authenticated: bool = False
    handle: str = ""
    did: str = ""
    nickname: str = ""
    web_token: str = ""  # broker_token for IRC SASL
    channels: Set[str] = field(default_factory=set)


# @phoenix-canon: node-2c33febc
@dataclass(slots=True)
class AuthenticationState:
    """Authentication flow state.
    
    REQUIREMENT: AuthScreen MUST open browser immediately when 
    Connect button pressed using webbrowser.open().
    """
    auth_handle: str = ""
    is_guest: bool = False
    broker_url: str = "https://auth.freeq.at"
    status: AuthenticationStatus = AuthenticationStatus.IDLE
    session_id: str = ""
    error_message: str = ""


# ============================================================================
# Connection Models
# ============================================================================

# @phoenix-canon: node-506aa018
@dataclass(slots=True)
class ConnectionStateData:
    """IRC connection state."""
    host: str = ""
    port: int = 6697
    tls: bool = True
    nickname: str = ""
    realname: str = ""
    status: ConnectionStatus = ConnectionStatus.DISCONNECTED
    channels: Dict[str, 'ChannelState'] = field(default_factory=dict)


# ============================================================================
# UI State Models
# ============================================================================

# @phoenix-canon: node-00609785
@dataclass(slots=True)
class UIState:
    """UI state management.
    
    REQUIREMENT: The main UI layout (sidebar, main content, user list) 
    MUST be hidden during authentication - only the auth screen visible.
    """
    active_buffer_id: Optional[str] = None
    auth_overlay_visible: bool = True
    loading_visible: bool = False
    thread_panel_open: bool = False
    debug_panel_open: bool = False
    unread_counts: Dict[str, int] = field(default_factory=dict)


# @dataclass(slots=True)
class UIStateCompact:
    """Compact UI state for serialization."""
    active_buffer_id: Optional[str]
    auth_visible: bool


# ============================================================================
# Buffer Models
# ============================================================================

# @phoenix-canon: node-506aa018
@dataclass(slots=True)
class BufferState:
    """Channel or query buffer state."""
    id: str = ""
    name: str = ""
    buffer_type: BufferType = BufferType.CHANNEL
    messages: List['Message'] = field(default_factory=list)
    unread_count: int = 0
    scroll_position: float = 0.0


# @phoenix-canon: node-ed81a1ef
@dataclass(slots=True)
class ChannelState:
    """IRC channel state.
    
    REQUIREMENT: When authentication completes, the main UI layout 
    MUST become visible by setting widget.visible = True on all regions.
    """
    name: str = ""
    topic: str = ""
    users: List['User'] = field(default_factory=list)
    mode: str = ""
    joined: bool = False
    auto_join: bool = False


# ============================================================================
# Message Models
# ============================================================================

@dataclass(slots=True)
class Message:
    """IRC message with full metadata."""
    id: str = ""
    sender: str = ""
    target: str = ""  # channel or nick
    content: str = ""
    timestamp: datetime = field(default_factory=datetime.now)
    edited: bool = False
    edit_history: List['EditEvent'] = field(default_factory=list)
    streaming: bool = False
    reactions: Dict[str, Set[str]] = field(default_factory=dict)  # emoji -> senders
    tags: Dict[str, str] = field(default_factory=dict)
    msgid: str = ""  # IRCv3 msgid
    reply_to: Optional[str] = None  # Parent msgid
    reply_count: int = 0
    batch_id: Optional[str] = None


@dataclass(slots=True)
class EditEvent:
    """Message edit history entry."""
    timestamp: datetime
    old_content: str
    new_content: str


# ============================================================================
# User Models
# ============================================================================

@dataclass(slots=True)
class User:
    """IRC user information."""
    nick: str = ""
    ident: str = ""
    host: str = ""
    realname: str = ""
    atproto_handle: Optional[str] = None
    modes: str = ""  # @ for op, + for voice, etc.


# ============================================================================
# Thread Models
# ============================================================================

@dataclass(slots=True)
class Thread:
    """Thread data structure."""
    root_msgid: str = ""
    root_message: Optional[Message] = None
    replies: List[Message] = field(default_factory=list)
    participant_count: int = 0
    reply_count: int = 0
    last_activity: datetime = field(default_factory=datetime.now)


# ============================================================================
# Avatar Models
# ============================================================================

@dataclass(slots=True)
class Avatar:
    """User avatar data."""
    nick: str = ""
    handle: str = ""
    image_data: Optional[bytes] = None
    dominant_colors: List[Tuple[int, int, int]] = field(default_factory=list)
    source: AvatarSource = AvatarSource.DEFAULT
    last_updated: datetime = field(default_factory=datetime.now)


@dataclass(slots=True)
class AvatarCache:
    """LRU cache for avatar data."""
    max_size: int = 1000
    ttl: timedelta = field(default_factory=lambda: timedelta(hours=24))
    _cache: OrderedDict = field(default_factory=OrderedDict)


@dataclass(slots=True)
class TerminalCapabilities:
    """Terminal rendering capabilities."""
    truecolor: bool = True
    rich_pixels: bool = False
    color_mode: ColorMode = ColorMode.TRUECOLOR


# ============================================================================
# Reaction Models
# ============================================================================

@dataclass(slots=True)
class ReactionGroup:
    """Aggregated reaction data."""
    emoji: str = ""
    count: int = 0
    senders: List[str] = field(default_factory=list)


@dataclass(slots=True)
class Reaction:
    """Individual reaction."""
    emoji: str = ""
    sender: str = ""
    target_msgid: str = ""
    timestamp: datetime = field(default_factory=datetime.now)


# ============================================================================
# App State Container
# ============================================================================

# @phoenix-canon: node-2c760e46
@dataclass(slots=True)
class AppState:
    """Complete application state container.
    
    REQUIREMENT: On AuthCompleted message, the app MUST update state, 
    pop auth screen, set all region widgets visible=True, and focus input bar.
    """
    session: Session = field(default_factory=Session)
    connection: ConnectionStateData = field(default_factory=ConnectionStateData)
    ui: UIState = field(default_factory=UIState)
    buffers: Dict[str, BufferState] = field(default_factory=dict)
    channels: Dict[str, ChannelState] = field(default_factory=dict)
    authentication: AuthenticationState = field(default_factory=AuthenticationState)
    threads: Dict[str, Thread] = field(default_factory=dict)
    avatars: Dict[str, Avatar] = field(default_factory=dict)


# ============================================================================
# Event Data Models
# ============================================================================

@dataclass(slots=True)
class BufferSelectedData:
    """Data for buffer selection event."""
    buffer_id: str = ""
    buffer_name: str = ""
    buffer_type: BufferType = BufferType.CHANNEL


@dataclass(slots=True)
class MessageSelectedData:
    """Data for message selection event."""
    message: Optional[Message] = None
    is_own_message: bool = False


@dataclass(slots=True)
class AuthResult:
    """OAuth authentication result."""
    handle: str = ""
    did: str = ""
    nick: str = ""
    broker_token: str = ""
    success: bool = False
    error: str = ""


# ============================================================================
# OAuth Callback HTML (without spinner)
# ============================================================================

# @phoenix-canon: node-2c33febc
OAUTH_CALLBACK_HTML = """<!DOCTYPE html>
<html>
<head>
    <title>FreeQ Authentication</title>
    <style>
        body { 
            font-family: system-ui, -apple-system, sans-serif; 
            text-align: center; 
            padding: 2rem;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            min-height: 100vh;
            margin: 0;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
        }
        .container {
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            border-radius: 16px;
            padding: 2rem;
            max-width: 400px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
        }
        h2 { margin-top: 0; }
        p { line-height: 1.6; }
        .status { 
            margin-top: 1rem; 
            padding: 1rem;
            background: rgba(255, 255, 255, 0.2);
            border-radius: 8px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h2>Completing authentication...</h2>
        <p>Please wait while we finish the login process.</p>
        <div class="status" id="status">Processing OAuth callback...</div>
    </div>
    <script>
        (function() {
            var hash = window.location.hash;
            var statusEl = document.getElementById('status');
            
            if (hash.startsWith('#oauth=')) {
                var oauthData = hash.slice(7);
                statusEl.textContent = 'Sending authentication data to app...';
                
                fetch('/oauth/complete?oauth=' + encodeURIComponent(oauthData))
                    .then(function(r) { 
                        if (r.ok) {
                            statusEl.textContent = '✓ Authenticated successfully!';
                            document.body.innerHTML = '<div class="container"><h2>✓ Authenticated!</h2><p>You can close this tab and return to the FreeQ app.</p></div>';
                        } else {
                            throw new Error('Server error: ' + r.status);
                        }
                    })
                    .catch(function(e) {
                        statusEl.textContent = 'Error: ' + e.message;
                        document.body.innerHTML = '<div class="container"><h2>✗ Authentication Error</h2><p>' + e.message + '</p></div>';
                    });
            } else {
                statusEl.textContent = 'Error: No OAuth data found';
            }
        })();
    </script>
</body>
</html>"""

# @phoenix-canon: node-59dee27c
OAUTH_SUCCESS_HTML = """<!DOCTYPE html>
<html>
<head>
    <title>FreeQ - Authenticated</title>
    <style>
        body { 
            font-family: system-ui, -apple-system, sans-serif; 
            text-align: center; 
            padding: 2rem;
            background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
            color: white;
            min-height: 100vh;
            margin: 0;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
        }
        .container {
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            border-radius: 16px;
            padding: 2rem;
            max-width: 400px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
        }
        h2 { margin-top: 0; font-size: 2rem; }
        .checkmark { font-size: 4rem; margin-bottom: 1rem; }
    </style>
</head>
<body>
    <div class="container">
        <div class="checkmark">✓</div>
        <h2>Authenticated!</h2>
        <p>You can close this tab and return to the FreeQ app.</p>
    </div>
</body>
</html>"""

OAUTH_ERROR_HTML = """<!DOCTYPE html>
<html>
<head>
    <title>FreeQ - Authentication Error</title>
    <style>
        body { 
            font-family: system-ui, -apple-system, sans-serif; 
            text-align: center; 
            padding: 2rem;
            background: linear-gradient(135deg, #eb3349 0%, #f45c43 100%);
            color: white;
            min-height: 100vh;
            margin: 0;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
        }
        .container {
            background: rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(10px);
            border-radius: 16px;
            padding: 2rem;
            max-width: 400px;
            box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
        }
        h2 { margin-top: 0; }
    </style>
</head>
<body>
    <div class="container">
        <h2>✗ Authentication Error</h2>
        <p>Something went wrong. Please try again.</p>
    </div>
</body>
</html>"""
