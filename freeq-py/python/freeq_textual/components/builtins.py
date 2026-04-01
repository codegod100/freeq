"""Built-in component implementations.

WARNING: DO NOT DELETE THIS FILE.
These are the default implementations. If something looks broken, create a NEW
implementation and register it via ComponentRegistry.register('name').

DO NOT just delete these because they look like ass. Fix them or replace them.
"""

from typing import Callable, Optional

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

# NOTE: _context is RESERVED by Textual! Use _reply_context or similar.
# TypeError: 'str' object is not callable happens if you override it.

# DESIGN PRINCIPLE: Components manage their OWN state!
# BAD: Global state like app._reply_to_msgid - gets stale, causes bugs
# GOOD: Component has reply_to_msgid, emits ReplySent with ALL needed data
#
# WHY GLOBAL STATE IS BAD:
# - Gets out of sync when component unmounts
# - Multiple instances fight over same variable
# - Hard to debug - who set it? when? where?
# - Component can't be reused independently
#
# FRIENDS DON'T LET FRIENDS USE GLOBAL STATE!

@ComponentRegistry.register('reply_panel')
class ReplyPanel(AutoLogMixin, Vertical):
    """Reply panel for composing replies to messages.
    
    Designed to fit in a SidePanelSlot (not floating overlay).
    Slot-based architecture - mounts into typed slot container.
    
    DO NOT DELETE. This is the default implementation.
    If it looks broken, create a replacement and register it.
    """
    
    DEFAULT_CSS = """
    ReplyPanel {
        width: 1fr;
        height: 1fr;
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
        def __init__(self, text: str, reply_to_msgid: str, target: str, is_edit: bool = False) -> None:
            self.text = text
            self.reply_to_msgid = reply_to_msgid
            self.target = target
            self.is_edit = is_edit
            super().__init__()

    def __init__(
        self, 
        reply_to_msgid: str, 
        context: str, 
        target: str, 
        sender: str = "",
        is_edit: bool = False,
        **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self.reply_to_msgid = reply_to_msgid
        self._reply_context = context  # NOT _context (reserved by Textual!)
        self._target = target
        self._sender = sender
        self._is_edit = is_edit

    def compose(self):
        with Horizontal(id="reply-header-row"):
            header_text = "✎ Edit" if self._is_edit else (f"↩ {self._sender}" if self._sender else "↩ Reply")
            yield Static(header_text, id="reply-header")
            yield Button("✕", id="reply-close")
        yield Static(self._reply_context[:80], id="reply-context")
        placeholder = "Edit message..." if self._is_edit else "Reply..."
        value = self._reply_context if self._is_edit else ""
        yield Input(placeholder=placeholder, id="reply-input", value=value)

    def on_mount(self) -> None:
        super().on_mount()  # AutoLogMixin logs mount
        inp = self.query_one("#reply-input", Input)
        inp.focus()
        # For edit mode: move cursor to end instead of selecting all
        if self._is_edit:
            inp.cursor_position = len(inp.value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        if event.button.id == "reply-close":
            self.remove()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        super().on_input_submitted(event)  # AutoLogMixin logs input
        text = event.value.strip()
        if text:
            action = "Edit" if self._is_edit else "Reply"
            self._log(f"posting {action}Sent(msgid={self.reply_to_msgid[:8]}, target={self._target})")
            self.post_message(self.ReplySent(text, self.reply_to_msgid, self._target, self._is_edit))
        self.remove()


# ─────────────────────────────────────────────────────────────────────────────
# CONTEXT MENU - Default implementation  
# ─────────────────────────────────────────────────────────────────────────────

@ComponentRegistry.register('context_menu')
class ContextMenu(AutoLogMixin, Horizontal):
    """Context menu for message actions - thin action bar.
    
    Designed to fit perfectly in a Slot below a message.
    Thin, compact, readable.
    
    Slot-based architecture:
    - Mounts into a Slot below the message
    - Calls on_close callback when done (to clear slot)
    - Such modular. Much reactive. Very thin.
    """
    
    DEFAULT_CSS = """
    ContextMenu {
        width: 1fr;
        height: auto;
        background: $surface-darken-1;
        border: none;
        padding: 0 1;
        align: left middle;
    }
    
    ContextMenu Button {
        background: transparent;
        border: none;
        content-align: center middle;
        padding: 0 2;
        height: auto;
        min-width: 10;
        width: auto;
        color: $text;
        text-style: bold;
    }
    
    ContextMenu Button:hover {
        background: $primary;
        color: $text;
        text-style: bold;
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
        on_close: Optional[Callable] = None,
    ) -> None:
        super().__init__()
        self._actions = actions
        self._msgid = msgid
        self._on_close = on_close

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

    def _close(self) -> None:
        """Close the menu and clear parent slot if callback provided."""
        # Call on_close callback to clear parent slot
        if self._on_close:
            self._on_close()
        self.remove()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        callback = getattr(event.button, '_callback', None)
        if callback:
            callback(self._msgid)
        self._close()

    def on_key(self, event) -> None:
        """Handle ESC key to close menu."""
        if hasattr(event, 'key') and event.key == 'escape':
            self._close()


# ─────────────────────────────────────────────────────────────────────────────
# USER LIST - Default implementation  
# ─────────────────────────────────────────────────────────────────────────────

@ComponentRegistry.register('user_list')
class UserList(AutoLogMixin, Vertical):
    """User list panel showing channel members.
    
    DO NOT DELETE. This is the default implementation.
    If it looks broken, create a replacement and register it.
    """
    
    DEFAULT_CSS = """
    UserList {
        width: 25;
        min-width: 25;
        max-width: 35;
        height: 1fr;
        border: solid $panel-lighten-2;
        background: $surface;
    }
    
    UserList Static {
        color: $text;
        padding: 0 1;
    }
    
    UserList .user-list-header {
        color: $primary;
        text-align: center;
        padding: 1;
        border-bottom: solid $panel-lighten-2;
    }
    """

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._members: set[str] = set()
        self._ops: set[str] = set()
        self._voice: set[str] = set()
        self._channel: str = ""

    def compose(self):
        yield Static("Users", classes="user-list-header")
        yield Static("", id="user-list-content")

    def update_users(self, channel: str, members: set[str], ops: set[str] = None, voice: set[str] = None) -> None:
        """Update the user list for a channel."""
        self._channel = channel
        self._members = members
        self._ops = ops or set()
        self._voice = voice or set()
        self._refresh_display()

    def _refresh_display(self) -> None:
        """Refresh the user list display."""
        # Guard: Don't run before mount. No try/except - hard fail for real bugs.
        if not self.is_mounted:
            return
        
        content = self.query_one("#user-list-content", Static)
        if not self._members:
            content.update("(no users)")
            return
        
        # Sort users: ops first, then voice, then regular, each alphabetically
        def sort_key(nick):
            nick_key = nick.lstrip("@+").lower()
            is_op = nick_key in self._ops
            is_voice = nick_key in self._voice
            # Sort: ops first (0), then voice (1), then regular (2)
            priority = 0 if is_op else (1 if is_voice else 2)
            return (priority, nick.lower())
        
        sorted_users = sorted(self._members, key=sort_key)
        
        # Format with prefix and color classes
        lines = []
        for nick in sorted_users:
            nick_key = nick.lstrip("@+").lower()
            if nick_key in self._ops:
                lines.append(f"[@] {nick}")  # Operator
            elif nick_key in self._voice:
                lines.append(f"[+] {nick}")  # Voice
            else:
                lines.append(f"    {nick}")  # Regular (4 spaces to align)
        
        content.update("\n".join(lines))