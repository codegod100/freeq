"""Message item widget with slot for context menu.

WE'RE ALL FRIENDS HERE! This widget provides a slot-based architecture
where each message has a reserved slot below it for mounting components.
"""

from typing import Optional
from rich.text import Text
from textual.containers import Vertical
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Static

from .debug import _dbg


class MessageItem(Vertical):
    """A message with a slot below it for mounting components.
    
    SLOT ARCHITECTURE PHILOSOPHY:
    
    A slot is NOT a container. It is a mounting point - a place where
    components can temporarily exist. The slot itself has zero visual
    presence: no border, no background, no padding, no height when empty.
    
    Components mounted in the slot (ContextMenu, ReplyPanel, etc.) are
    responsible for their own styling. The slot just provides space.
    
    Structure:
    - message_area (Static): displays the message content (rich text, markdown, etc.)
    - slot (Vertical): invisible mounting point below the message
    
    Lifecycle:
    1. User clicks message -> _show_context_menu_in_slot() called
    2. ContextMenu mounts into the slot via mount_in_slot()
    3. Slot expands from height=0 to height=auto (class has-content added)
    4. User selects action or presses ESC -> ContextMenu calls on_close callback
    5. Slot cleared via clear_slot() -> height returns to 0, invisible again
    
    Key principle: When the slot is empty, it should be as if it doesn't exist.
    When it has content, the content appears inline, not boxed.
    
    Such modular. Much reactive. Very slot.
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
        text-style: none;
        text-wrap: nowrap;
    }
    
    MessageItem #slot {
        /* SLOT PHILOSOPHY: A slot is not a container, it's a mounting point.
         * It should have zero visual presence - no border, no background, no padding.
         * When empty: height 0, completely invisible
         * With content: height auto, expands only to fit the mounted widget
         * The mounted widget (ContextMenu, etc.) provides its own styling.
         */
        height: 0;           /* Zero height when empty - truly invisible */
        width: 1fr;          /* Full width for content */
        display: block;      /* Always block, visibility controlled by height */
        background: transparent;
        border: none;
        padding: 0;
        margin: 0;
    }
    
    MessageItem #slot.has-content {
        /* When slot has content, just expand to fit it.
         * NO styling here - the mounted component (ContextMenu, ReplyPanel, etc.)
         * is responsible for its own appearance. The slot just provides space.
         */
        height: auto;        /* Expand to fit mounted widget */
    }
    """
    
    class Clicked(Message):
        """Emitted when message is clicked."""
        def __init__(self, msgid: str | None, line_index: int, widget: Optional["MessageItem"] = None) -> None:
            self.msgid = msgid
            self.line_index = line_index
            self.widget = widget
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
        from .debug import validate_invariant, validate_warning
        
        # Proactive validation
        validate_invariant(
            self._content is not None,
            "MessageItem content is None",
            msgid=self._msgid
        )
        validate_warning(
            len(str(self._content)) > 0,
            "MessageItem content is empty",
            msgid=self._msgid
        )
        
        # Render Rich Text properly
        content = self._content
        content_type = type(content).__name__
        use_markup = True
        if isinstance(content, Text):
            content_str = str(content)[:50] + "..." if len(str(content)) > 50 else str(content)
            _dbg(f"MessageItem.compose msgid={self._msgid[:8] if self._msgid else None} type={content_type} content={content_str!r}")
            use_markup = False  # Text objects are pre-styled, don't need markup processing
        else:
            content = str(content)
            _dbg(f"MessageItem.compose msgid={self._msgid[:8] if self._msgid else None} type={content_type} content={content[:50]!r}")
        
        yield Static(content, classes="message-area", markup=use_markup)
        yield Vertical(id="slot")
    
    def on_mount(self) -> None:
        """Log mount for debugging."""
        _dbg(f"MessageItem mounted msgid={self._msgid[:8] if self._msgid else None}")
    
    def on_click(self, event) -> None:
        """Handle click - emit Clicked message."""
        _dbg(f"MessageItem.on_click msgid={self._msgid[:8] if self._msgid else None}")
        self.post_message(self.Clicked(self._msgid, 0, self))
    
    def mount_in_slot(self, widget: Widget) -> None:
        """Mount a widget into the slot below this message.
        
        SLOT PHILOSOPHY: The slot is not a container, it's a mounting point.
        
        We don't "contain" the widget - we just provide a place for it to exist.
        The widget (ContextMenu, etc.) is responsible for its own styling.
        The slot just expands to accommodate it, with zero visual presence.
        
        Lifecycle:
        1. Clear any existing content
        2. Mount new widget
        3. Add has-content class to expand slot height (from 0 to auto)
        """
        slot = self.query_one("#slot", Vertical)
        
        # Clear existing - slots are exclusive, only one widget at a time
        if self._slot_content:
            self._slot_content.remove()
            self._slot_content = None
        
        # Mount new widget - the widget provides its own styling
        # We just provide the mounting point (the slot Vertical container)
        self._slot_content = widget
        slot.mount(widget)
        slot.add_class("has-content")  # This just changes height from 0 to auto
        _dbg(f"MessageItem mounted widget in slot msgid={self._msgid[:8] if self._msgid else None}")
    
    def clear_slot(self) -> None:
        """Clear the slot - destroy any mounted component.
        
        SLOT PHILOSOPHY: When empty, the slot should disappear completely.
        Height goes back to 0, making it truly invisible.
        
        Lifecycle complete. Much destroy. So reactive.
        """
        slot = self.query_one("#slot", Vertical)
        
        if self._slot_content:
            self._slot_content.remove()
            self._slot_content = None
            slot.remove_class("has-content")  # Height returns to 0, slot invisible
            _dbg(f"MessageItem cleared slot msgid={self._msgid[:8] if self._msgid else None}")
            self.post_message(self.SlotCleared(self._msgid))
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
