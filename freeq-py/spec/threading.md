# Threading Domain Specification

## Part 1: Abstract System Design

### Domain Model

```
Entity Thread:
  root_msgid: String (IRCv3 msgid of root message)
  root_message: Message
  replies: List[Message] (chronological order)
  participant_count: Int
  reply_count: Int
  last_activity: DateTime

Entity Reply:
  message: Message
  parent_msgid: String (message being replied to)
  root_msgid: String (thread root)

Entity ThreadPanelState:
  open: Bool
  active_thread: String | None (root_msgid)
  width: Percentage (40% default)
```

### Thread Hierarchy

```
Tree ThreadTree:
  root: Message
  children: List[Reply]
  depth: calculated from reply chain

Reply Indicators:
  - Show parent author
  - Link to thread panel
  - Highlight related messages
```

### Thread Panel

```
Overlay ThreadPanel:
  trigger: event == ShowThread
  presentation: MODAL_RIGHT(width: 40%)
  dismissable: true
  content:
    - Header: participants, message count
    - Tree: chronological messages
    - Reply box at bottom
```

### Context Menu Actions

```
Menu MessageContextMenu:
  trigger: right-click on message
  actions:
    - Reply: start reply to this message
    - Edit: edit own message
    - Delete: delete own message
    - React: open emoji picker
    - View Thread: open thread panel
```

---

## Part 2: Implementation Guidance (Python/Textual)

### Thread Tracking

```python
class ThreadManager:
    """Track thread relationships and reply chains."""
    
    def __init__(self):
        # msgid -> Thread (for root messages)
        self._threads: dict[str, Thread] = {}
        # msgid -> root_msgid (for all messages in threads)
        self._message_to_thread: dict[str, str] = {}
    
    def add_message(self, msg: Message) -> None:
        """Add message, tracking thread relationships."""
        reply_to = msg.tags.get("+reply")
        
        if reply_to:
            # This is a reply - add to existing thread
            root_msgid = self._find_root(reply_to)
            if root_msgid in self._threads:
                self._threads[root_msgid].replies.append(msg)
                self._message_to_thread[msg.msgid] = root_msgid
                self._update_thread_stats(root_msgid)
        else:
            # This is a new root message
            self._threads[msg.msgid] = Thread(
                root_msgid=msg.msgid,
                root_message=msg,
                replies=[],
                participant_count=1,
                reply_count=0,
                last_activity=msg.timestamp,
            )
            self._message_to_thread[msg.msgid] = msg.msgid
    
    def _find_root(self, msgid: str) -> str | None:
        """Find root msgid for any message in thread."""
        # Chase reply chain to root
        seen = set()
        current = msgid
        
        while current in self._message_to_thread:
            if current in seen:
                break  # Cycle detected
            seen.add(current)
            
            root = self._message_to_thread[current]
            if root == current:
                return current  # Found root
            current = root
        
        return None
    
    def _update_thread_stats(self, root_msgid: str) -> None:
        """Recalculate thread statistics."""
        thread = self._threads[root_msgid]
        
        participants = {thread.root_message.sender}
        for reply in thread.replies:
            participants.add(reply.sender)
        
        thread.participant_count = len(participants)
        thread.reply_count = len(thread.replies)
        
        if thread.replies:
            thread.last_activity = max(r.timestamp for r in thread.replies)
    
    def get_thread(self, msgid: str) -> Thread | None:
        """Get thread for any message (root or reply)."""
        root_msgid = self._message_to_thread.get(msgid)
        if root_msgid:
            return self._threads.get(root_msgid)
        return None


class Thread:
    """Thread data structure."""
    def __init__(
        self,
        root_msgid: str,
        root_message: Message,
        replies: list[Message],
        participant_count: int,
        reply_count: int,
        last_activity: datetime,
    ):
        self.root_msgid = root_msgid
        self.root_message = root_message
        self.replies = replies
        self.participant_count = participant_count
        self.reply_count = reply_count
        self.last_activity = last_activity
```

### Thread Panel Implementation

```python
class ThreadPanel(ModalScreen):
    """Side panel showing thread conversation."""
    
    DEFAULT_CSS = """
    ThreadPanel {
        dock: right;
        width: 40%;
        height: 100%;
        background: $surface;
        border-left: solid $primary;
    }
    ThreadPanel .header {
        height: 3;
        background: $surface-darken-1;
        padding: 0 1;
    }
    ThreadPanel .messages {
        height: 1fr;
        overflow-y: scroll;
    }
    ThreadPanel .reply-box {
        height: 3;
        border-top: solid $primary;
    }
    """
    
    def __init__(self, thread: Thread, **kwargs):
        super().__init__(**kwargs)
        self.thread = thread
    
    def compose(self) -> ComposeResult:
        # Header with stats
        with Horizontal(classes="header"):
            yield Label(
                f"Thread: {self.thread.participant_count} participants, "
                f"{self.thread.reply_count + 1} messages"
            )
            yield Button("✕", id="close-btn", variant="error")
        
        # Messages (root + replies)
        with VerticalScroll(classes="messages"):
            yield MessageWidget(self.thread.root_message, highlight=True)
            for reply in self.thread.replies:
                yield MessageWidget(reply, indent=2)
        
        # Reply input
        with Horizontal(classes="reply-box"):
            yield Input(placeholder="Reply to thread...", id="reply-input")
            yield Button("Send", id="send-btn")
    
    @on(Button.Pressed, "#close-btn")
    def on_close(self):
        self.dismiss()
    
    @on(Button.Pressed, "#send-btn")
    def on_send_reply(self):
        """Send reply to thread root."""
        input_widget = self.query_one("#reply-input", Input)
        content = input_widget.value.strip()
        
        if content:
            self.app.post_message(ThreadReplyRequested(
                root_msgid=self.thread.root_msgid,
                content=content,
            ))
            input_widget.value = ""


class ShowThreadRequested(Message):
    """Request to show thread panel."""
    def __init__(self, msgid: str):
        super().__init__()
        self.msgid = msgid


class ThreadReplyRequested(Message):
    """Request to send reply to thread."""
    def __init__(self, root_msgid: str, content: str):
        super().__init__()
        self.root_msgid = root_msgid
        self.content = content
```

