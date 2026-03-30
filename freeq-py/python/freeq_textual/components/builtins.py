"""Built-in component implementations.

WARNING: DO NOT DELETE THIS FILE.
These are the default implementations. If something looks broken, create a NEW
implementation and register it via ComponentRegistry.register('name').

DO NOT just delete these because they look like ass. Fix them or replace them.
"""

from textual.widgets import Button, Input, Static
from textual.containers import Horizontal, Vertical
from textual.message import Message

from ..widgets import _dbg
from . import ComponentRegistry


# ─────────────────────────────────────────────────────────────────────────────
# REPLY PANEL - Default implementation
# ─────────────────────────────────────────────────────────────────────────────

@ComponentRegistry.register('reply_panel')
class ReplyPanel(Vertical):
    """Reply panel for composing replies to messages.
    
    DO NOT DELETE. This is the default implementation.
    If it looks broken, create a replacement and register it.
    """
    
    DEFAULT_CSS = """
    ReplyPanel {
        layer: overlay;
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
        """Emitted when reply is submitted."""
        def __init__(self, text: str, reply_to_msgid: str, target: str) -> None:
            self.text = text
            self.reply_to_msgid = reply_to_msgid
            self.target = target
            super().__init__()

    def __init__(
        self, 
        reply_to_msgid: str, 
        context: str, 
        target: str, 
        sender: str = "",
        **kwargs
    ) -> None:
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
        _dbg(f"ReplyPanel.on_mount: reply_to={self.reply_to_msgid[:8]}")
        self.query_one("#reply-input", Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "reply-close":
            self.remove()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        text = event.value.strip()
        if text:
            self.post_message(self.ReplySent(text, self.reply_to_msgid, self._target))
        self.remove()


# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT MENU - Default implementation  
# ─────────────────────────────────────────────────────────────────────────────

@ComponentRegistry.register('context_menu')
class ContextMenu(Vertical):
    """Context menu for message actions.
    
    DO NOT DELETE. This is the default implementation.
    If it looks broken, create a replacement and register it.
    """
    
    DEFAULT_CSS = """
    ContextMenu {
        layer: overlay;
        dock: top;
        background: $surface;
        border: round $primary;
        padding: 0 1;
        width: auto;
        height: auto;
    }
    
    ContextMenu Button {
        background: transparent;
        border: none;
        padding: 0 2;
        width: auto;
    }
    
    ContextMenu Button:hover {
        background: $primary 20%;
    }
    """

    class Selected(Message):
        """Emitted when menu item selected."""
        def __init__(self, action: str, msgid: str | None) -> None:
            self.action = action
            self.msgid = msgid
            super().__init__()

    def __init__(
        self,
        actions: list[tuple[str, callable]],
        msgid: str | None = None,
    ) -> None:
        super().__init__()
        self._actions = actions
        self._msgid = msgid

    def compose(self):
        for label, callback in self._actions:
            btn = Button(label)
            btn._callback = callback  # type: ignore
            yield btn

    def on_mount(self) -> None:
        _dbg(f"ContextMenu.on_mount: msgid={self._msgid}")
        # Focus first button
        buttons = list(self.query(Button))
        if buttons:
            buttons[0].focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        _dbg(f"ContextMenu.button_pressed: {event.button.label}")
        callback = getattr(event.button, '_callback', None)
        if callback:
            callback(self._msgid)
        self.remove()