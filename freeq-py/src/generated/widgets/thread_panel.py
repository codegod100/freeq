# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Thread panel widget for FreeQ TUI."""

from textual.screen import ModalScreen
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.widgets import Static, Label, Button, Input
from textual.reactive import reactive
from textual.message import Message
from textual import on

from ..models import Thread, Message
from .message_item import MessageWidget


# @phoenix-canon: node-c385163a
class ThreadPanel(ModalScreen):
    """Side panel showing thread conversation.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
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
        content-align: center middle;
    }
    ThreadPanel .messages {
        height: 1fr;
        overflow-y: scroll;
    }
    ThreadPanel .reply-box {
        height: 3;
        border-top: solid $primary;
        padding: 0 1;
    }
    ThreadPanel .reply-info {
        color: $text-muted;
        text-style: italic;
        height: 1;
    }
    """
    
    thread = reactive(None)
    open = reactive(False)
    
    def __init__(
        self,
        thread: Thread = None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize thread panel.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.thread = thread or Thread()
        self.open = False
    
    def compose(self):
        """Compose thread panel."""
        # Header with stats
        with Horizontal(classes="header"):
            yield Label(
                f"Thread: {self.thread.participant_count} participants, "
                f"{self.thread.reply_count + 1} messages"
            )
            yield Button("✕", id="close-btn", variant="error")
        
        # Messages (root + replies)
        with VerticalScroll(classes="messages"):
            if self.thread.root_message:
                yield MessageWidget(self.thread.root_message, highlight=True)
            for reply in self.thread.replies:
                yield MessageWidget(reply, indent=2)
        
        # Reply input
        with Horizontal(classes="reply-box"):
            yield Input(placeholder="Reply to thread...", id="reply-input")
            yield Button("Send", id="send-btn", variant="primary")
    
    # @phoenix-canon: node-43cb8709
    def watch_thread(self, thread: Thread):
        """React to thread changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        # Update header
        header_label = self.query_one(".header Label", Label)
        header_label.update(
            f"Thread: {thread.participant_count} participants, "
            f"{thread.reply_count + 1} messages"
        )
        
        # Update messages
        messages_container = self.query_one(".messages", VerticalScroll)
        messages_container.remove_children()
        
        if thread.root_message:
            messages_container.mount(MessageWidget(thread.root_message, highlight=True))
        for reply in thread.replies:
            messages_container.mount(MessageWidget(reply, indent=2))
    
    # @phoenix-canon: node-43cb8709
    def watch_open(self, open: bool):
        """React to open state changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        if open:
            self.styles.display = "block"
        else:
            self.styles.display = "none"
    
    @on(Button.Pressed, "#close-btn")
    def on_close(self):
        """Close thread panel."""
        self.open = False
        self.dismiss()
    
    @on(Button.Pressed, "#send-btn")
    def on_send_reply(self):
        """Send reply to thread root."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        input_widget = self.query_one("#reply-input", Input)
        content = input_widget.value.strip()
        
        if content and self.thread.root_msgid:
            self.post_message(ThreadReplyRequested(
                root_msgid=self.thread.root_msgid,
                content=content,
            ))
            input_widget.value = ""
    
    def show_thread(self, thread: Thread):
        """Show thread in panel."""
        self.thread = thread
        self.open = True
    
    def hide(self):
        """Hide thread panel."""
        self.open = False


class ShowThreadRequested(Message):
    """Request to show thread panel.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, msgid: str):
        super().__init__()  # REQUIRED for Textual messages
        self.msgid = msgid


class ThreadReplyRequested(Message):
    """Request to send reply to thread.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, root_msgid: str, content: str):
        super().__init__()  # REQUIRED for Textual messages
        self.root_msgid = root_msgid
        self.content = content


class StartReplyRequested(Message):
    """Request to start replying to a message.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, msgid: str, sender: str):
        super().__init__()  # REQUIRED for Textual messages
        self.msgid = msgid
        self.sender = sender
