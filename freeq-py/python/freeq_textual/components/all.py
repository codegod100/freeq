"""Register all swappable components.

All interactive widgets should be registered here so they can be swapped out.
DO NOT import widgets directly - use get_component('name') instead.
"""

from ..components import ComponentRegistry

# Import widgets to register
from ..widgets.thread_panel import ThreadPanel
from ..widgets.buffer_list import BufferList
from ..widgets.scrollable_log import ScrollableLog
from ..widgets.messages_panel import MessagesPanel, MessagesPanelWithThread
from ..widgets.spinner import LoadingOverlay, InlineSpinner

# Register all components
ComponentRegistry._components['thread_panel'] = ThreadPanel
ComponentRegistry._components['buffer_list'] = BufferList
ComponentRegistry._components['scrollable_log'] = ScrollableLog
ComponentRegistry._components['messages_panel'] = MessagesPanel
ComponentRegistry._components['messages_panel_with_thread'] = MessagesPanelWithThread
ComponentRegistry._components['loading_overlay'] = LoadingOverlay
ComponentRegistry._components['inline_spinner'] = InlineSpinner

# Built-in components (ReplyPanel, ContextMenu) are registered in builtins.py

__all__ = [
    'ThreadPanel',
    'BufferList', 
    'ScrollableLog',
    'MessagesPanel',
    'MessagesPanelWithThread',
    'LoadingOverlay',
    'InlineSpinner',
]