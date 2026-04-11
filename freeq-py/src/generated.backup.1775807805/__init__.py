# @phoenix-canon: IU-517684c6 - Requirements Domain
# @phoenix-canon: IU-c40ae8a5 - Definitions Domain
# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Generated Textual TUI widgets and models for FreeQ IRC client.

This module implements all 34 Implementation Units (IUs) as specified
in the Phoenix codegen instruction.

NOTE: No loading overlay for auth flow - direct transition from AuthScreen to Main UI.
"""

# Models
from .models import (
    # Enums
    AppUIState,
    BufferType,
    ConnectionStatus,
    AuthenticationStatus,
    AvatarSource,
    ColorMode,
    
    # Domain Models
    RequirementsState,
    DefinitionsState,
    PhoenixState,
    
    # Session Models
    Session,
    AuthenticationState,
    ConnectionStateData,
    UIState,
    BufferState,
    ChannelState,
    
    # Message Models
    Message,
    EditEvent,
    
    # User Models
    User,
    
    # Thread Models
    Thread,
    
    # Avatar Models
    Avatar,
    AvatarCache,
    TerminalCapabilities,
    
    # Reaction Models
    ReactionGroup,
    Reaction,
    
    # App State
    AppState as AppStateData,
    BufferSelectedData,
    MessageSelectedData,
    AuthResult,
    
    # HTML Templates
    OAUTH_CALLBACK_HTML,
    OAUTH_SUCCESS_HTML,
    OAUTH_ERROR_HTML,
)

# Auth Flow
from .auth_flow import (
    BrokerAuthFlow,
    SessionManager,
    OAuthCallbackHandler,
)

# App - direct imports from screens module
from .screens.auth_screen import (
    AuthScreen,
    AuthCompleted,
    GuestModeRequested,
    AuthFailed,
)

# App main class
from .app import (
    FreeQApp,
    RequirementsWidget,
    DefinitionsWidget,
    PhoenixWidget,
    run_app,
)

# Widgets
from .widgets.sidebar import BufferSidebar, BufferSelected
from .widgets.message_list import MessageList, MessageSelected
from .widgets.message_item import MessageItem, MessageWidget, MessageWidgetClicked
from .widgets.thread_panel import (
    ThreadPanel,
    ShowThreadRequested,
    ThreadReplyRequested,
    StartReplyRequested,
)
from .widgets.user_list import UserList, UserSelected
from .widgets.input_bar import (
    InputBar,
    MessageSent,
    CommandEntered,
    EmojiPickerRequested,
    AttachRequested,
)
from .widgets.emoji_picker import (
    EmojiPicker,
    EmojiSelected,
    ReactionWidget,
    ReactionToggled,
)
from .widgets.debug_panel import DebugPanel, LogEntry
# NOTE: LoadingOverlay NOT imported - auth flow goes directly from AuthScreen to Main UI
from .widgets.context_menu import (
    ContextMenu,
    EditMessageRequested,
    DeleteMessageRequested,
    OpenEmojiPickerRequested,
)

__all__ = [
    # Enums
    "AppUIState",
    "BufferType",
    "ConnectionStatus",
    "AuthenticationStatus",
    "AvatarSource",
    "ColorMode",
    
    # Domain Models
    "RequirementsState",
    "DefinitionsState",
    "PhoenixState",
    
    # Session Models
    "Session",
    "AuthenticationState",
    "ConnectionStateData",
    "UIState",
    "BufferState",
    "ChannelState",
    
    # Message Models
    "Message",
    "EditEvent",
    
    # User Models
    "User",
    
    # Thread Models
    "Thread",
    
    # Avatar Models
    "Avatar",
    "AvatarCache",
    "TerminalCapabilities",
    
    # Reaction Models
    "ReactionGroup",
    "Reaction",
    
    # Data Models
    "AppStateData",
    "BufferSelectedData",
    "MessageSelectedData",
    "AuthResult",
    
    # HTML Templates
    "OAUTH_CALLBACK_HTML",
    "OAUTH_SUCCESS_HTML",
    "OAUTH_ERROR_HTML",
    
    # Auth Flow
    "BrokerAuthFlow",
    "SessionManager",
    "OAuthCallbackHandler",
    
    # App
    "FreeQApp",
    "AuthScreen",
    "AuthCompleted",
    "GuestModeRequested",
    "AuthFailed",
    "RequirementsWidget",
    "DefinitionsWidget",
    "PhoenixWidget",
    "run_app",
    
    # Widgets
    "BufferSidebar",
    "BufferSelected",
    "MessageList",
    "MessageItem",
    "MessageWidget",
    "MessageWidgetClicked",
    "MessageSelected",
    "ThreadPanel",
    "ShowThreadRequested",
    "ThreadReplyRequested",
    "StartReplyRequested",
    "UserList",
    "UserSelected",
    "InputBar",
    "MessageSent",
    "CommandEntered",
    "EmojiPickerRequested",
    "AttachRequested",
    "EmojiPicker",
    "EmojiSelected",
    "ReactionWidget",
    "ReactionToggled",
    "DebugPanel",
    "LogEntry",
    # NOTE: LoadingOverlay NOT exported - auth flow goes directly from AuthScreen to Main UI
    "ContextMenu",
    "EditMessageRequested",
    "DeleteMessageRequested",
    "OpenEmojiPickerRequested",
]
