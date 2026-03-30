"""Custom widgets for freeq-textual."""

from .buffer_list import BufferList
from .debug import _dbg, set_debug_callback
from .debug_panel import DebugPanel
from .layout_render import LayoutAwareRender, RenderablePanel
from .spinner import BaseSpinner, InlineSpinner, LoadingOverlay
from .messages_panel import MessagesPanel, MessagesPanelWithThread
from .scrollable_log import ScrollableLog
from .thread_panel import ThreadMessage, ThreadPanel

# Note: ReplyPanel and ContextMenu moved to components/ for swappability
# Use get_component('reply_panel') or get_component('context_menu') instead

__all__ = [
    "BaseSpinner",
    "BufferList",
    "DebugPanel",
    "InlineSpinner",
    "LayoutAwareRender",
    "LoadingOverlay",
    "MessagesPanel",
    "MessagesPanelWithThread",
    "RenderablePanel",
    "ScrollableLog",
    "ThreadMessage",
    "ThreadPanel",
    "_dbg",
    "set_debug_callback",
]