"""Message item widget with slot for context menu.

WE'RE ALL FRIENDS HERE! This widget provides a slot-based architecture
where each message has a reserved slot below it for mounting components.
"""

from rich.text import Text
from textual.containers import Vertical
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Static

from .debug import _dbg


class MessageItem(Vertical):
    """A message with a slot below it for mounting components.
    
    Architecture:
    - message_area: displays the message content
    - slot: empty container below message, holds mounted components
    
    When clicked, the ContextMenu (or other components) mounts into the slot.
    When action completes, the component is destroyed and slot is empty again.
    
    Such modular. Much reactive.
    """
    
    DEFAULT_CSS = """
    MessageItem {
        height: auto;
        width: 1fr;
        display: block;
    }
    
    MessageItem Static.message-area {
        height: auto;
        width: 1fr;
        display: block;
    }
    
    MessageItem #slot {
        height: auto;
        width: 1fr;
        display: none;  /* Hidden when empty */
    }
    
    MessageItem #slot.has-content {
        display: block;
        border-top: solid $panel-lighten-2;
        background: $surface-darken-1;
    }
    """
    
    class Clicked(Message):
        """Emitted when message is clicked."""
        def __init__(self, msgid: str | None, line_index: int) -> None:
            self.msgid = msgid
            self.line_index = line_index
            super().__init__()
    
    class SlotCleared(Message):
        """Emitted when slot is cleared (component destroyed)."""
        def __init__(self, msgid: str | None) -> None:
            self.msgid = msgid
            super().__init__()
    
    def __init__(
        self,
        content: Text | str,
        msgid: str | None = None,
        thread_root: str | None = None,
        **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._content = content
        self._msgid = msgid
        self._thread_root = thread_root
        self._slot_content: Widget | None = None
    
    def compose(self):
        """Compose message area and empty slot."""
        # Render Rich Text properly - Static can take Text objects directly
        content = self._content
        content_type = type(content).__name__
        if isinstance(content, Text):
            # Keep as Text object for rich rendering
            content_str = str(content)[:50] + "..." if len(str(content)) > 50 else str(content)
            _dbg(f"MessageItem.compose msgid={self._msgid[:8] if self._msgid else None} type={content_type} content={content_str!r}")
        else:
            content = str(content)
            _dbg(f"MessageItem.compose msgid={self._msgid[:8] if self._msgid else None} type={content_type} content={content[:50]!r}")
        yield Static(content, classes="message-area", markup=True)
        yield Vertical(id="slot")
    
    def on_mount(self) -> None:
        """Log mount for debugging."""
        _dbg(f"MessageItem mounted msgid={self._msgid[:8] if self._msgid else None}")
    
    def on_click(self, event) -> None:
        """Handle click - emit Clicked message."""
        _dbg(f"MessageItem.on_click msgid={self._msgid[:8] if self._msgid else None}")
        self.post_message(self.Clicked(self._msgid, 0))
    
    def mount_in_slot(self, widget: Widget) -> None:
        """Mount a widget into the slot below this message.
        
        Lifecycle:
        1. Clear any existing content
        2. Mount new widget
        3. Add has-content class to show slot
        """
        slot = self.query_one("#slot", Vertical)
        
        # Clear existing
        if self._slot_content:
            self._slot_content.remove()
            self._slot_content = None
        
        # Mount new
        self._slot_content = widget
        slot.mount(widget)
        slot.add_class("has-content")
        _dbg(f"MessageItem mounted widget in slot msgid={self._msgid[:8] if self._msgid else None}")
    
    def clear_slot(self) -> None:
        """Clear the slot - destroy any mounted component.
        
        Lifecycle complete. Much destroy. So reactive.
        """
        slot = self.query_one("#slot", Vertical)
        
        if self._slot_content:
            self._slot_content.remove()
            self._slot_content = None
            slot.remove_class("has-content")
            _dbg(f"MessageItem cleared slot msgid={self._msgid[:8] if self._msgid else None}")
            self.post_message(self.SlotCleared(self._msgid))
    
    def has_slot_content(self) -> bool:
        """Check if slot has mounted content."""
        return self._slot_content is not None
    
    @property
    def msgid(self) -> str | None:
        return self._msgid
    
    @property
    def thread_root(self) -> str | None:
        return self._thread_root
