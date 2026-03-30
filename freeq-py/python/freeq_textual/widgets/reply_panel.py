"""Reply panel for composing replies.

WARNING: DO NOT DELETE THIS FILE.
This widget is part of the core UX. The user explicitly asked for a reply panel.
If something is broken, fix it. DO NOT just rm the file because you're frustrated.

The user WANTS this feature. They asked for it. Keep it. Fix it. Don't nuke it.
"""

from textual.containers import Horizontal, Vertical
from textual.message import Message
from textual.widgets import Button, Input, Static


class ReplyPanel(Vertical):
    """Reply panel docked at bottom right, like thread panel on right side."""

    DEFAULT_CSS = """
    ReplyPanel {
        dock: right;
        width: 30%;
        min-width: 24;
        max-width: 50;
        height: auto;
        border: round $primary;
        padding: 0 1;
        background: $surface;
    }

    #reply-header-row {
        height: 1;
    }

    #reply-header {
        color: $primary;
        width: 1fr;
    }

    #reply-close {
        width: auto;
        border: none;
        background: transparent;
    }

    #reply-context {
        color: $text-muted;
        height: auto;
        max-height: 2;
        overflow: hidden;
    }

    #reply-input {
        dock: bottom;
    }
    """

    class ReplySent(Message):
        def __init__(self, text: str, reply_to_msgid: str, target: str) -> None:
            self.text = text
            self.reply_to_msgid = reply_to_msgid
            self.target = target
            super().__init__()

    def __init__(self, reply_to_msgid: str, context: str, target: str, sender: str = "", **kwargs) -> None:
        super().__init__(**kwargs)
        self.reply_to_msgid = reply_to_msgid
        self._context = context
        self._target = target
        self._sender = sender

    def compose(self):
        with Horizontal(id="reply-header-row"):
            yield Static(f"↩ {self._sender}" if self._sender else "↩ Reply", id="reply-header")
            yield Button("✕", id="reply-close")
        yield Static(self._context[:80], id="reply-context")
        yield Input(placeholder="Reply...", id="reply-input")

    def on_mount(self) -> None:
        self.query_one("#reply-input", Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "reply-close":
            self.remove()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        text = event.value.strip()
        if text:
            self.post_message(self.ReplySent(text, self.reply_to_msgid, self._target))
        self.remove()