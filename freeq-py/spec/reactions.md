# Reactions Domain Specification

## Part 1: Abstract System Design

### Domain Model

```
Entity Reaction:
  emoji: String (Unicode emoji)
  sender: String (nickname)
  target_msgid: String (IRCv3 msgid of message being reacted to)
  timestamp: DateTime

Entity ReactionGroup:
  emoji: String
  count: Int
  senders: List[String]
  
Entity MessageWithReactions:
  message: Message
  reactions: List[ReactionGroup]
```

### Reaction Protocol

```
Protocol IRCv3Reactions:
  sending:
    method: TAGMSG
    tags:
      +react: "{emoji}"
      +reply: "{target_msgid}"
    content: empty (TAGMSG has no content)
  
  receiving:
    event: TAGMSG
    tags:
      +react: present
      +reply: present
    action: Aggregate into ReactionGroup
```

### Emoji Normalization Rules

```
Rule VariationSelector:
  condition: Emoji codepoint defaults to text presentation
  action: Append U+FE0F (VS16) to force emoji presentation
  avoid: Double-appending if VS16 already present

Rule TextPresentation:
  examples:
    - "❤" + VS16 = "❤️"  (U+2764 U+FE0F)
    - "☺" + VS16 = "☺️"  (U+263A U+FE0F)
```

---

## Part 2: Implementation Guidance (Python/Textual)

### Sending Reactions

```python
class ReactionSender:
    """Send emoji reactions via IRCv3 TAGMSG."""
    
    # Emoji that need variation selector for emoji presentation
    VS16_CHARS = frozenset(
        "#*0123456789©®‼⁉ℹ™ℹ↔↕↖↗↘↙↚↛↜↝↞↟↠↡↢↣↤↥↦↧↨↩↪↫↬↭↮↯↰↱↲↳↴↵↶↷↸↹↺↻↼↽↾↿⇀⇁⇂⇃⇄⇅⇆⇇⇈⇉⇊⇋⇌⇍⇎⇏"
        "⇐⇑⇒⇓⇔⇕⇖⇗⇘⇙⇚⇛⇜⇝⇞⇟⇠⇡⇢⇣⇤⇥⇦⇧⇨⇩⇪⇫⇬⇭⇮⇯⇰⇱⇲⇳⇴⇵⇶⇷⇸⇹⇻⇼⇽⇾⇿∀∁∂∃∄∅∆∇∈∉∊∋∌∍∎∏∐∑−∓∔∕∖∗∘∙√∛∜∝∞∟∠∡∢∣∤∥∦∧∨∩∪∫∬∭∮∯∰∱∲∳∴∵∶∷∸∹∺∻∼∽∾∿"
    )
    
    @classmethod
    def normalize_emoji(cls, emoji: str) -> str:
        """Ensure emoji presentation by adding VS16 if needed."""
        if len(emoji) == 1 and emoji in cls.VS16_CHARS:
            if not emoji.endswith("\ufe0f"):
                return emoji + "\ufe0f"
        return emoji
    
    def send_reaction(self, target: str, msgid: str, emoji: str):
        """Send reaction via TAGMSG."""
        normalized = self.normalize_emoji(emoji)
        
        # TAGMSG format: @+react=emoji;+reply=msgid TAGMSG target :
        tags = f"+react={normalized};+reply={msgid}"
        self.client.send_raw(f"@{tags} TAGMSG {target} :")


class ReactionWidget(Static):
    """Display a reaction emoji with count."""
    
    DEFAULT_CSS = """
    ReactionWidget {
        padding: 0 1;
    }
    ReactionWidget .emoji {
        text-style: bold;
    }
    ReactionWidget .count {
        color: $text-muted;
        text-style: dim;
    }
    """
    
    def __init__(self, emoji: str, count: int, **kwargs):
        super().__init__(**kwargs)
        self.emoji = emoji
        self.count = count
    
    def compose(self) -> ComposeResult:
        yield Label(self.emoji, classes="emoji")
        if self.count > 1:
            yield Label(str(self.count), classes="count")
```

### Reaction Display

