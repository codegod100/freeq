# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Emoji picker widget for FreeQ TUI."""

from textual.screen import ModalScreen
from textual.containers import Grid, Vertical
from textual.widgets import Static, Label, Button
from textual.reactive import reactive
from textual.message import Message
from textual import on


# @phoenix-canon: node-c385163a
class EmojiPicker(ModalScreen):
    """Modal emoji picker for adding reactions.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    EmojiPicker {
        align: center middle;
        background: $surface-darken-2 80%;
    }
    EmojiPicker .container {
        width: 44;
        height: 14;
        border: thick $primary;
        background: $surface;
        padding: 1;
    }
    EmojiPicker .title {
        text-align: center;
        text-style: bold;
        height: 1;
        margin-bottom: 1;
    }
    EmojiPicker .emoji-grid {
        grid-size: 6 2;
        grid-gutter: 1;
        width: 100%;
        height: auto;
    }
    EmojiPicker .emoji-btn {
        width: auto;
        height: 3;
        content-align: center middle;
        text-style: bold;
    }
    EmojiPicker .close-btn {
        width: 100%;
        margin-top: 1;
    }
    """
    
    # Common reaction emojis
    EMOJI_GRID = [
        "👍", "❤️", "😂", "😮", "😢", "🎉",
        "🔥", "👏", "🤔", "👀", "✅", "❌",
    ]
    
    target_msgid = reactive("")
    
    def __init__(
        self,
        target_msgid: str = "",
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize emoji picker.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.target_msgid = target_msgid
    
    def compose(self):
        """Compose emoji picker."""
        with Vertical(classes="container"):
            yield Label("Select reaction:", classes="title")
            
            with Grid(classes="emoji-grid"):
                for i, emoji in enumerate(self.EMOJI_GRID):
                    yield Button(emoji, id=f"emoji-{i}", classes="emoji-btn")
            
            yield Button("Cancel", id="close-btn", variant="error")
    
    @on(Button.Pressed, "#close-btn")
    def on_close(self):
        """Close emoji picker."""
        self.dismiss()
    
    @on(Button.Pressed, ".emoji-btn")
    def on_emoji_selected(self, event: Button.Pressed):
        """User selected emoji - send reaction."""
        emoji = str(event.button.label)
        
        # Normalize emoji
        emoji = self._normalize_emoji(emoji)
        
        self.post_message(EmojiSelected(
            msgid=self.target_msgid,
            emoji=emoji,
        ))
        self.dismiss()
    
    @classmethod
    def _normalize_emoji(cls, emoji: str) -> str:
        """Ensure emoji presentation by adding VS16 if needed."""
        # Characters that need variation selector for emoji presentation
        VS16_CHARS = frozenset(
            "#*0123456789©®‼⁉ℹ™ℹ↔↕↖↗↘↙↚↛↜↝↞↟↠↡↢↣↤↥↦↧↨↩↪↫↬↭↮↯↰↱↲↳↴↵↶↷↸↹↺↻↼↽↾↿⇀⇁⇂⇃⇄⇅⇆⇇⇈⇉⇊⇋⇌⇍⇎⇏"
        )
        
        if len(emoji) == 1 and emoji in VS16_CHARS:
            if not emoji.endswith("\ufe0f"):
                return emoji + "\ufe0f"
        return emoji
    
    def show(self):
        """Show emoji picker."""
        pass  # ModalScreen handles this


class EmojiSelected(Message):
    """User selected emoji from picker.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, msgid: str, emoji: str):
        super().__init__()  # REQUIRED for Textual messages
        self.msgid = msgid
        self.emoji = emoji


class ReactionWidget(Static):
    """Display a reaction emoji with count.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    ReactionWidget {
        padding: 0 1;
        height: 1;
    }
    ReactionWidget .emoji {
        text-style: bold;
    }
    ReactionWidget .count {
        color: $text-muted;
        text-style: dim;
        margin-left: 1;
    }
    """
    
    emoji = reactive("")
    count = reactive(0)
    
    def __init__(
        self,
        emoji: str = "",
        count: int = 0,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize reaction widget."""
        super().__init__(id=id, classes=classes, **kwargs)
        self.emoji = emoji
        self.count = count
    
    def compose(self):
        """Compose reaction widget."""
        yield Label(self.emoji, classes="emoji")
        if self.count > 1:
            yield Label(str(self.count), classes="count")
    
    def on_click(self):
        """Handle click - toggle reaction."""
        self.post_message(ReactionToggled(emoji=self.emoji))


class ReactionToggled(Message):
    """Reaction toggle event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, emoji: str):
        super().__init__()  # REQUIRED for Textual messages
        self.emoji = emoji
