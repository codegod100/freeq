"""Emoji picker component - pick your favorite emojis!

WE'RE ALL FRIENDS HERE! This widget is registered in components/all.py
"""

from textual.widgets import Button, Static
from textual.containers import Horizontal
from textual.message import Message

from ..widgets.debug import _dbg
from . import ComponentRegistry
from .builtins import AutoLogMixin


# Choice emojis for the picker - the BEST emojis
CHOICE_EMOJIS = [
    "👍", "👎",  # Thumbs
    "❤️", "🔥",  # Love/Fire
    "😂", "😭",  # Laugh/Cry
    "🎉", "🎊",  # Party
    "👀", "🤔",  # Thinking
    "💀", "☠️",  # Skull
]


@ComponentRegistry.register('emoji_picker')
class EmojiPicker(AutoLogMixin, Horizontal):
    """Emoji picker with choice emojis.
    
    Designed to fit in an InlineActionsSlot (below message).
    Slot-based architecture - no floating overlay.
    
    DO NOT DELETE. This is a friend component.
    If you want different emojis, swap this component with your own!
    """
    
    DEFAULT_CSS = """
    EmojiPicker {
        width: 1fr;
        height: auto;
        background: $surface-darken-1;
        border-top: solid $panel-lighten-2;
        padding: 0 1;
        align: left middle;
    }
    
    EmojiPicker Button {
        background: transparent;
        border: none;
        padding: 0 1;
        min-width: 3;
        width: auto;
        content-align: center middle;
    }
    
    EmojiPicker Button:hover {
        background: $primary 30%;
        text-style: bold;
    }
    
    EmojiPicker Button:focus {
        background: $primary 40%;
    }
    
    #emoji-header {
        display: none;
    }
    """

    class EmojiSelected(Message):
        """Emitted when an emoji is selected."""
        def __init__(self, emoji: str, msgid: str | None) -> None:
            self.emoji = emoji
            self.msgid = msgid
            super().__init__()

    def __init__(
        self,
        msgid: str | None = None,
        emojis: list[str] | None = None,
        **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._msgid = msgid
        self._emojis = emojis or CHOICE_EMOJIS

    def compose(self):
        # Single horizontal row of emojis
        for emoji in self._emojis:
            btn = Button(emoji, classes="emoji-btn")
            btn._emoji = emoji  # type: ignore
            yield btn

    def on_mount(self) -> None:
        super().on_mount()  # AutoLogMixin logs mount
        # Focus first emoji button
        buttons = list(self.query(".emoji-btn"))
        if buttons:
            buttons[0].focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        emoji = getattr(event.button, '_emoji', None)
        if emoji:
            self._log(f"selected {emoji}")
            self.post_message(self.EmojiSelected(emoji, self._msgid))
        # Call on_close if provided (slot callback)
        if hasattr(self, '_on_close') and self._on_close:
            self._on_close()
        self.remove()
