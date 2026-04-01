"""Emoji picker component - pick your favorite emojis!

WE'RE ALL FRIENDS HERE! This widget is registered in components/all.py
"""

from collections.abc import Callable

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
        /* INVISIBLE CONTAINER: Like ContextMenu, the picker should have no visual presence.
         * It's just a holder for the emoji buttons. All visual styling comes from
         * the buttons themselves (hover states).
         */
        width: 1fr;
        height: auto;
        background: transparent;  /* No box around buttons */
        border: none;             /* No visual separation */
        padding: 0;               /* Tight fit, no extra space */
        align: left middle;
    }
    
    EmojiPicker Button {
        /* MINIMAL BUTTONS: Only show presence on hover.
         * Transparent by default, subtle background on hover.
         * Tight padding (0 1) to keep buttons compact.
         */
        background: transparent;    /* Invisible until hover */
        border: none;
        padding: 0 1;
        min-width: 3;
        width: auto;
        content-align: center middle;
    }
    
    EmojiPicker Button:hover {
        /* HOVER STATE: The only visual feedback. */
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
        on_close: Callable[[], None] | None = None,
        **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._msgid = msgid
        self._emojis = emojis or CHOICE_EMOJIS
        self._on_close = on_close  # Slot callback to clear parent slot

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
        """Handle emoji button press.
        
        HARD FAIL PHILOSOPHY: No try/except here. If emitting the message or
        calling on_close fails, that's a real bug we want to know about.
        Textual's message passing should not fail - if it does, we need to fix
        the underlying issue, not swallow the error.
        """
        super().on_button_pressed(event)  # AutoLogMixin logs button press
        emoji = getattr(event.button, '_emoji', None)
        if emoji:
            self._log(f"selected {emoji}")
            # Emit message - if this fails, let it crash (hard fail philosophy)
            self.post_message(self.EmojiSelected(emoji, self._msgid))
        # Call on_close if provided (slot callback to clear parent slot)
        # No try/except - if callback fails, we want to know
        if self._on_close:
            self._on_close()
        # Remove self from slot - this will trigger slot cleanup via unmount
        self.remove()
