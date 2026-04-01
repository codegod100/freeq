"""Custom widgets for freeq-textual."""

from .buffer_list import BufferList
from .debug import _dbg, set_debug_callback
from .debug_panel import DebugPanel
from .layout_render import LayoutAwareRender, RenderablePanel
from .message_item import MessageItem
from .slotted_message_list import SlottedMessageList
from .slots import Slot, SlottedMessageItem, SlotManager, slot_manager
from .spinner import BaseSpinner, InlineSpinner, LoadingOverlay
from .sum_slots import (
    ComposedSlotMessage,
    MessageActionsSlot,
    SlotVariant,
    SumSlot,
    SumSlotManager,
    ThreadPanelSlot,
    sum_slot_manager,
)
from .messages_panel import MessagesPanel, MessagesPanelWithThread
from .scrollable_log import ScrollableLog
from .thread_panel import ThreadMessage, ThreadPanel

# WE'RE ALL FRIENDS HERE!
# Export get_component so everyone can get their friends!
from ..components import get_component

__all__ = [
    "BaseSpinner",
    "BufferList",
    "ComposedSlotMessage",
    "DebugPanel",
    "InlineSpinner",
    "LayoutAwareRender",
    "LoadingOverlay",
    "MessageActionsSlot",
    "MessageItem",
    "MessagesPanel",
    "MessagesPanelWithThread",
    "RenderablePanel",
    "ScrollableLog",
    "Slot",
    "SlotManager",
    "SlotVariant",
    "SlottedMessageItem",
    "SlottedMessageList",
    "SumSlot",
    "SumSlotManager",
    "ThreadMessage",
    "ThreadPanel",
    "ThreadPanelSlot",
    "_dbg",
    "get_component",
    "set_debug_callback",
    "slot_manager",
    "sum_slot_manager",
]
