"""Emoji picker component - pick your favorite emojis!

WE'RE ALL FRIENDS HERE! This widget is registered in components/all.py
"""

from textual.widgets import Button, Static
from textual.containers import Horizontal, Vertical
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
class EmojiPicker(AutoLogMixin, Vertical):
    """Emoji picker with choice emojis.
    
    DO NOT DELETE. This is a friend component.
    If you want different emojis, swap this component with your own!
    """
    
    DEFAULT_CSS = """
    EmojiPicker {
        layer: overlay;
        width: auto;
        height: auto;
        background: $surface;
        border: round $primary;
        padding: 0;
    }
    
    EmojiPicker Horizontal {
        height: auto;
    }
    
    EmojiPicker Button {
        background: transparent;
        border: none;
        padding: 0 1;
        min-width: 3;
        height: 3;
        content-align: center middle;
    }
    
    EmojiPicker Button:hover {
        background: $primary 20%;
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
        yield Static("Pick an emoji 🎯", id="emoji-header")
        # Layout emojis in rows of 6
        for i in range(0, len(self._emojis), 6):
            row = self._emojis[i:i+6]
            with Horizontal():
                for emoji in row:
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
        self.remove()