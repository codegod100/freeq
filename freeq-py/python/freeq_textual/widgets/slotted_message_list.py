"""Slotted message list - widget-based message display with slots.

Replaces RichLog/ScrollableLog with a Vertical container of MessageItem widgets.
Each message has a slot below it for mounting components reactively.

Much modular. So reactive. Very slot.
"""

from textual.containers import Vertical
from textual.message import Message
from textual.widget import Widget
from rich.text import Text

from .debug import _dbg
from .message_item import MessageItem


class SlottedMessageList(Vertical):
    """A message list where each message has a slot below it.

    Architecture:
    - Vertical container holds MessageItem widgets
    - Each MessageItem has: message_area + slot
    - Components mount into slots reactively

    Unlike RichLog which renders text lines, this uses actual widgets
    enabling true slot-based reactive component mounting.
    """

    DEFAULT_CSS = """
    SlottedMessageList {
        width: 1fr;
        height: 1fr;
        overflow-y: auto;
        border: solid $panel-lighten-2;
        background: $surface;
        display: block;
        scrollbar-gutter: stable;
    }

    SlottedMessageList MessageItem {
        width: 1fr;
        height: auto;
        display: block;
    }
    """

    class MessageClicked(Message):
        """Emitted when a message is clicked."""
        def __init__(self, msgid: str | None, widget: MessageItem) -> None:
            self.msgid = msgid
            self.widget = widget
            super().__init__()

    class ScrolledToTop(Message, bubble=True):
        """Emitted when scrolled to top (for infinite scroll)."""
        pass

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        # Track msgid -> MessageItem mapping for quick lookup
        self._msgid_to_item: dict[str, MessageItem] = {}
        # Track which item has an active slot
        self._active_slot_item: MessageItem | None = None

    def write(
        self,
        content: Text | str,
        msgid: str | None = None,
        thread_root: str | None = None,
    ) -> "SlottedMessageList":
        """Add a message to the list.

        Creates a MessageItem with empty slot below the message.
        """
        _dbg(f"SlottedMessageList.write: msgid={msgid[:8] if msgid else None} content_type={type(content).__name__} content_len={len(str(content))}")
        item = MessageItem(
            content=content,
            msgid=msgid,
            thread_root=thread_root,
        )

        # Track by msgid for quick lookup
        if msgid:
            self._msgid_to_item[msgid] = item

        # Mount the item
        self.mount(item)

        # Auto-scroll to bottom (deferred to allow mount to complete)
        self.call_after_refresh(self.scroll_end, animate=False)

        return self

    def clear(self) -> None:
        """Clear all messages and slots."""
        self._msgid_to_item.clear()
        self._active_slot_item = None
        # Remove all children
        for child in list(self.children):
            child.remove()

    def on_message_item_clicked(self, event: MessageItem.Clicked) -> None:
        """Handle message click - emit MessageClicked."""
        event.stop()
        _dbg(f"SlottedMessageList: message clicked msgid={event.msgid[:8] if event.msgid else None}")
        # Pass the widget from the event (includes thread_root for reply indicators)
        self.post_message(self.MessageClicked(event.msgid, event.widget))

    def mount_in_slot(self, msgid: str | None, widget: Widget) -> None:
        """Mount a widget into the slot of a specific message.

        If another slot is active, it gets cleared first.
        Such exclusive. Much single-focus.
        """
        if not msgid or msgid not in self._msgid_to_item:
            _dbg(f"SlottedMessageList: cannot mount, msgid={msgid[:8] if msgid else None} not found")
            return

        item = self._msgid_to_item[msgid]

        # Clear any existing active slot
        if self._active_slot_item and self._active_slot_item != item:
            self._active_slot_item.clear_slot()

        # Mount into this item's slot
        item.mount_in_slot(widget)
        self._active_slot_item = item

        # Scroll to make slot visible
        item.scroll_visible()

    def clear_active_slot(self) -> None:
        """Clear whichever slot is currently active."""
        if self._active_slot_item:
            self._active_slot_item.clear_slot()
            self._active_slot_item = None

    def watch_scroll_y(self, old_value: float, new_value: float) -> None:
        """Detect when scrolled to top and emit ScrolledToTop for infinite scroll."""
        # Call parent's watcher to update scrollbar
        super().watch_scroll_y(old_value, new_value)
        # When scroll_y crosses into threshold (<5), we're at the top
        if new_value < 5 and old_value >= 5:
            self.post_message(self.ScrolledToTop())

    def on_mouse_scroll_up(self, event) -> None:
        """Detect scroll-up gesture when already at top."""
        # If we're at or near the top, request history directly
        if self.scroll_y < 5:
            self.post_message(self.ScrolledToTop())

    def msgid_at(self, y: int) -> str | None:
        """Get msgid at given y coordinate.

        Used for compatibility with old coordinate-based lookup.
        """
        # Get child at approximate offset
        # This is approximate since widgets have different heights
        offset = 0
        for child in self.children:
            if not isinstance(child, MessageItem):
                continue
            height = child.size.height if child.size else 1
            if offset <= y < offset + height:
                return child.msgid
            offset += height
        return None

    def scroll_to_msgid(self, msgid: str) -> None:
        """Scroll to make message with given msgid visible."""
        if msgid in self._msgid_to_item:
            self._msgid_to_item[msgid].scroll_visible()
