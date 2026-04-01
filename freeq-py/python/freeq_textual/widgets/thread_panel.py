"""ThreadPanel widget - panel showing thread messages with header, close button, and reply input.

WE'RE ALL FRIENDS HERE! This widget is registered in components/all.py
"""

from dataclasses import dataclass

from rich.text import Text
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Button, Input, Static

from .debug import _dbg
from .scrollable_log import ScrollableLog

# Import AutoLogMixin directly from builtins to avoid circular import
from ..components.builtins import AutoLogMixin


@dataclass
class ThreadMessage:
    """A message in a thread."""
    sender: str
    text: str


class ThreadPanel(AutoLogMixin, Vertical):
    """Thread panel showing thread messages with header, close button, and reply input.
    
    Can be used in two modes:
    1. As a sibling in Horizontal layout (display toggled to show/hide)
    2. As an overlay panel (traditional mode, docked)
    """

    DEFAULT_CSS = """
    ThreadPanel {
        width: 30;
        min-width: 24;
        max-width: 50;
        border: round $success;
        padding: 0 1;
        background: $surface;
        display: none;  /* Hidden by default, shown via display: block */
    }
    
    ThreadPanel.shown {
        display: block;
    }

    #thread-header-row {
        height: auto;
        padding: 0 0 1 0;
        align: center middle;
    }

    #thread-header {
        text-style: bold;
        width: 1fr;
    }

    #thread-close {
        min-width: 8;
        width: auto;
        height: 1;
        padding: 0 1;
        border: none;
        background: transparent;
    }

    #thread-messages {
        height: 1fr;
        min-height: 3;
    }

    #thread-reply {
        dock: bottom;
        height: 3;
        margin-top: 1;
    }
    """

    class Closed(Message):
        """Emitted when the thread panel is closed."""
        pass

    class ReplySent(Message):
        """Emitted when a reply is submitted."""
        def __init__(self, text: str, thread_root: str) -> None:
            self.text = text
            self.thread_root = thread_root
            super().__init__()

    def __init__(self, thread_root: str = "", messages: list[ThreadMessage] | None = None, formatter = None, **kwargs) -> None:
        super().__init__(**kwargs)
        self.thread_root = thread_root
        self._messages = messages or []
        self._formatter = formatter
        
    def show_thread(self, thread_root: str, messages: list[ThreadMessage], formatter) -> None:
        """Populate and show the thread panel."""
        self.thread_root = thread_root
        self._messages = messages
        self._formatter = formatter
        _dbg(f"ThreadPanel.show_thread: {thread_root[:8]} with {len(messages)} msgs, mounted={self.is_mounted}")
        self.add_class("shown")
        # Defer refresh to allow CSS transition and layout to complete
        # Critical: widget goes from display:none to display:block, need layout pass first
        def do_refresh():
            if self.is_mounted:
                self.refresh_messages(messages)
            else:
                _dbg(f"  still not mounted after defer, will render in on_mount")
        self.call_later(do_refresh)
        
    def hide_thread(self) -> None:
        """Hide the thread panel."""
        _dbg(f"ThreadPanel.hide_thread: hiding {self.thread_root[:8] if self.thread_root else 'none'}")
        self.remove_class("shown")

    def compose(self):
        """Compose header, messages, reply input."""
        with Horizontal(id="thread-header-row"):
            yield Static("", id="thread-header")
            yield Button("Close", id="thread-close")
        yield ScrollableLog(id="thread-messages", highlight=True, markup=False, min_width=0, wrap=True, auto_scroll=True)
        yield Input(placeholder="Reply to thread...", id="thread-reply")

    def on_mount(self) -> None:
        super().on_mount()  # AutoLogMixin logs mount
        """Render messages when mounted."""
        messages = self._messages
        if not messages:
            self._log(f"no messages for {self.thread_root[:8]!r}")
            return

        self._log(f"{len(messages)} msgs for {self.thread_root[:8]!r}")

        # Update header
        header = self.query_one("#thread-header", Static)
        header.update(f"Thread ({len(messages)} msg{'s' if len(messages) != 1 else ''})")

        # Update placeholder
        reply_input = self.query_one("#thread-reply", Input)
        reply_input.placeholder = f"Reply to thread ({self.thread_root[:8]}...)"

        # Render messages with width wrapping
        # FIXED: Account for padding and scrollbar gutter (reduced from 6 to 3)
        # ThreadPanel padding (2) + scrollbar gutter (1) = 3
        # ScrollableLog padding is already accounted for in its size.width
        log = self.query_one("#thread-messages", ScrollableLog)
        _dbg(f"  on_mount: lines={len(log.lines)} msgs={len(messages)}")
        log.clear()
        formatter = self._formatter or (lambda s, t, w=0: Text(f"{s}: {t}"))
        width = log.size.width
        effective_width = max(10, width - 3) if width > 0 else 27
        _dbg(f"  on_mount: width={width}, effective_width={effective_width}")
        for msg in messages:
            formatted = formatter(msg.sender, msg.text, effective_width)
            log.write(formatted, width=effective_width)
            log.write(Text(" "))
        _dbg(f"  after writes: lines={len(log.lines)}")

        reply_input.focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        """Handle close button press."""
        if event.button.id == "thread-close":
            event.stop()
            self.post_message(self.Closed())

    def on_input_submitted(self, event: Input.Submitted) -> None:
        super().on_input_submitted(event)  # AutoLogMixin logs input
        """Handle reply submission."""
        if event.input.id == "thread-reply":
            text = event.value.strip()
            event.stop()
            if text and self.thread_root:
                event.input.value = ""
                self.post_message(self.ReplySent(text, self.thread_root))
                event.input.focus()

    def is_open(self) -> bool:
        """Return True if panel is visible (has 'shown' class)."""
        return "shown" in self.classes

    def refresh_messages(self, messages: list[ThreadMessage]) -> None:
        """Refresh with new messages.
        
        WIDTH CALCULATION NOTES:
        The thread panel is narrow (default 30 chars). We need to account for:
        - ThreadPanel padding: 1 left + 1 right = 2 chars  
        - ScrollableLog scrollbar-gutter: 1 char (with 'stable')
        - Total overhead: ~3 chars (ScrollableLog padding is internal to its width)
        
        So content width = widget width - 3 (approximately).
        This prevents text from being covered by the scrollbar gutter.
        """
        _dbg(f"ThreadPanel.refresh_messages: {len(messages)} msgs, mounted={self.is_mounted}")
        if not self.is_mounted:
            _dbg(f"  SKIPPING - not mounted")
            return
        self._messages = messages
        # Re-render
        log = self.query_one("#thread-messages", ScrollableLog)
        width = log.size.width
        # Guard: if width is 0 (widget transitioning from hidden), use sensible default
        if width <= 0:
            width = 30  # Default width for thread panel
            _dbg(f"  width was 0, using default {width}")
        
        # FIXED: Reduce subtraction from 6 to 3
        # Previous: width - 6 (too conservative, caused early wrapping)
        # ThreadPanel padding (2) + scrollbar gutter (1) = 3
        # ScrollableLog padding is already accounted for in its size.width
        effective_width = max(10, width - 3)
        _dbg(f"  log width={width}, effective_width={effective_width}, writing {len(messages)} messages")
        
        log.clear()
        for i, msg in enumerate(messages):
            formatted = self._formatter(msg.sender, msg.text, effective_width)
            log.write(formatted, width=effective_width)
            log.write(Text(" "))
            _dbg(f"    wrote msg {i}: {msg.sender[:10]}...")
        
        header = self.query_one("#thread-header", Static)
        header.update(f"Thread ({len(messages)} msg{'s' if len(messages) != 1 else ''})")
        _dbg(f"  header updated, lines={len(log.lines)}")