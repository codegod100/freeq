"""Custom widgets for freeq-textual."""

from .buffer_list import BufferList
from .debug import (
    _dbg,
    _error,
    _warn,
    check_render_pipeline,
    check_slot_operation,
    check_widget_state,
    log_operation,
    log_state_snapshot,
    set_context,
    set_debug_callback,
    validate_invariant,
    validate_warning,
)
from .debug_panel import DebugPanel
from .layout_render import LayoutAwareRender, RenderablePanel
from .message_item import MessageItem
from .slotted_message_list import SlottedMessageList
from .slots import Slot, SlottedMessageItem, SlotManager, slot_manager
from .spinner import BaseSpinner, InlineSpinner, LoadingOverlay
from .sum_slots import (
    ContentSlot,
    InlineActionsSlot,
    OverlaySlot,
    SidePanelSlot,
    SlotCoordinator,
    SlotType,
    SlotVariantRegistry,
    TypedSlot,
    slot_coordinator,
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
    "ContentSlot",
    "DebugPanel",
    "InlineActionsSlot",
    "InlineSpinner",
    "LayoutAwareRender",
    "LoadingOverlay",
    "MessageItem",
    "MessagesPanel",
    "MessagesPanelWithThread",
    "OverlaySlot",
    "RenderablePanel",
    "ScrollableLog",
    "SidePanelSlot",
    "Slot",
    "SlotCoordinator",
    "SlotManager",
    "SlotType",
    "SlotVariantRegistry",
    "SlottedMessageItem",
    "SlottedMessageList",
    "ThreadMessage",
    "ThreadPanel",
    "TypedSlot",
    "_dbg",
    "_error",
    "_warn",
    "check_render_pipeline",
    "check_slot_operation",
    "check_widget_state",
    "get_component",
    "log_operation",
    "log_state_snapshot",
    "set_context",
    "set_debug_callback",
    "slot_coordinator",
    "slot_manager",
    "validate_invariant",
    "validate_warning",
]
