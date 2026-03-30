"""Custom widgets for freeq-textual."""

from dataclasses import dataclass

from rich.text import Text
from textual import events
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Button, Input, ListItem, ListView, RichLog, Static


class BufferList(ListView):
    """Sidebar widget showing list of buffers (channels and DMs)."""

    def update_buffers(self, buffers: list, active: str) -> None:
        """Update the buffer list with current buffers and mark active one."""
        self.clear()
        for buffer in buffers:
            label = buffer.name
            if buffer.unread:
                label = f"{label} ({buffer.unread})"
            item = ListItem(Static(label), name=buffer.name)
            if buffer.name == active:
                item.add_class("active")
            self.append(item)


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
        yield RichLog(id="thread-messages", highlight=True, markup=False, min_width=0, wrap=True, auto_scroll=True)
        yield Input(placeholder="Reply to thread...", id="thread-reply")

    def open(self, thread_root: str, messages: list[ThreadMessage], formatter) -> None:
        """Open the panel for a specific thread.

        Args:
            thread_root: The root msgid of the thread
            messages: List of ThreadMessage objects to display
            formatter: Callable(sender, text) -> Text to format messages
        """
        self.open_root = thread_root
        self.add_class("visible")

        # Update header
        header = self.query_one("#thread-header", Static)
        count = len(messages)
        header.update(f"Thread ({count} msg{'s' if count != 1 else ''})")

        # Update placeholder
        reply_input = self.query_one("#thread-reply", Input)
        reply_input.placeholder = f"Reply to thread ({thread_root[:8]}...)"

        # Render messages
        log = self.query_one("#thread-messages", RichLog)
        log.clear()
        for msg in messages:
            formatted = formatter(msg.sender, msg.text)
            log.write(formatted)
            log.write(Text(" "))

        # Focus the reply input
        reply_input.focus()

    def close(self) -> None:
        """Close the thread panel."""
        self.open_root = ""
        self.remove_class("visible")
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