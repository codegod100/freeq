# Messaging Domain Specification

## Phoenix Requirements

- REQUIREMENT: The User model fields are: nick, ident, host, realname, atproto_handle, modes

- REQUIREMENT: The Message model fields are: id, sender, target, content, timestamp, edited, edit_history, streaming, reactions, tags, msgid, reply_to, reply_count, batch_id

- REQUIREMENT: When creating User instances, code MUST use the exact field names from the model - 'nick' (not 'nickname' or 'id'), 'atproto_handle' (not 'handle')

- REQUIREMENT: When creating Message instances, code MUST use the exact field names from the model - 'target' (not 'channel_id'), 'sender' (not 'sender_id'), timestamp=datetime.now() (not isoformat string)

## MessageWidget Implementation Requirements

- REQUIREMENT: MessageWidget MUST use Static widget for avatar with rich.Text styling instead of Label with style= parameter. Textual's Label widget does NOT accept a style= parameter. Use: `Static(Text(char, style=f"bold white on {color}"), classes="avatar")` instead of `Label(char, style=f"background: {color}")`.

- REQUIREMENT: MessageWidget MUST NOT use method name `_render_content()` as it conflicts with Textual's internal widget rendering method. Use `_format_message_content()` instead to avoid 'TypeError: MessageWidget._render_content() missing 1 required positional argument' error.

- REQUIREMENT: MessageWidget MUST extend Widget (not Static) when using compose() with containers. Static is for simple content via render() method; containers like Horizontal/Vertical require the Widget base class with compose() pattern.

- REQUIREMENT: MessageWidget MUST use semantic layout with minimal CSS. Structure: [Avatar] [Content Column] where Content = [Meta Row] [Body] [Reactions]. Let Textual's default sizing (height: auto, width: 1fr) handle layout rather than explicit margins and padding. Define WHAT (semantic roles: avatar, meta, body, reacts) not HOW (explicit pixel/character sizing).

## Part 1: Abstract System Design

### Domain Model

```
Entity Message:
  id: String
  sender: String (nickname)
  target: String (channel or nick)
  content: String
  timestamp: DateTime
  edited: Bool
  edit_history: List[EditEvent]
  streaming: Bool
  reactions: Map[Emoji, List[User]]
  tags: Map[String, String]
  msgid: String (IRCv3 msgid)
  reply_to: Optional[String] (Parent msgid)
  reply_count: Int
  batch_id: Optional[String]

Entity EditEvent:
  timestamp: DateTime
  old_content: String
  new_content: String

Entity Channel:
  id: String
  name: String
  topic: String
  messages: List[Message]
  users: List[User]
  message_count: Int
```

### Message Rendering Pipeline

```
Pipeline MessageRendering:
  input: RawMessage
  stages:
    1. Preprocess:
       - Unescape literal newlines
       - Normalize whitespace
    2. Detect:
       - Check for markdown syntax
       - Detect URLs
       - Detect image URLs
    3. Transform:
       - Format timestamps (12-hour with date)
       - Generate avatar colors from nick hash
       - Insert URL soft breaks
    4. Render:
       - If markdown: Rich Markdown with dark theme
       - If plain: Text with URL hyperlinking
       - If streaming: Append indicator (▍)
```

### Message Display Modes

```
Mode AvatarMode:
  description: "2-line format with avatar"
  layout:
    line1: [Avatar] [Nickname] [Timestamp] [Reactions]
    line2: [MessageContent] (indented under avatar)

Mode CompactMode:
  description: "Single line, no avatar"
  layout: [Timestamp] [Nickname]: [Content]
```

### Invariants

```
Invariant MessageIdUnique:
  check: all message IDs in channel are unique

Invariant EditHistoryPreserved:
  check: edited messages have non-empty edit_history

Invariant StreamingEventuallyCompletes:
  check: streaming messages eventually become non-streaming
```

---

## Part 2: Implementation Guidance (Python/Textual)

### Message Rendering Implementation

