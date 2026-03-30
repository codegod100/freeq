"""Context menu for right-click actions."""

from textual.widgets import Static, Button
from textual.containers import Vertical
from textual.message import Message
from typing import Optional, Callable


class ContextMenu(Vertical):
    """A simple context menu that appears at cursor position.
    
    USAGE:
        menu = ContextMenu(actions=[
            ("Reply", callback_reply),
            ("React", callback_react),
        ])
        menu.position = (x, y)
        self.mount(menu)
    """
    
    DEFAULT_CSS = """
    ContextMenu {
        position: absolute;
        layer: overlay;
        background: $surface;
        border: round $primary;
        padding: 0;
        margin: 0;
        width: auto;
        height: auto;
    }
    
    ContextMenu Button {
        background: transparent;
        border: none;
        padding: 0 2;
        height: auto;
    }
    
    ContextMenu Button:hover {
        background: $primary 20%;
    }
    
    ContextMenu Button:focus {
        background: $primary 40%;
    }
    """
    
    class Action(Message):
        """Emitted when a menu item is selected."""
        def __init__(self, action: str, msgid: str | None) -> None:
            self.action = action
            self.msgid = msgid
            super().__init__()
    
    def __init__(
        self,
        actions: list[tuple[str, Callable]],
        msgid: str | None = None,
        id: str | None = None,
    ) -> None:
        """Create context menu.
        
        Args:
            actions: List of (label, callback) tuples
            msgid: The message ID this menu applies to
        """
        super().__init__(id=id)
        self._actions = actions
        self._msgid = msgid
        self._buttons: list[Button] = []
    
    def compose(self):
        """Create buttons for each action."""
        for label, callback in self._actions:
            btn = Button(label, id=f"menu-{label.lower()}")
            btn._callback = callback  # type: ignore
            self._buttons.append(btn)
            yield btn
    
    def on_mount(self) -> None:
        """Focus first button."""
        if self._buttons:
            self._buttons[0].focus()
    
    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Handle button press - call callback and close menu."""
        with open('/tmp/freeq-click.log', 'a') as f:
            f.write(f'ContextMenu button pressed: {event.button.label}\n')
        callback = getattr(event.button, '_callback', None)
        if callback:
            callback(self._msgid)
        self.remove()
    
    def on_click(self, event) -> None:
        """Close menu when clicking outside."""
        # Let button presses through, but close on any other click
        pass