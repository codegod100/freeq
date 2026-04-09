# @phoenix-canon: IU-517684c6 - Requirements Domain
# @phoenix-canon: IU-c40ae8a5 - Definitions Domain
# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Generated Textual TUI widgets for FreeQ IRC client.

NOTE: No loading overlay widget - auth flow goes directly from AuthScreen to Main UI.
"""

from .sidebar import BufferSidebar, BufferSelected
from .message_list import MessageList, MessageSelected
from .message_item import MessageItem, MessageWidget, MessageWidgetClicked
from .thread_panel import (
    ThreadPanel,
    ThreadReplyRequested,
    StartReplyRequested,
    ShowThreadRequested,
)
from .user_list import UserList, UserSelected
from .input_bar import (
    InputBar,
    MessageSent,
    CommandEntered,
    EmojiPickerRequested,
    AttachRequested,
)
from .emoji_picker import (
    EmojiPicker,
    EmojiSelected,
    ReactionWidget,
    ReactionToggled,
)
from .debug_panel import DebugPanel
# NOTE: LoadingOverlay NOT imported - auth flow goes directly from AuthScreen to Main UI
from .context_menu import (
    ContextMenu,
    EditMessageRequested,
    DeleteMessageRequested,
    OpenEmojiPickerRequested,
)

__all__ = [
    "BufferSidebar",
    "BufferSelected",
    "MessageList",
    "MessageItem",
    "MessageWidget",
    "MessageWidgetClicked",
    "ThreadPanel",
    "ThreadReplyRequested",
    "StartReplyRequested",
    "ShowThreadRequested",
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
    # NOTE: LoadingOverlay NOT exported - auth flow goes directly from AuthScreen to Main UI
    "ContextMenu",
    "EditMessageRequested",
    "DeleteMessageRequested",
    "OpenEmojiPickerRequested",
]