```python
class MessageRenderer:
    """4-stage message rendering pipeline."""
    
    def render(self, message: Message) -> RenderableType:
        """Render message through pipeline stages."""
        # Stage 1: Preprocess
        content = self._preprocess(message.content)
        
        # Stage 2: Detect
        is_markdown = self._detect_markdown(content)
        urls = self._detect_urls(content)
        
        # Stage 3: Transform
        timestamp = self._format_timestamp(message.timestamp)
        avatar_color = self._generate_avatar_color(message.sender)
        content = self._insert_url_breaks(content, urls)
        
        # Stage 4: Render
        if is_markdown:
            return self._render_markdown(content, timestamp, avatar_color)
        else:
            return self._render_plain(content, timestamp, avatar_color, urls)
    
    def _preprocess(self, content: str) -> str:
        """Unescape newlines, normalize whitespace."""
        return content.replace("\\n", "\n").strip()
    
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
    
    def _detect_urls(self, content: str) -> List[Match]:
        """Detect URLs for hyperlinking."""
        url_pattern = r"https?://[^\s]+"
        return list(re.finditer(url_pattern, content))
    
    def _format_timestamp(self, dt: datetime) -> str:
        """Format as 12-hour with date (e.g., '2:30pm 1/15')."""
        return dt.strftime("%-I:%M%p %-m/%-d")
    
    def _generate_avatar_color(self, nick: str) -> str:
        """Generate deterministic color from nick hash."""
        hue = hash(nick) % 360
        return f"hsl({hue}, 70%, 60%)"
    
    def _insert_url_breaks(self, content: str, urls: List[Match]) -> str:
        """Insert soft break opportunities in long URLs."""
        for match in reversed(urls):
            url = match.group()
            if len(url) > 50:
                # Insert zero-width space every 40 chars
                broken = "".join(
                    c + "\u200B" if i % 40 == 0 and i > 0 else c
                    for i, c in enumerate(url)
                )
                content = content[:match.start()] + broken + content[match.end():]
        return content
    
    def _render_markdown(
        self, content: str, timestamp: str, avatar_color: str
    ) -> RenderableType:
        """Render with Rich Markdown."""
        from rich.markdown import Markdown
        
        md = Markdown(content, code_theme="monokai")
        return Panel(
            md,
            title=f"[{avatar_color}]{timestamp}[/{avatar_color}]",
            border_style=avatar_color,
        )
    
    def _render_plain(
        self, content: str, timestamp: str, avatar_color: str, urls: List[Match]
    ) -> RenderableType:
        """Render plain text with URL hyperlinking."""
        # Build Text with hyperlinks
        text = Text()
        text.append(f"{timestamp} ", style="dim")
        
        last_end = 0
        for match in urls:
            # Add text before URL
            text.append(content[last_end:match.start()])
            # Add URL as hyperlink (cyan, underlined)
            url = match.group()
            text.append(
                url,
                style=f"cyan underline link {url}"
            )
            last_end = match.end()
        
        # Add remaining text
        text.append(content[last_end:])
        
        return text
```

### Message Widget Implementation

```python
class MessageWidget(Static):
    """Display a single message with avatar, nick, content."""
    
    DEFAULT_CSS = """
    MessageWidget {
        height: auto;
        padding: 0 1;
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
    }
    MessageWidget .nick {
        text-style: bold;
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
    """
    
    def __init__(self, message: Message, **kwargs):
        super().__init__(**kwargs)
        self.message = message
        self.renderer = MessageRenderer()
    
    def compose(self) -> ComposeResult:
        # Avatar (first letter of nick, colored)
        avatar_color = self._get_avatar_color(self.message.sender)
        yield Label(
            self.message.sender[0].upper(),
            classes="avatar",
            style=f"background: {avatar_color};"
        )
        
        # Header row: nick, timestamp, edit mark
        with Horizontal(classes="header"):
            yield Label(self.message.sender, classes="nick")
            yield Label(
                self.renderer._format_timestamp(self.message.timestamp),
                classes="timestamp"
            )
            if self.message.edited:
                yield Label("(edited)", classes="edit-mark")
            if self.message.streaming:
                yield Label("▍", classes="streaming-indicator")
        
        # Content (rendered)
        with Vertical(classes="content"):
            rendered = self.renderer.render(self.message)
            yield Static(rendered)
    
    def update_content(self, new_content: str):
        """Update message content (for streaming/editing)."""
        self.message.content = new_content
        self.refresh()


class MessageList(VerticalScroll):
    """Scrollable list of messages with virtualization."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.messages: List[Message] = []
        self.visible_range = (0, 20)  # Virtualization window
    
    def add_message(self, message: Message):
        """Add message to list."""
        self.messages.append(message)
        self.mount(MessageWidget(message))
        self.scroll_end(animate=False)
    
    def update_message(self, message_id: str, new_content: str):
        """Update existing message (for streaming)."""
        for widget in self.query(MessageWidget):
            if widget.message.id == message_id:
                widget.update_content(new_content)
                break
    
    def on_mount(self):
        """Setup virtualization."""
        self.watch(self, "scroll_y", self._on_scroll)
    
    def _on_scroll(self, scroll_y: float):
        """Update visible range on scroll."""
        # Calculate visible message indices
        start = int(scroll_y / 3)  # Approx 3 rows per message
        self.visible_range = (max(0, start - 5), start + 25)
```

