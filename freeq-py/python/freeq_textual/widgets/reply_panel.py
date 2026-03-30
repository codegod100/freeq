"""ReplyPanel widget - compact panel for replying to a message."""

from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.widgets import Button, Input, Static

from .debug import _dbg


class ReplyPanel(Vertical):
    """Compact reply panel with message context and input."""

    DEFAULT_CSS = """
    ReplyPanel {
        dock: bottom;
        height: auto;
        min-height: 5;
        max-height: 10;
        border: round $primary;
        padding: 0 1;
        background: $surface;
        margin: 0 0 1 0;
    }

    #reply-header-row {
        height: 1;
        padding: 0;
        align: center middle;
    }

    #reply-header {
        color: $primary;
        width: 1fr;
    }

    #reply-close {
        min-width: 6;
        width: auto;
        height: 1;
        padding: 0 1;
        border: none;
        background: transparent;
    }

    #reply-context {
        height: auto;
        max-height: 3;
        overflow: hidden;
        color: $text-muted;
        margin-bottom: 1;
    }

    #reply-input {
        dock: bottom;
        height: 3;
    }
    """

    class Closed(Message):
        """Emitted when the reply panel is closed."""
        pass

    class ReplySent(Message):
        """Emitted when a reply is submitted."""
        def __init__(self, text: str, reply_to_msgid: str, target: str) -> None:
            self.text = text
            self.reply_to_msgid = reply_to_msgid
            self.target = target
            super().__init__()

    def __init__(self, reply_to_msgid: str, context: str, target: str, sender: str = "", **kwargs) -> None:
        """Create reply panel.
        
        Args:
            reply_to_msgid: The message ID being replied to
            context: The text of the message being replied to (for context display)
            target: The channel/buffer to send the reply to
            sender: The sender of the original message (for context display)
        """
        super().__init__(**kwargs)
        self.reply_to_msgid = reply_to_msgid
        self._context = context
        self._target = target
        self._sender = sender

    def compose(self):
        """Compose header, context, reply input."""
        with Horizontal(id="reply-header-row"):
            yield Static(f"↩ Reply to {self._sender}" if self._sender else "↩ Reply", id="reply-header")
            yield Button("✕", id="reply-close")
        yield Static(self._context[:100] + ("..." if len(self._context) > 100 else ""), id="reply-context")
        yield Input(placeholder="Type your reply...", id="reply-input")

    def on_mount(self) -> None:
        """Focus the input."""
        self.query_one("#reply-input", Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle close button."""
        if event.button.id == "reply-close":
            self._close()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle reply submission."""
        text = event.value.strip()
        if text:
            self.post_message(self.ReplySent(text, self.reply_to_msgid, self._target))
        self._close()

    def _close(self) -> None:
        """Close the panel."""
        self.post_message(self.Closed())
        self.remove()