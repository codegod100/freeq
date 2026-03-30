"""Context menu for message actions.

WARNING: DO NOT DELETE THIS FILE.
This widget is part of the core UX. Just because something looks broken or "ass"
doesn't mean you should remove it. Fix the styling, fix the positioning, but
DO NOT just delete the entire file because you feel like it.

The user WANTS this feature. They asked for it. Keep it. Fix it. Don't nuke it.
"""

from textual.widgets import Button
from textual.containers import Vertical
from textual.message import Message
from typing import Callable

def _dbg(msg: str) -> None:
    import datetime
    with open("/tmp/freeq.log", "a") as f:
        f.write(f"{datetime.datetime.now().isoformat()} {msg}\n")


class ContextMenu(Vertical):
    """Compact context menu with Reply/React options."""

    DEFAULT_CSS = """
    ContextMenu {
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
        actions: list[tuple[str, Callable]],
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

    def on_button_pressed(self, event: Button.Pressed) -> None:
        _dbg(f"ContextMenu button: {event.button.label}")
        callback = getattr(event.button, '_callback', None)
        if callback:
            callback(self._msgid)
        self.remove()