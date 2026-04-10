# @phoenix-canon: IU-c40ae8a5 - Definitions Domain
"""Message list widget for FreeQ TUI."""

import logging
from textual.widgets import Static
from textual.widget import Widget
from textual.containers import VerticalScroll
from textual.reactive import reactive
from textual.message import Message
from typing import List, Optional

from ..models import Message, BufferState

logger = logging.getLogger(__name__)


# @phoenix-canon: node-c385163a
class MessageList(VerticalScroll):
    """Scrollable list of messages with virtualization.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    MessageList {
        width: 100%;
        height: 1fr;
        overflow-y: scroll;
        background: $surface-darken-1;
    }
    MessageList .messages-container {
        width: 100%;
        height: auto;
        min-height: 100%;
    }
    MessageList .thread-highlight {
        border-left: solid $primary;
    }
    """
    
    messages = reactive(list)
    visible_range = reactive((0, 20))
    highlighted_thread = reactive(None)
    
    def __init__(
        self,
        app_state=None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize message list.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.app_state = app_state
        # Populate messages from active buffer in app_state
        if self.app_state and hasattr(self.app_state, 'ui') and self.app_state.ui:
            active_buffer_id = self.app_state.ui.active_buffer_id
            if active_buffer_id and active_buffer_id in self.app_state.buffers:
                buffer = self.app_state.buffers[active_buffer_id]
                self.messages = list(buffer.messages) if hasattr(buffer, 'messages') else []
            else:
                self.messages = []
        else:
            self.messages = []
        self._pending_messages: List[Message] = []
        self._render_timer = None
    
    def compose(self):
        """Compose message list."""
        # @phoenix-canon: node-c385163a
        logger.info(f"[UI] MessageList composing with {len(self.messages)} messages")
        from .message_item import MessageWidget
        from textual.containers import Vertical
        from textual.containers import Vertical
        count = 0
        with Vertical(classes="messages-container"):
            for msg in self.messages[self.visible_range[0]:self.visible_range[1]]:
                yield MessageWidget(message=msg)
                count += 1
        logger.info(f"[UI] MessageList composed with {count} MessageWidgets, range {self.visible_range}")
    
    # @phoenix-canon: node-43cb8709
    def watch_messages(self, messages: List[Message]):
        """React to message list changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            logger.debug("[REACTIVE] watch_messages called but not mounted, skipping")
            return
        
        logger.info(f"[REACTIVE] watch_messages: updating with {len(messages)} messages")
        self.refresh_messages()
    
    # @phoenix-canon: node-43cb8709
    def watch_visible_range(self, visible_range: tuple):
        """React to visible range changes for virtualization.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        self.refresh_messages()
    
    def refresh_from_buffer(self) -> None:
        """Refresh messages from current active buffer.
        
        Called when new messages arrive from IRC server.
        """
        if not self.app_state:
            return
        
        active_buffer_id = self.app_state.ui.active_buffer_id
        if active_buffer_id and active_buffer_id in self.app_state.buffers:
            buffer = self.app_state.buffers[active_buffer_id]
            self.messages = list(buffer.messages) if hasattr(buffer, 'messages') else []
            logger.info(f"[REACTIVE] MessageList refreshed from buffer {active_buffer_id}: {len(self.messages)} messages")
        else:
            self.messages = []
    
    # @phoenix-canon: node-43cb8709
    def watch_highlighted_thread(self, root_msgid: Optional[str]):
        """Highlight all messages in thread.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        from .message_item import MessageWidget
        for widget in self.query(MessageWidget):
            if root_msgid and widget.message.msgid == root_msgid:
                widget.add_class("thread-highlight")
            else:
                widget.remove_class("thread-highlight")
    
    def refresh_messages(self):
        """Refresh message widgets - incremental update for performance."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            logger.debug("[REACTIVE] refresh_messages called but not mounted, skipping")
            return
        
        try:
            from .message_item import MessageWidget
            from textual.containers import Vertical
            container = self.query_one(".messages-container", Vertical)
            
            # Get current widget count for incremental update
            current_widgets = list(container.children)
            current_count = len(current_widgets)
            start, end = self.visible_range
            target_messages = self.messages[start:end]
            target_count = len(target_messages)
            
            # Only add new messages instead of clearing everything
            if target_count > current_count:
                logger.info(f"[REACTIVE] Adding {target_count - current_count} new messages (total: {target_count})")
                for i in range(current_count, target_count):
                    msg = target_messages[i]
                    widget = MessageWidget(message=msg)
                    container.mount(widget)
                container.refresh()
            elif target_count < current_count:
                # Remove excess widgets
                logger.info(f"[REACTIVE] Removing {current_count - target_count} old messages")
                for widget in current_widgets[target_count:]:
                    widget.remove()
            else:
                logger.debug(f"[REACTIVE] Message count unchanged: {target_count}")
                
        except Exception as e:
            logger.error(f"[REACTIVE] refresh_messages error: {e}", exc_info=True)
    
    def add_message(self, message: Message):
        """Add message to list."""
        self.messages.append(message)
        
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        from .message_item import MessageWidget
        self.mount(MessageWidget(message=message))
        self.scroll_end(animate=False)
    
    def update_message(self, message_id: str, new_content: str):
        """Update existing message (for streaming/editing)."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        from .message_item import MessageWidget
        for widget in self.query(MessageWidget):
            if widget.message.id == message_id:
                widget.update_content(new_content)
                break
    
    def render_messages(self, messages: List[Message]):
        """Render all messages for buffer."""
        self.messages = messages
        
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        self.refresh_messages()
    
    def on_scroll(self):
        """Update visible range on scroll."""
        if not self.is_mounted:
            return
        
        # Calculate visible message indices
        scroll_y = self.scroll_y
        start = int(scroll_y / 3)  # Approx 3 rows per message
        self.visible_range = (max(0, start - 5), start + 25)
    
    def scroll_to_bottom(self):
        """Scroll to bottom of message list."""
        self.scroll_end(animate=False)
    
    def on_message_widget_clicked(self, event):
        """Handle message click."""
        self.post_message(MessageSelected(
            message=event.message,
            is_own_message=event.is_own
        ))


class MessageSelected(Message):
    """Message selection event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, message: Message, is_own_message: bool = False):
        super().__init__()  # REQUIRED for Textual messages
        self.message = message
        self.is_own = is_own_message
