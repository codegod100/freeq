# @phoenix-canon: IU-a4bef590 - Phoenix Domain
"""Loading overlay widget for FreeQ TUI.

NOTE: This widget is NOT used for the authentication flow.
The auth flow goes directly from AuthScreen to Main UI without any 
intermediate loading overlay.

This widget may be used for other purposes (e.g., connection loading)
but should NOT be used between AuthScreen and Main UI transition.
"""

from textual.screen import ModalScreen
from textual.containers import Vertical
from textual.widgets import Static, Label, Button
from textual.reactive import reactive
from textual.message import Message
from textual import on


# @phoenix-canon: node-c385163a
class LoadingOverlay(ModalScreen):
    """Loading overlay for connecting state.
    
    NOTE: NOT used for auth flow - auth goes directly from AuthScreen to Main UI.
    May be used for other connection loading scenarios.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    LoadingOverlay {
        align: center middle;
        background: $surface-darken-2 90%;
    }
    LoadingOverlay .container {
        width: 40;
        height: auto;
        border: thick $primary;
        background: $surface;
        padding: 2;
        content-align: center middle;
    }
    LoadingOverlay .spinner {
        text-align: center;
        height: 3;
        text-style: bold;
    }
    LoadingOverlay .status {
        text-align: center;
        margin-top: 1;
        text-style: dim;
    }
    LoadingOverlay .cancel-btn {
        margin-top: 1;
        width: 100%;
    }
    """
    
    status_text = reactive("Connecting...")
    show_cancel = reactive(True)
    
    def __init__(
        self,
        status: str = "Connecting...",
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize loading overlay.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.status_text = status
        self.show_cancel = True
    
    def compose(self):
        """Compose loading overlay."""
        with Vertical(classes="container"):
            # Spinner animation using text
            yield Static("◐", classes="spinner")
            yield Label(self.status_text, classes="status")
            
            if self.show_cancel:
                yield Button("Cancel", id="cancel-btn", variant="error")
    
    # @phoenix-canon: node-43cb8709
    def watch_status_text(self, status: str):
        """Update status text.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            status_label = self.query_one(".status", Label)
            status_label.update(status)
        except Exception:
            pass
    
    # @phoenix-canon: node-43cb8709
    def watch_show_cancel(self, show: bool):
        """Update cancel button visibility.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            cancel_btn = self.query_one("#cancel-btn", Button)
            cancel_btn.visible = show
        except Exception:
            pass
    
    def on_mount(self):
        """Start spinner animation."""
        self.set_interval(0.1, self._animate_spinner)
    
    def _animate_spinner(self):
        """Animate spinner."""
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        try:
            spinner = self.query_one(".spinner", Static)
            frames = ["◐", "◓", "◑", "◒"]
            current = spinner.renderable
            try:
                idx = frames.index(str(current))
                next_idx = (idx + 1) % len(frames)
            except ValueError:
                next_idx = 0
            spinner.update(frames[next_idx])
        except Exception:
            pass
    
    @on(Button.Pressed, "#cancel-btn")
    def on_cancel(self):
        """Handle cancel button."""
        self.post_message(LoadingCancelled())
        self.dismiss()
    
    def update_status(self, status: str):
        """Update status text."""
        self.status_text = status


class LoadingCancelled(Message):
    """Loading cancelled event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self):
        super().__init__()  # REQUIRED for Textual messages


class LoadingStatusUpdated(Message):
    """Loading status updated.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, status: str):
        super().__init__()  # REQUIRED for Textual messages
        self.status = status
