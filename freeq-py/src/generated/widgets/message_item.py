# @phoenix-canon: IU-c40ae8a5 - Definitions Domain
"""Message item widget for FreeQ TUI."""

from textual.widget import Widget
from textual.widgets import Static, Label
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.message import Message
from rich.text import Text
from rich.panel import Panel
from rich.markdown import Markdown
from datetime import datetime
import hashlib
import re
from typing import List, Match, Any

from ..models import Message


# @phoenix-canon: node-c385163a
class MessageWidget(Static):
    """Display a single message with avatar, nick, content.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    MessageWidget {
        height: auto;
        padding: 0 1;
        background: $surface;
        border: solid $primary;
    }
    MessageWidget:hover {
        background: $surface-darken-1;
    }
    MessageWidget .avatar {
        width: 2;
        height: 1;
        background: $primary;
        color: $text;
        content-align: center middle;
        text-style: bold;
    }
    MessageWidget .nick {
        text-style: bold;
        color: $text-accent;
    }
    MessageWidget .timestamp {
        color: $text-muted;
        text-style: dim;
    }
    MessageWidget .streaming-indicator {
        color: $success;
        text-style: blink;
    }
    MessageWidget .edit-mark {
        color: $warning;
        text-style: italic;
    }
    MessageWidget .content {
        margin-left: 3;
    }
    MessageWidget .reaction-bar {
        height: 1;
        margin-top: 1;
        margin-left: 3;
    }
    MessageWidget .reply-indicator {
        color: $primary;
        text-style: italic;
    }
    """
    
    message = reactive(None)
    indent = reactive(0)
    highlight = reactive(False)
    
    def __init__(
        self,
        message: Message = None,
        indent: int = 0,
        highlight: bool = False,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize message widget.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.message = message or Message()
        self.indent = indent
        self.highlight = highlight
    
    def compose(self):
        """Compose message widget."""
        import logging
        logger = logging.getLogger(__name__)
        logger.info(f"[MESSAGE_WIDGET] Composing message from {self.message.sender}: {self.message.content[:30]}...")
        
        # Avatar (first letter of nick, colored)
        avatar_color = self._get_avatar_color(self.message.sender)
        
        # Main layout with avatar and content
        with Horizontal():
            # Use Static with styled text instead of Label (Label doesn't accept style=)
            from rich.text import Text
            avatar_text = Text(
                self.message.sender[0].upper() if self.message.sender else "?",
                style=f"bold white on {avatar_color}"
            )
            yield Static(avatar_text, classes="avatar")
            
            with Vertical(classes="content"):
                # Header row: nick, timestamp, edit mark
                with Horizontal(classes="header"):
                    yield Label(self.message.sender, classes="nick")
                    yield Label(
                        self._format_timestamp(self.message.timestamp),
                        classes="timestamp"
                    )
                    if self.message.edited:
                        yield Label("(edited)", classes="edit-mark")
                    if self.message.streaming:
                        yield Label("▍", classes="streaming-indicator")
                
                # Reply indicator if replying
                if self.message.reply_to:
                    yield Label(
                        f"↳ replying to {self.message.reply_to}",
                        classes="reply-indicator"
                    )
                
                # Content (rendered)
                rendered = self._format_message_content(self.message.content)
                yield Static(rendered)
                
                # Reactions bar
                if self.message.reactions:
                    with Horizontal(classes="reaction-bar"):
                        for emoji, senders in self.message.reactions.items():
                            count = len(senders)
                            if count > 1:
                                yield Label(f"{emoji} {count}")
                            else:
                                yield Label(emoji)
    
    def render(self):
        """Render method for debugging - ensures widget has content."""
        import logging
        logger = logging.getLogger(__name__)
        logger.debug(f"[MESSAGE_WIDGET] Rendering {self.message.sender}: {self.message.content[:20]}...")
        return super().render()
    
    def _get_avatar_color(self, nick: str) -> str:
        """Generate deterministic color from nick hash."""
        hue = hash(nick) % 360
        return f"hsl({hue}, 70%, 60%)"
    
    def _format_timestamp(self, dt: datetime) -> str:
        """Format as 12-hour with date (e.g., '2:30pm 1/15')."""
        return dt.strftime("%-I:%M%p %-m/%-d")
    
    def _format_message_content(self, content: str) -> Any:
        """Render message content with formatting."""
        # Preprocess
        content = content.replace("\\n", "\n").strip()
        
        # Detect markdown
        is_markdown = self._detect_markdown(content)
        
        if is_markdown:
            return Markdown(content, code_theme="monokai")
        else:
            # Plain text with URL hyperlinking
            return self._render_plain_with_urls(content)
    
    def _detect_markdown(self, content: str) -> bool:
        """Detect markdown via pattern matching."""
        patterns = [
            r"\*\*.*?\*\*",  # Bold
            r"\*.*?\*",      # Italic
            r"`.*?`",         # Code
            r"\[.*?\]\(.*?\)", # Links
            r"^#+ ",         # Headers
        ]
        return any(re.search(p, content) for p in patterns)
    
    def _render_plain_with_urls(self, content: str) -> Text:
        """Render plain text with URL hyperlinking."""
        text = Text()
        
        # Detect URLs
        url_pattern = r"https?://[^\s]+"
        urls = list(re.finditer(url_pattern, content))
        
        last_end = 0
        for match in urls:
            # Add text before URL
            text.append(content[last_end:match.start()])
            
            # Add URL as hyperlink
            url = match.group()
            # Insert soft breaks in long URLs
            if len(url) > 50:
                url = self._insert_url_breaks(url)
            
            text.append(url, style=f"cyan underline link {url}")
            last_end = match.end()
        
        # Add remaining text
        text.append(content[last_end:])
        
        return text
    
    def _insert_url_breaks(self, url: str) -> str:
        """Insert soft break opportunities in long URLs."""
        return "".join(
            c + "\u200B" if i % 40 == 0 and i > 0 else c
            for i, c in enumerate(url)
        )
    
    def update_content(self, new_content: str):
        """Update message content (for streaming/editing)."""
        self.message.content = new_content
        self.refresh()
    
    def on_click(self):
        """Handle click - emit message selected."""
        self.post_message(MessageWidgetClicked(
            message=self.message,
            is_own=False  # Will be set by parent based on current user
        ))


# @phoenix-canon: node-77eff8b8
class MessageItem(Static):
    """Alternative message item display.
    
    REQUIREMENT: Visibility MUST be controlled by Python widget.visible 
    property, NOT CSS display classes.
    """
    
    DEFAULT_CSS = """
    MessageItem {
        height: auto;
        padding: 0 1;
    }
    """
    
    message = reactive(None)
    
    def __init__(
        self,
        message: Message = None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize message item."""
        super().__init__(id=id, classes=classes, **kwargs)
        self.message = message or Message()
    
    def compose(self):
        """Compose message item."""
        yield MessageWidget(message=self.message)


class MessageWidgetClicked(Message):
    """Message widget click event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, message: Message, is_own: bool = False):
        super().__init__()  # REQUIRED for Textual messages
        self.message = message
        self.is_own = is_own
