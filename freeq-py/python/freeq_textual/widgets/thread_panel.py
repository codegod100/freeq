"""ThreadPanel widget - panel showing thread messages with header, close button, and reply input."""

from dataclasses import dataclass

from rich.text import Text
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Button, Input, Static

from .debug import _dbg
from .scrollable_log import ScrollableLog


@dataclass
class ThreadMessage:
    """A message in a thread."""
    sender: str
    text: str


class ThreadPanel(Vertical):
    """Open thread panel with width 30%. Mounted when open, removed when closed."""

    DEFAULT_CSS = """
    ThreadPanel {
        width: 30%;
        min-width: 24;
        max-width: 50;
        border: round $success;
        padding: 0 1;
        background: $surface;
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

    def __init__(self, thread_root: str, messages: list[ThreadMessage], formatter, **kwargs) -> None:
        super().__init__(**kwargs)
        self.thread_root = thread_root
        self._messages = messages
        self._formatter = formatter

    def compose(self):
        """Compose header, messages, reply input."""
        with Horizontal(id="thread-header-row"):
            yield Static("", id="thread-header")
            yield Button("Close", id="thread-close")
        yield ScrollableLog(id="thread-messages", highlight=True, markup=False, min_width=0, wrap=True, auto_scroll=True)
        yield Input(placeholder="Reply to thread...", id="thread-reply")

    def on_mount(self) -> None:
        """Render messages when mounted."""
        messages = self._messages
        if not messages:
            _dbg(f"ThreadPanel.on_mount({self.thread_root[:8]!r}, no messages)")
            return

        _dbg(f"ThreadPanel.on_mount({self.thread_root[:8]!r}, {len(messages)} msgs)")

        # Update header
        header = self.query_one("#thread-header", Static)
        header.update(f"Thread ({len(messages)} msg{'s' if len(messages) != 1 else ''})")

        # Update placeholder
        reply_input = self.query_one("#thread-reply", Input)
        reply_input.placeholder = f"Reply to thread ({self.thread_root[:8]}...)"

        # Render messages with width wrapping
        log = self.query_one("#thread-messages", ScrollableLog)
        _dbg(f"  on_mount: lines={len(log.lines)} msgs={len(messages)}")
        log.clear()
        formatter = self._formatter or (lambda s, t, w=0: Text(f"{s}: {t}"))
        width = log.size.width
        for msg in messages:
            formatted = formatter(msg.sender, msg.text, width)
            # Only pass width if > 0, otherwise let RichLog compute it
            if width > 0:
                log.write(formatted, width=width)
            else:
                log.write(formatted)
            log.write(Text(" "))
        _dbg(f"  after writes: lines={len(log.lines)}")

        reply_input.focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle close button press."""
        if event.button.id == "thread-close":
            _dbg(f"ThreadPanel.on_button_pressed(close)")
            event.stop()
            self.post_message(self.Closed())

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle reply submission."""
        if event.input.id == "thread-reply":
            text = event.value.strip()
            _dbg(f"ThreadPanel.on_input_submitted(text={text[:20]!r}...)")
            event.stop()
            if text and self.thread_root:
                event.input.value = ""
                self.post_message(self.ReplySent(text, self.thread_root))
                event.input.focus()

    def is_open(self) -> bool:
        """Always True - panel is only mounted when open."""
        return True

    def refresh_messages(self, messages: list[ThreadMessage]) -> None:
        """Refresh with new messages."""
        self._messages = messages
        # Re-render
        log = self.query_one("#thread-messages", ScrollableLog)
        log.clear()
        width = log.size.width
        for msg in messages:
            formatted = self._formatter(msg.sender, msg.text, width)
            if width > 0:
                log.write(formatted, width=width)
            else:
                log.write(formatted)
            log.write(Text(" "))
        
        header = self.query_one("#thread-header", Static)
        header.update(f"Thread ({len(messages)} msg{'s' if len(messages) != 1 else ''})")