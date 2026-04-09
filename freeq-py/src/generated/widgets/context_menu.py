# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Context menu widget for FreeQ TUI."""

from textual.screen import ModalScreen
from textual.containers import Vertical
from textual.widgets import Static, Label, Button
from textual.reactive import reactive
from textual.message import Message
from textual import on

from ..models import Message


# @phoenix-canon: node-c385163a
class ContextMenu(ModalScreen):
    """Context menu for message actions.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    ContextMenu {
        align: center middle;
        background: $surface-darken-2 80%;
    }
    ContextMenu .menu {
        width: 24;
        height: auto;
        background: $surface;
        border: solid $primary;
        padding: 1;
    }
    ContextMenu .title {
        text-align: center;
        text-style: bold;
        height: 1;
        margin-bottom: 1;
        border-bottom: solid $primary-darken-2;
    }
    ContextMenu .menu-btn {
        width: 100%;
        height: auto;
        content-align: center middle;
        margin-top: 1;
    }
    """
    
    message = reactive(None)
    is_own_message = reactive(False)
    
    def __init__(
        self,
        message: Message = None,
        is_own_message: bool = False,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize context menu.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.message = message or Message()
        self.is_own_message = is_own_message
    
    def compose(self):
        """Compose context menu."""
        with Vertical(classes="menu"):
            yield Label("Actions", classes="title")
            
            yield Button("📧 Reply", id="reply-btn", variant="primary")
            yield Button("😊 React", id="react-btn", variant="primary")
            
            if self.is_own_message:
                yield Button("✏️ Edit", id="edit-btn", variant="warning")
                yield Button("🗑️ Delete", id="delete-btn", variant="error")
            
            if self.message.reply_count > 0:
                yield Button(
                    f"💬 View Thread ({self.message.reply_count})",
                    id="view-thread-btn",
                    variant="primary",
                )
            
            yield Button("Cancel", id="cancel-btn", variant="default")
    
    @on(Button.Pressed, "#reply-btn")
    def on_reply(self):
        """Start reply to message."""
        from ..widgets.thread_panel import StartReplyRequested
        self.post_message(StartReplyRequested(
            msgid=self.message.msgid,
            sender=self.message.sender,
        ))
        self.dismiss()
    
    @on(Button.Pressed, "#react-btn")
    def on_react(self):
        """Open emoji picker."""
        self.post_message(OpenEmojiPickerRequested(
            target_msgid=self.message.msgid
        ))
        self.dismiss()
    
    @on(Button.Pressed, "#edit-btn")
    def on_edit(self):
        """Edit own message."""
        self.post_message(EditMessageRequested(
            msgid=self.message.msgid,
            current_content=self.message.content,
        ))
        self.dismiss()
    
    @on(Button.Pressed, "#delete-btn")
    def on_delete(self):
        """Delete own message."""
        self.post_message(DeleteMessageRequested(msgid=self.message.msgid))
        self.dismiss()
    
    @on(Button.Pressed, "#view-thread-btn")
    def on_view_thread(self):
        """View message thread."""
        from ..widgets.thread_panel import ShowThreadRequested
        self.post_message(ShowThreadRequested(msgid=self.message.msgid))
        self.dismiss()
    
    @on(Button.Pressed, "#cancel-btn")
    def on_cancel(self):
        """Close context menu."""
        self.dismiss()


class OpenEmojiPickerRequested(Message):
    """Request to open emoji picker.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, target_msgid: str):
        super().__init__()  # REQUIRED for Textual messages
        self.target_msgid = target_msgid


class EditMessageRequested(Message):
    """Request to edit a message.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, msgid: str, current_content: str):
        super().__init__()  # REQUIRED for Textual messages
        self.msgid = msgid
        self.current_content = current_content


class DeleteMessageRequested(Message):
    """Request to delete a message.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, msgid: str):
        super().__init__()  # REQUIRED for Textual messages
        self.msgid = msgid
