"""ThreadPanel widget - panel showing thread messages with header, close button, and reply input."""

from dataclasses import dataclass

from rich.text import Text
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.reactive import reactive
from textual.widgets import Button, Input, Static

from .debug import _dbg
from .scrollable_log import ScrollableLog


@dataclass
class ThreadMessage:
    """A message in a thread."""
    sender: str
    text: str


class ThreadPanel(Vertical):
    """A panel showing a thread's messages with a header, close button, and reply input."""

    DEFAULT_CSS = """
    ThreadPanel {
        display: none;
        border: round $success;
        padding: 0 1;
        background: $surface;
    }

    ThreadPanel.visible {
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

    open_root: reactive[str] = reactive("")
    _messages: reactive[list[ThreadMessage]] = reactive(list)
    _formatter: reactive[object] = reactive(None)

    class Closed(Message):
        """Emitted when the thread panel is closed."""
        pass

    class ReplySent(Message):
        """Emitted when a reply is submitted."""
        def __init__(self, text: str, thread_root: str) -> None:
            self.text = text
            self.thread_root = thread_root
            super().__init__()

    def compose(self) -> None:
        """Compose the thread panel's internal widgets."""
        with Horizontal(id="thread-header-row"):
            yield Static("", id="thread-header")
            yield Button("Close", id="thread-close")
        yield ScrollableLog(id="thread-messages", highlight=True, markup=False, min_width=0, wrap=True, auto_scroll=True)
        yield Input(placeholder="Reply to thread...", id="thread-reply")

    def open(self, thread_root: str, messages: list[ThreadMessage], formatter) -> None:
        """Open the panel for a specific thread.

        Args:
            thread_root: The root msgid of the thread
            messages: List of ThreadMessage objects to display
            formatter: Callable(sender, text) -> Text to format messages
        """
        _dbg(f"ThreadPanel.open({thread_root[:8]!r}, {len(messages)} msgs)")
        self.open_root = thread_root
        self._messages = messages
        self._formatter = formatter
        self.add_class("visible")

    def watch__messages(self, messages: list[ThreadMessage]) -> None:
        """Reactive watcher - renders messages when _messages changes."""
        if not messages:
            return

        # Update header
        header = self.query_one("#thread-header", Static)
        header.update(f"Thread ({len(messages)} msg{'s' if len(messages) != 1 else ''})")

        # Update placeholder
        reply_input = self.query_one("#thread-reply", Input)
        reply_input.placeholder = f"Reply to thread ({self.open_root[:8]}...)"

        # Render messages
        log = self.query_one("#thread-messages", ScrollableLog)
        _dbg(f"  watch__messages: lines={len(log.lines)} msgs={len(messages)}")
        log.clear()
        formatter = self._formatter or (lambda s, t: Text(f"{s}: {t}"))
        for msg in messages:
            formatted = formatter(msg.sender, msg.text)
            log.write(formatted)
            log.write(Text(" "))
        _dbg(f"  after writes: lines={len(log.lines)}")

        # Focus the reply input
        reply_input.focus()

    def close(self) -> None:
        """Close the thread panel."""
        _dbg(f"ThreadPanel.close() open_root was {self.open_root[:8] if self.open_root else 'empty'}")
        self.open_root = ""
        self._messages = []
        self.remove_class("visible")

        # Clear the message log
        try:
            log = self.query_one("#thread-messages", ScrollableLog)
            _dbg(f"  clearing ScrollableLog, had {len(log.lines)} lines")
            log.clear()
        except Exception as e:
            _dbg(f"  exception clearing ScrollableLog: {e}")

        self.post_message(self.Closed())

    @staticmethod
    def _with_trailing_padding(text: Text) -> Text:
        """Ensure text has trailing padding for readability."""
        if not text.plain.endswith(" "):
            text.append(" ")
        return text

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle close button press."""
        if event.button.id == "thread-close":
            event.stop()
            self.close()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle reply submission."""
        if event.input.id == "thread-reply":
            event.stop()
            text = event.value.strip()
            if text and self.open_root:
                event.input.value = ""
                self.post_message(self.ReplySent(text, self.open_root))
                # Re-focus for rapid replies
                event.input.focus()