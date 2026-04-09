# @phoenix-canon: IU-517684c6 - Requirements Domain
"""Buffer sidebar widget for FreeQ TUI."""

import logging
from textual.widget import Widget
from textual.containers import Vertical, VerticalScroll
from textual.reactive import reactive
from textual.widgets import Static, Label, Button
from textual.message import Message

from ..models import BufferState, BufferType, AppState, BufferSelectedData

logger = logging.getLogger(__name__)


# @phoenix-canon: node-c385163a
class BufferSidebar(Widget):
    """Sidebar showing list of buffers (channels/queries).
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    BufferSidebar {
        width: 100%;
        height: 100%;
        border: solid $primary;
        background: $surface;
    }
    BufferSidebar .buffer-list {
        height: 1fr;
        overflow-y: scroll;
    }
    BufferSidebar .buffer-item {
        height: auto;
        padding: 0 1;
    }
    BufferSidebar .buffer-item:hover {
        background: $surface-darken-1;
    }
    BufferSidebar .buffer-item.active {
        background: $primary-darken-2;
    }
    BufferSidebar .buffer-item .name {
        text-style: bold;
    }
    BufferSidebar .buffer-item .unread {
        color: $success;
        text-style: bold;
    }
    BufferSidebar .buffer-item .unread-count {
        background: $error;
        color: $text;
        padding: 0 1;
        text-style: bold;
    }
    """
    
    # @phoenix-canon: node-77eff8b8
    buffers = reactive(dict)
    active_buffer = reactive(None)
    
    def __init__(
        self,
        app_state: AppState = None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize sidebar widget.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.app_state = app_state or AppState()
        self.buffers = self.app_state.buffers if self.app_state else {}
    
    def compose(self):
        """Compose sidebar layout."""
        # @phoenix-canon: node-c385163a
        logger.info("[UI] BufferSidebar composing layout")
        yield Label("Buffers", classes="header")
        with VerticalScroll(classes="buffer-list"):
            for buffer_id, buffer in self.buffers.items():
                yield self._create_buffer_widget(buffer_id, buffer)
        logger.info(f"[UI] BufferSidebar composed with {len(self.buffers)} buffers")
    
    def _create_buffer_widget(self, buffer_id: str, buffer: BufferState) -> Widget:
        """Create widget for a single buffer."""
        classes = "buffer-item"
        if buffer_id == self.active_buffer:
            classes += " active"
        
        unread_indicator = ""
        if buffer.unread_count > 0:
            unread_indicator = f" [{buffer.unread_count}]"
        
        buffer_type_indicator = "#" if buffer.buffer_type == BufferType.CHANNEL else "@"
        
        widget = Static(
            f"{buffer_type_indicator}{buffer.name}{unread_indicator}",
            classes=classes
        )
        widget.buffer_id = buffer_id
        return widget
    
    # @phoenix-canon: node-43cb8709
    def watch_buffers(self, buffers: dict):
        """React to buffer changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            logger.debug("[REACTIVE] watch_buffers called but not mounted, skipping")
            return
        
        logger.info(f"[REACTIVE] watch_buffers: updating with {len(buffers)} buffers")
        buffer_list = self.query_one(".buffer-list", VerticalScroll)
        buffer_list.remove_children()
        
        for buffer_id, buffer in buffers.items():
            buffer_list.mount(self._create_buffer_widget(buffer_id, buffer))
        
        logger.info(f"[REACTIVE] watch_buffers: rendered {len(buffers)} buffers")
    
    # @phoenix-canon: node-43cb8709
    def watch_active_buffer(self, active_buffer: str):
        """React to active buffer change.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        for widget in self.query(".buffer-item"):
            if hasattr(widget, 'buffer_id') and widget.buffer_id == active_buffer:
                widget.add_class("active")
            else:
                widget.remove_class("active")
    
    def update_buffers(self, buffers: dict):
        """Update buffer list."""
        self.buffers = buffers
    
    def on_click(self, event):
        """Handle buffer selection."""
        widget = event.control
        if hasattr(widget, 'buffer_id'):
            self.post_message(BufferSelected(
                buffer_id=widget.buffer_id,
                buffer_name=self.buffers.get(widget.buffer_id, BufferState()).name,
                buffer_type=self.buffers.get(widget.buffer_id, BufferState()).buffer_type
            ))


# @phoenix-canon: node-2c760e46
class BufferSelected(Message):
    """Buffer selection event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(
        self,
        buffer_id: str,
        buffer_name: str,
        buffer_type: BufferType = BufferType.CHANNEL
    ):
        """Initialize buffer selected message."""
        super().__init__()  # REQUIRED for Textual messages
        self.buffer_id = buffer_id
        self.buffer_name = buffer_name
        self.buffer_type = buffer_type
