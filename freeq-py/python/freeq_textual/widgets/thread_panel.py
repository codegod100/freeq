"""ThreadPanel widget - panel showing thread messages with header, close button, and reply input."""

from dataclasses import dataclass

from rich.text import Text
from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.reactive import reactive
from textual.widget import Widget
from textual.widgets import Button, Input, Static

from .debug import _dbg
from .scrollable_log import ScrollableLog


@dataclass
class ThreadMessage:
    """A message in a thread."""
    sender: str
    text: str


class ThreadPanelContent(Vertical):
    """The actual thread content - mounted when visible, unmounted when hidden."""

    DEFAULT_CSS = """
    ThreadPanelContent {
        border: round $success;
        padding: 0 1;
        background: $surface;
        width: 1fr;
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

    def __init__(self, thread_root: str, messages: list[ThreadMessage], formatter) -> None:
        super().__init__()
        self.thread_root = thread_root
        self._messages = messages
        self._formatter = formatter

    def compose(self) -> None:
        """Compose the thread panel's internal widgets."""
        with Horizontal(id="thread-header-row"):
            yield Static("", id="thread-header")
            yield Button("Close", id="thread-close")
        yield ScrollableLog(id="thread-messages", highlight=True, markup=False, min_width=0, wrap=True, auto_scroll=True)
        yield Input(placeholder="Reply to thread...", id="thread-reply")

    def on_mount(self) -> None:
        """Called when widget is mounted - render messages."""
        messages = self._messages
        if not messages:
            return

        _dbg(f"ThreadPanelContent.on_mount({self.thread_root[:8]!r}, {len(messages)} msgs)")

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
        width = max(40, log.size.width - 3)  # account for scrollbar and padding
        for msg in messages:
            formatted = formatter(msg.sender, msg.text, width)
            log.write(formatted)
            log.write(Text(" "))
        _dbg(f"  after writes: lines={len(log.lines)}")

        # Focus the reply input
        reply_input.focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle close button press."""
        if event.button.id == "thread-close":
            event.stop()
            # Parent ThreadPanel handles removal
            self.parent._request_close()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle reply submission."""
        if event.input.id == "thread-reply":
            event.stop()
            text = event.value.strip()
            if text and self.thread_root:
                event.input.value = ""
                # Parent ThreadPanel handles reply
                self.parent._send_reply(text, self.thread_root)
                # Re-focus for rapid replies
                event.input.focus()


class ThreadPanel(Widget):
    """Container that mounts/unmounts ThreadPanelContent based on visibility."""

    DEFAULT_CSS = """
    ThreadPanel {
        width: auto;
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

    def compose(self):
        """Start empty - content mounted on open()."""
        yield from ()  # Empty - content mounted dynamically

    def is_open(self) -> bool:
        """Check if panel is currently open."""
        try:
            self.query_one(ThreadPanelContent)
            return True
        except Exception:
            return False

    def open(self, thread_root: str, messages: list[ThreadMessage], formatter) -> None:
        """Open the panel by mounting content."""
        _dbg(f"ThreadPanel.open({thread_root[:8]!r}, {len(messages)} msgs)")

        # Remove existing content if any
        try:
            old = self.query_one(ThreadPanelContent)
            old.remove()
        except Exception:
            pass

        # Mount new content - on_mount will fire
        content = ThreadPanelContent(thread_root, messages, formatter)
        self.mount(content)

    def close(self) -> None:
        """Close the panel by unmounting content."""
        _dbg(f"ThreadPanel.close()")
        try:
            content = self.query_one(ThreadPanelContent)
            _dbg(f"  removing content with {len(content.query_one('#thread-messages', ScrollableLog).lines)} lines")
            content.remove()
        except Exception as e:
            _dbg(f"  exception removing content: {e}")
        self.post_message(self.Closed())

    def _request_close(self) -> None:
        """Called by content when close button pressed."""
        self.close()

    def _send_reply(self, text: str, thread_root: str) -> None:
        """Called by content when reply submitted."""
        self.post_message(self.ReplySent(text, thread_root))