### Reply Indicator

```python
class ReplyIndicator(Static):
    """Shows reply relationship inline with message."""
    
    DEFAULT_CSS = """
    ReplyIndicator {
        color: $primary;
        text-style: italic;
    }
    """
    
    def __init__(self, parent_sender: str, **kwargs):
        super().__init__(**kwargs)
        self.parent_sender = parent_sender
    
    def compose(self) -> ComposeResult:
        yield Label(f"↳ replying to {self.parent_sender}")
    
    def on_click(self):
        """Click to view thread."""
        self.app.post_message(ShowThreadRequested(msgid=self.parent_msgid))


class MessageWithReply(Static):
    """Message widget with inline reply indicator."""
    
    def compose(self) -> ComposeResult:
        if self.message.reply_to:
            yield ReplyIndicator(self.message.reply_to_sender)
        
        yield MessageWidget(self.message)
```

### Context Menu

```python
class MessageContextMenu(ModalScreen):
    """Context menu for message actions."""
    
    DEFAULT_CSS = """
    MessageContextMenu {
        layer: overlay;
        align: center middle;
    }
    MessageContextMenu .menu {
        width: 20;
        height: auto;
        background: $surface;
        border: solid $primary;
    }
    """
    
    def __init__(self, message: Message, is_own_message: bool, **kwargs):
        super().__init__(**kwargs)
        self.message = message
        self.is_own = is_own_message
    
    def compose(self) -> ComposeResult:
        with Vertical(classes="menu"):
            yield Button("📧 Reply", id="reply-btn", variant="primary")
            yield Button("😊 React", id="react-btn", variant="primary")
            
            if self.is_own:
                yield Button("✏️ Edit", id="edit-btn", variant="warning")
                yield Button("🗑️ Delete", id="delete-btn", variant="error")
            
            if self.message.reply_count > 0:
                yield Button(
                    f"💬 View Thread ({self.message.reply_count})",
                    id="view-thread-btn",
                    variant="primary",
                )
    
    @on(Button.Pressed, "#reply-btn")
    def on_reply(self):
        self.app.post_message(StartReplyRequested(
            msgid=self.message.msgid,
            sender=self.message.sender,
        ))
        self.dismiss()
    
    @on(Button.Pressed, "#react-btn")
    def on_react(self):
        self.app.push_screen(EmojiPicker(target_msgid=self.message.msgid))
        self.dismiss()
    
    @on(Button.Pressed, "#edit-btn")
    def on_edit(self):
        self.app.post_message(EditMessageRequested(
            msgid=self.message.msgid,
            current_content=self.message.content,
        ))
        self.dismiss()
    
    @on(Button.Pressed, "#delete-btn")
    def on_delete(self):
        self.app.post_message(DeleteMessageRequested(msgid=self.message.msgid))
        self.dismiss()
    
    @on(Button.Pressed, "#view-thread-btn")
    def on_view_thread(self):
        self.app.post_message(ShowThreadRequested(msgid=self.message.msgid))
        self.dismiss()
```

### Reply Input Bar

```python
class ReplyInputBar(Static):
    """Input bar when replying to a message."""
    
    DEFAULT_CSS = """
    ReplyInputBar {
        height: auto;
        background: $surface-darken-1;
        border-top: solid $primary;
        padding: 1;
    }
    ReplyInputBar .reply-info {
        color: $text-muted;
        text-style: italic;
    }
    """
    
    def __init__(self, reply_to_msgid: str, reply_to_sender: str, **kwargs):
        super().__init__(**kwargs)
        self.reply_to_msgid = reply_to_msgid
        self.reply_to_sender = reply_to_sender
    
    def compose(self) -> ComposeResult:
        yield Label(
            f"↳ Replying to {self.reply_to_sender}",
            classes="reply-info"
        )
        
        with Horizontal():
            yield Input(placeholder="Type your reply...", id="reply-input")
            yield Button("Send", id="send-btn", variant="success")
            yield Button("Cancel", id="cancel-btn", variant="error")
    
    @on(Button.Pressed, "#send-btn")
    def on_send(self):
        input_widget = self.query_one("#reply-input", Input)
        content = input_widget.value.strip()
        
        if content:
            self.app.post_message(SendReplyRequested(
                reply_to_msgid=self.reply_to_msgid,
                content=content,
            ))
            self.remove()  # Close reply bar
```

### Thread Highlighting

```python
class MessageList(VerticalScroll):
    """Message list with thread highlighting."""
    
    def highlight_thread(self, root_msgid: str):
        """Highlight all messages in thread."""
        for widget in self.query(MessageWidget):
            thread = self.app.thread_manager.get_thread(widget.message.msgid)
            if thread and thread.root_msgid == root_msgid:
                widget.add_class("thread-highlight")
            else:
                widget.remove_class("thread-highlight")
```