```python
class MessageWithReactions(Static):
    """Message widget with reaction bar."""
    
    DEFAULT_CSS = """
    MessageWithReactions {
        height: auto;
    }
    MessageWithReactions .reaction-bar {
        height: 1;
        margin-top: 1;
    }
    """
    
    def __init__(self, message: Message, **kwargs):
        super().__init__(**kwargs)
        self.message = message
        self.reactions: dict[str, set[str]] = {}  # emoji -> {senders}
    
    def compose(self) -> ComposeResult:
        # Message content
        yield MessageWidget(self.message)
        
        # Reaction bar
        with Horizontal(classes="reaction-bar"):
            for emoji, senders in self.reactions.items():
                yield ReactionWidget(emoji, len(senders))
    
    def add_reaction(self, emoji: str, sender: str):
        """Add a reaction from sender."""
        if emoji not in self.reactions:
            self.reactions[emoji] = set()
        self.reactions[emoji].add(sender)
        self.refresh()
    
    def remove_reaction(self, emoji: str, sender: str):
        """Remove a reaction from sender."""
        if emoji in self.reactions:
            self.reactions[emoji].discard(sender)
            if not self.reactions[emoji]:
                del self.reactions[emoji]
        self.refresh()
```

### Emoji Picker Implementation

```python
class EmojiPicker(ModalScreen):
    """Modal emoji picker for adding reactions."""
    
    DEFAULT_CSS = """
    EmojiPicker {
        align: center middle;
    }
    EmojiPicker .container {
        width: 40;
        height: 12;
        border: thick $primary;
        background: $surface;
    }
    """
    
    EMOJI_GRID = [
        "👍", "❤️", "😂", "😮", "😢", "🎉",
        "🔥", "👏", "🤔", "👀", "✅", "❌",
    ]
    
    def __init__(self, target_msgid: str, **kwargs):
        super().__init__(**kwargs)
        self.target_msgid = target_msgid
    
    def compose(self) -> ComposeResult:
        with Container(classes="container"):
            yield Label("Select reaction:", classes="title")
            
            with Grid(classes="emoji-grid"):
                for i, emoji in enumerate(self.EMOJI_GRID):
                    yield Button(emoji, id=f"emoji-{i}")
    
    @on(Button.Pressed)
    def on_emoji_selected(self, event: Button.Pressed) -> None:
        """User selected emoji - send reaction."""
        emoji = event.button.label
        
        self.app.post_message(EmojiSelected(
            msgid=self.target_msgid,
            emoji=emoji,
        ))
        self.dismiss()


class EmojiSelected(Message):
    """User selected emoji from picker."""
    def __init__(self, msgid: str, emoji: str):
        super().__init__()
        self.msgid = msgid
        self.emoji = emoji
```

### Reaction Aggregation

```python
class ReactionAggregator:
    """Aggregate reactions per message."""
    
    def __init__(self):
        # msgid -> {emoji: {senders}}
        self._reactions: dict[str, dict[str, set[str]]] = {}
    
    def add(self, msgid: str, emoji: str, sender: str):
        """Add reaction to message."""
        if msgid not in self._reactions:
            self._reactions[msgid] = {}
        
        if emoji not in self._reactions[msgid]:
            self._reactions[msgid][emoji] = set()
        
        self._reactions[msgid][emoji].add(sender)
    
    def remove(self, msgid: str, emoji: str, sender: str):
        """Remove reaction from message."""
        if msgid in self._reactions and emoji in self._reactions[msgid]:
            self._reactions[msgid][emoji].discard(sender)
            
            if not self._reactions[msgid][emoji]:
                del self._reactions[msgid][emoji]
            
            if not self._reactions[msgid]:
                del self._reactions[msgid]
    
    def get_for_message(self, msgid: str) -> list[ReactionGroup]:
        """Get aggregated reactions for message."""
        if msgid not in self._reactions:
            return []
        
        return [
            ReactionGroup(emoji=emoji, count=len(senders), senders=list(senders))
            for emoji, senders in self._reactions[msgid].items()
        ]
```
