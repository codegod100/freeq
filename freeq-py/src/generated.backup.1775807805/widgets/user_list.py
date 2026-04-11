# @phoenix-canon: IU-517684c6 - Requirements Domain
"""User list widget for FreeQ TUI."""

from textual.widget import Widget
from textual.containers import VerticalScroll
from textual.widgets import Static, Label
from textual.reactive import reactive
from textual.message import Message

from ..models import User, ChannelState


# @phoenix-canon: node-c385163a
class UserList(Widget):
    """List of users in current channel.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    UserList {
        width: 100%;
        height: 100%;
        border: solid $primary;
        background: $surface;
    }
    UserList .header {
        height: 1;
        background: $surface-darken-1;
        padding: 0 1;
        content-align: center middle;
    }
    UserList .user-list {
        height: 1fr;
        overflow-y: scroll;
    }
    UserList .user-item {
        height: auto;
        padding: 0 1;
    }
    UserList .user-item:hover {
        background: $surface-darken-1;
    }
    UserList .op {
        color: $warning;
        text-style: bold;
    }
    UserList .voice {
        color: $success;
    }
    UserList .count {
        color: $text-muted;
        text-style: dim;
        height: 1;
        padding: 0 1;
        content-align: center middle;
    }
    """
    
    users = reactive(list)
    channel_name = reactive("")
    
    def __init__(
        self,
        app_state=None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize user list.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.app_state = app_state
        # Populate users from active channel in app_state
        if self.app_state and hasattr(self.app_state, 'ui') and self.app_state.ui:
            active_buffer_id = self.app_state.ui.active_buffer_id
            if active_buffer_id and active_buffer_id in self.app_state.channels:
                channel = self.app_state.channels[active_buffer_id]
                self.users = list(channel.users) if hasattr(channel, 'users') else []
                self.channel_name = active_buffer_id
            else:
                self.users = []
                self.channel_name = ""
        else:
            self.users = []
            self.channel_name = ""
        self.channel_name = ""
    
    def compose(self):
        """Compose user list."""
        yield Label(f"Users ({len(self.users)})", classes="header")
        
        with VerticalScroll(classes="user-list"):
            for user in self.users:
                yield self._create_user_widget(user)
    
    def _create_user_widget(self, user: User) -> Static:
        """Create widget for a single user."""
        prefix = ""
        classes = "user-item"
        
        if "@" in user.modes or "o" in user.modes:
            prefix = "@"
            classes += " op"
        elif "+" in user.modes or "v" in user.modes:
            prefix = "+"
            classes += " voice"
        
        return Static(f"{prefix}{user.nick}", classes=classes)
    
    # @phoenix-canon: node-43cb8709
    def watch_users(self, users: list):
        """React to user list changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        # Update header count
        header = self.query_one(".header", Label)
        header.update(f"Users ({len(users)})")
        
        # Update user list
        user_list = self.query_one(".user-list", VerticalScroll)
        user_list.remove_children()
        
        for user in users:
            user_list.mount(self._create_user_widget(user))
    
    # @phoenix-canon: node-43cb8709
    def watch_channel_name(self, name: str):
        """React to channel name changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        header = self.query_one(".header", Label)
        header.update(f"{name} - Users ({len(self.users)})")
    
    def update_users(self, users: list[User]):
        """Update user list."""
        self.users = users
    
    def update_channel(self, channel_name: str):
        """Update channel name."""
        self.channel_name = channel_name
    
    def on_click(self, event):
        """Handle user selection."""
        widget = event.control
        if hasattr(widget, 'user'):
            self.post_message(UserSelected(user=widget.user))


class UserSelected(Message):
    """User selection event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, user: User):
        super().__init__()  # REQUIRED for Textual messages
        self.user = user
