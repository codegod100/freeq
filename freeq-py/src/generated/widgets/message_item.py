# @phoenix-canon: IU-c40ae8a5 - Definitions Domain
"""Message item widget for FreeQ TUI."""

from textual.widget import Widget
from textual.widgets import Static, Label
from textual.containers import Horizontal
from textual.reactive import reactive
from textual.message import Message as TextualMessage
from rich.text import Text
from rich.markdown import Markdown
from datetime import datetime
import re
from typing import Any

from ..models import Message


# @phoenix-canon: node-c385163a
class MessageWidget(Widget):
    """A chat message - semantic layout, minimal styling.
    
    Structure: [Avatar] [Content Column]
               where Content = [Header Row] [Body] [Reactions]
    """
    
    # Minimal CSS - rely on Textual's defaults for sizing
    DEFAULT_CSS = """
    MessageWidget {
        height: auto;
        layout: horizontal;
        padding: 0 1;
    }
    MessageWidget .avatar {
        width: 2;
        height: 1;
    }
    MessageWidget .content {
        width: 1fr;
        height: auto;
    }
    MessageWidget .meta {
        height: auto;
    }
    MessageWidget .body {
        height: auto;
    }
    MessageWidget .reacts {
        height: auto;
    }
    """
    
    message = reactive(None)
    
    def __init__(self, message: Message = None, **kwargs):
        super().__init__(**kwargs)
        self.message = message or Message()
    
    def compose(self):
        """Semantic structure: Avatar | Content(meta, body, reacts)"""
        # Avatar - colored by sender
        avatar = self.message.sender[0].upper() if self.message.sender else "?"
        color = self._avatar_color(self.message.sender)
        yield Static(
            Text(avatar, style=f"bold white on {color}"),
            classes="avatar"
        )
        
        # Content column
        with Horizontal(classes="content"):
            # Meta: nick + time + edited + streaming
            meta_parts = [self.message.sender, self._format_time(self.message.timestamp)]
            if self.message.edited:
                meta_parts.append("(edited)")
            if self.message.streaming:
                meta_parts.append("▍")
            yield Label(" • ".join(meta_parts), classes="meta")
            
            # Body: message text
            body = self._render_body(self.message.content)
            yield Static(body, classes="body")
            
            # Reactions if any
            if self.message.reactions:
                reacts = " ".join(
                    f"{e} {len(u)}" if len(u) > 1 else e
                    for e, u in self.message.reactions.items()
                )
                yield Static(reacts, classes="reacts")
    
    def _avatar_color(self, nick: str) -> str:
        return f"hsl({hash(nick) % 360}, 70%, 60%)"
    
    def _format_time(self, dt: datetime) -> str:
        return dt.strftime("%-I:%M%p %-m/%-d")
    
    def _render_body(self, content: str) -> Any:
        content = content.replace("\\n", "\n").strip()
        
        # Check for markdown
        md_patterns = [r"\*\*.*?\*\*", r"\*.*?\*", r"`.*?`", r"\[.*?\]\(.*?\)", r"^#+ "]
        is_md = any(re.search(p, content) for p in md_patterns)
        
        if is_md:
            return Markdown(content, code_theme="monokai")
        
        # Plain with URLs
        text = Text()
        urls = list(re.finditer(r"https?://[^\s]+", content))
        last = 0
        for m in urls:
            text.append(content[last:m.start()])
            text.append(content[m.start():m.end()], style="underline blue", link=m.group())
            last = m.end()
        text.append(content[last:])
        return text


# Keep for backward compatibility with __init__.py exports
class MessageItem(MessageWidget):
    """Alternative name for MessageWidget."""
    pass


class MessageWidgetClicked(TextualMessage):
    """Message widget click event."""
    
    def __init__(self, message: Message, is_own: bool = False):
        super().__init__()
        self.message = message
        self.is_own = is_own
