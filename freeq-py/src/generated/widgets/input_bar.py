# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Input bar widget for FreeQ TUI."""

import logging
from textual.widget import Widget
from textual.containers import Horizontal
from textual.widgets import Input, Button, Static
from textual.reactive import reactive
from textual.message import Message as TextualMessage
from textual import on

from ..models import Message, AppState

logger = logging.getLogger(__name__)


# @phoenix-canon: node-c385163a
class InputBar(Widget):
    """Input bar for typing messages and commands.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    InputBar {
        height: auto;
        min-height: 3;
        max-height: 6;
        border-top: solid $primary;
        background: $surface;
        padding: 0 1;
    }
    InputBar .input-container {
        height: auto;
        width: 1fr;
    }
    InputBar #message-input {
        width: 100%;
        height: auto;
    }
    InputBar .actions {
        width: auto;
        height: auto;
    }
    InputBar .reply-info {
        color: $primary;
        text-style: italic;
        height: 1;
    }
    """
    
    placeholder = reactive("Type a message...")
    reply_to = reactive(None)
    multiline = reactive(False)
    
    def __init__(
        self,
        app_state: AppState = None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize input bar.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.app_state = app_state or AppState()
        self.reply_to = None
        self.multiline = False
    
    def compose(self):
        """Compose input bar."""
        # @phoenix-canon: node-c385163a
        logger.info("[UI] InputBar composing layout")
        # Reply indicator (shown when replying)
        if self.reply_to:
            yield Static(
                f"↳ Replying to {self.reply_to['sender']}",
                classes="reply-info"
            )
        
        with Horizontal():
            # Message input
            yield Input(
                placeholder=self.placeholder,
                id="message-input"
            )
            
            # Action buttons
            with Horizontal(classes="actions"):
                yield Button("📎", id="attach-btn", variant="primary")
                yield Button("😊", id="emoji-btn", variant="primary")
                yield Button("➤", id="send-btn", variant="success")
        logger.info("[UI] InputBar composed with input and buttons")
    
    # @phoenix-canon: node-43cb8709
    def watch_reply_to(self, reply_to: dict):
        """React to reply state changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        # Update or add reply info
        existing = self.query(".reply-info")
        if existing:
            existing.first().update(
                f"↳ Replying to {reply_to['sender']}" if reply_to else ""
            )
        elif reply_to:
            # Add reply info at top
            self.mount(
                Static(
                    f"↳ Replying to {reply_to['sender']}",
                    classes="reply-info"
                ),
                before=0
            )
    
    # @phoenix-canon: node-43cb8709
    def watch_placeholder(self, placeholder: str):
        """Update placeholder text.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            input_widget = self.query_one("#message-input", Input)
            input_widget.placeholder = placeholder
        except Exception:
            pass
    
    @on(Button.Pressed, "#send-btn")
    @on(Input.Submitted, "#message-input")
    def on_send(self):
        """Handle send button or enter key."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        input_widget = self.query_one("#message-input", Input)
        content = input_widget.value.strip()
        
        if content:
            # Check if it's a command
            if content.startswith("/"):
                self.post_message(CommandEntered(command=content))
            else:
                self.post_message(MessageSent(
                    content=content,
                    reply_to=self.reply_to
                ))
            
            # Clear input
            input_widget.value = ""
            
            # Clear reply state
            if self.reply_to:
                self.reply_to = None
                # Remove reply info
                for widget in self.query(".reply-info"):
                    widget.remove()
    
    @on(Button.Pressed, "#emoji-btn")
    def on_emoji_button(self):
        """Open emoji picker."""
        self.post_message(EmojiPickerRequested())
    
    @on(Button.Pressed, "#attach-btn")
    def on_attach(self):
        """Handle attach button."""
        self.post_message(AttachRequested())
    
    def start_reply(self, msgid: str, sender: str):
        """Start replying to a message."""
        self.reply_to = {"msgid": msgid, "sender": sender}
        self.focus_input()
    
    def cancel_reply(self):
        """Cancel reply mode."""
        self.reply_to = None
    
    def focus_input(self):
        """Focus the input field."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            input_widget = self.query_one("#message-input", Input)
            input_widget.focus()
        except Exception:
            pass
    
    def clear(self):
        """Clear input."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            input_widget = self.query_one("#message-input", Input)
            input_widget.value = ""
        except Exception:
            pass


class MessageSent(TextualMessage):
    """Message sent event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, content: str, reply_to: dict = None):
        super().__init__()  # REQUIRED for Textual messages
        self.content = content
        self.reply_to = reply_to


class CommandEntered(TextualMessage):
    """Command entered event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, command: str):
        super().__init__()  # REQUIRED for Textual messages
        self.command = command


class EmojiPickerRequested(TextualMessage):
    """Request to open emoji picker.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self):
        super().__init__()  # REQUIRED for Textual messages


class AttachRequested(TextualMessage):
    """Request to attach file.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self):
        super().__init__()  # REQUIRED for Textual messages
