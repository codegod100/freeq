"""Built-in component implementations.

WARNING: DO NOT DELETE THIS FILE.
These are the default implementations. If something looks broken, create a NEW
implementation and register it via ComponentRegistry.register('name').

DO NOT just delete these because they look like ass. Fix them or replace them.
"""

from textual.widgets import Button, Input, Static
from textual.containers import Horizontal, Vertical
from textual.message import Message

# Import _dbg directly to avoid circular import with widgets/__init__.py
from ..widgets.debug import _dbg
from . import ComponentRegistry


class AutoLogMixin:
    """Mixin for components that auto-logs interactions.
    
    Use with multiple inheritance:
        class MyPanel(AutoLogMixin, Vertical):
            ...
    
    Auto-logs:
    - mount/unmount
    - button presses
    - input submissions
    - focus events
    """
    
    def _log(self, msg: str) -> None:
        """Log with component class name prefix."""
        _dbg(f"{self.__class__.__name__}: {msg}")
    
    def on_mount(self) -> None:
        self._log(f"mounted (id={self.id})")
    
    def on_unmount(self) -> None:
        self._log(f"unmounted (id={self.id})")
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        self._log(f"button pressed: {event.button.label!r} (id={event.button.id})")
    
    def on_input_submitted(self, event: Input.Submitted) -> None:
        self._log(f"input submitted: {event.value[:50]!r}")
    
    def on_focus(self, event) -> None:
        self._log(f"focus gained")
    
    def on_blur(self, event) -> None:
        self._log(f"focus lost")


# ─────────────────────────────────────────────────────────────────────────────
# REPLY PANEL - Default implementation
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# REPLY PANEL - Default implementation
# ─────────────────────────────────────────────────────────────────────────────

# NOTE: _context is RESERVED by Textual! Use _reply_context or similar.
# TypeError: 'str' object is not callable happens if you override it.

@ComponentRegistry.register('reply_panel')
class ReplyPanel(AutoLogMixin, Vertical):
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
        self._reply_context = context  # NOT _context (reserved by Textual!)
        self._target = target
        self._sender = sender

    def compose(self):
        with Horizontal(id="reply-header-row"):
            yield Static(f"↩ {self._sender}" if self._sender else "↩ Reply", id="reply-header")
            yield Button("✕", id="reply-close")
        yield Static(self._reply_context[:80], id="reply-context")
        yield Input(placeholder="Reply...", id="reply-input")

    def on_mount(self) -> None:
        super().on_mount()  # AutoLogMixin logs mount
        self.query_one("#reply-input", Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        if event.button.id == "reply-close":
            self.remove()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        super().on_input_submitted(event)  # AutoLogMixin logs input
        text = event.value.strip()
        if text:
            self.post_message(self.ReplySent(text, self.reply_to_msgid, self._target))
        self.remove()


# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT MENU - Default implementation  
# ─────────────────────────────────────────────────────────────────────────────

@ComponentRegistry.register('context_menu')
class ContextMenu(AutoLogMixin, Vertical):
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
        super().on_mount()  # AutoLogMixin logs mount
        # Focus first button
        buttons = list(self.query(Button))
        if buttons:
            buttons[0].focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        callback = getattr(event.button, '_callback', None)
        if callback:
            callback(self._msgid)
        self.remove()