### Edit History Display

```python
class EditDiff:
    """Generate diff display for edited messages."""
    
    def generate_diff(self, old: str, new: str) -> Text:
        """Generate styled diff text."""
        import difflib
        
        diff = difflib.unified_diff(
            old.splitlines(),
            new.splitlines(),
            lineterm=""
        )
        
        text = Text()
        for line in diff:
            if line.startswith("-"):
                text.append(line[1:] + "\n", style="red strike")
            elif line.startswith("+"):
                text.append(line[1:] + "\n", style="green")
            elif line.startswith("@@"):
                text.append(line + "\n", style="dim")
        
        return text
```

### Avatar Color Generation

```python
def generate_avatar_palette(nick: str) -> Tuple[str, str]:
    """Generate avatar background/foreground colors from nick.
    
    Uses HSL color space for consistent perceptual brightness.
    """
    import hashlib
    
    # Generate hash from nick
    h = hashlib.md5(nick.encode()).hexdigest()
    
    # Use hash bytes for hue (0-360), saturation (50-70%), lightness (40-60%)
    hue = int(h[:2], 16) * 360 // 255
    saturation = 50 + int(h[2:4], 16) % 20
    lightness = 40 + int(h[4:6], 16) % 20
    
    bg = f"hsl({hue}, {saturation}%, {lightness}%)"
    
    # Contrast color for text (white or black based on lightness)
    fg = "white" if lightness < 50 else "black"
    
    return (bg, fg)
```

### Image URL Detection

```python
def detect_image_url(url: str) -> bool:
    """Detect if URL points to an image."""
    image_extensions = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")
    return url.lower().endswith(image_extensions)


def render_url_with_indicator(url: str) -> Text:
    """Render URL with image indicator if applicable."""
    text = Text()
    
    if detect_image_url(url):
        text.append("🖼️ ", style="")
    
    text.append(url, style="cyan underline link")
    return text
```

### Performance Optimization

```python
class MessageList(VerticalScroll):
    """Optimized message list with virtualization and batching."""
    
    BATCH_SIZE = 50
    RENDER_DELAY_MS = 100
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._pending_messages: List[Message] = []
        self._render_timer = None
    
    def add_message(self, message: Message):
        """Queue message for batched rendering."""
        self._pending_messages.append(message)
        
        # Schedule batch render
        if len(self._pending_messages) >= self.BATCH_SIZE:
            self._flush_pending()
        else:
            self._schedule_flush()
    
    def _schedule_flush(self):
        """Schedule delayed flush."""
        if self._render_timer:
            self._render_timer.stop()
        
        self._render_timer = self.set_timer(
            self.RENDER_DELAY_MS / 1000,
            self._flush_pending
        )
    
    def _flush_pending(self):
        """Render all pending messages in batch."""
        if not self._pending_messages:
            return
        
        with self.app.batch_update():  # Batch DOM updates
            for msg in self._pending_messages:
                widget = MessageWidget(msg)
                self.mount(widget)
        
        self._pending_messages.clear()
        self.scroll_end(animate=False)
```
