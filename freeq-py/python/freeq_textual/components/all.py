"""Register all swappable components.

All interactive widgets should be registered here so they can be swapped out.
DO NOT import widgets directly - use get_component('name') instead.
"""

from ..components import ComponentRegistry

# Import widgets to register
from ..widgets.thread_panel import ThreadPanel
from ..widgets.buffer_list import BufferList
from ..widgets.scrollable_log import ScrollableLog
from ..widgets.slotted_message_list import SlottedMessageList
from ..widgets.messages_panel import MessagesPanel, MessagesPanelWithThread
from ..widgets.spinner import LoadingOverlay, InlineSpinner
from ..widgets.slots import Slot, SlottedMessageItem, SlotManager
from ..widgets.sum_slots import (
    SumSlot,
    MessageActionsSlot,
    ThreadPanelSlot,
    SumSlotManager,
)

# Import built-in components (they register themselves via decorator)
from .emoji_picker import EmojiPicker  # noqa: F401 - registers as friend!

# Register all components - EVERYONE IS A FRIEND!
ComponentRegistry._components['thread_panel'] = ThreadPanel
ComponentRegistry._components['buffer_list'] = BufferList
ComponentRegistry._components['scrollable_log'] = ScrollableLog
ComponentRegistry._components['slotted_message_list'] = SlottedMessageList
ComponentRegistry._components['messages_panel'] = MessagesPanel
ComponentRegistry._components['messages_panel_with_thread'] = MessagesPanelWithThread
ComponentRegistry._components['loading_overlay'] = LoadingOverlay
ComponentRegistry._components['inline_spinner'] = InlineSpinner
ComponentRegistry._components['slot'] = Slot
ComponentRegistry._components['slotted_message_item'] = SlottedMessageItem
ComponentRegistry._components['slot_manager'] = SlotManager
# Sum type slots
ComponentRegistry._components['sum_slot'] = SumSlot
ComponentRegistry._components['message_actions_slot'] = MessageActionsSlot
ComponentRegistry._components['thread_panel_slot'] = ThreadPanelSlot
ComponentRegistry._components['sum_slot_manager'] = SumSlotManager
# EmojiPicker registers itself via @ComponentRegistry.register decorator!

__all__ = [
    'ThreadPanel',
    'BufferList', 
    'ScrollableLog',
    'SlottedMessageList',
    'MessagesPanel',
    'MessagesPanelWithThread',
    'LoadingOverlay',
    'InlineSpinner',
    'Slot',
    'SlottedMessageItem',
    'SlotManager',
    'SumSlot',
    'MessageActionsSlot',
    'ThreadPanelSlot',
    'SumSlotManager',
    'EmojiPicker',
]"
