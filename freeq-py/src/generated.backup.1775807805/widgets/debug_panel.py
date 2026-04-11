# @phoenix-canon: IU-517684c6 - Requirements Domain
"""Debug panel widget for FreeQ TUI."""

from textual.widget import Widget
from textual.containers import Vertical, VerticalScroll
from textual.widgets import Static, Label, Button
from textual.reactive import reactive
from textual.message import Message
from textual import on
from datetime import datetime
from typing import List


# @phoenix-canon: node-c385163a
class DebugPanel(Widget):
    """Debug panel showing logs and state.
    
    REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
    and pass to super().__init__().
    """
    
    DEFAULT_CSS = """
    DebugPanel {
        dock: bottom;
        height: 10;
        width: 100%;
        border-top: solid $warning;
        background: $surface-darken-2;
        layer: overlay;
        display: none;
    }
    DebugPanel.visible {
        display: block;
    }
    DebugPanel .header {
        height: 1;
        background: $warning-darken-2;
        color: $text;
        padding: 0 1;
        content-align: center middle;
    }
    DebugPanel .log-container {
        height: 1fr;
        overflow-y: scroll;
        padding: 0 1;
    }
    DebugPanel .log-entry {
        height: auto;
        text-style: dim;
    }
    DebugPanel .log-entry.error {
        color: $error;
    }
    DebugPanel .log-entry.warning {
        color: $warning;
    }
    DebugPanel .log-entry.info {
        color: $primary;
    }
    """
    
    logs = reactive(list)
    visible = reactive(False)
    max_logs = reactive(100)
    
    def __init__(
        self,
        app_state=None,
        id: str = None,
        classes: str = None,
        **kwargs
    ):
        """Initialize debug panel.
        
        REQUIREMENT: Widget initialization MUST accept id, classes, **kwargs 
        and pass to super().__init__().
        """
        super().__init__(id=id, classes=classes, **kwargs)
        self.app_state = app_state
        self.logs: List[dict] = []
        self.max_logs = 100
    
    def compose(self):
        """Compose debug panel."""
        yield Label("Debug Panel (F1 to toggle)", classes="header")
        
        with VerticalScroll(classes="log-container"):
            for log in self.logs[-20:]:  # Show last 20
                yield self._create_log_entry(log)
    
    def _create_log_entry(self, log: dict) -> Label:
        """Create log entry widget."""
        timestamp = log.get("timestamp", datetime.now()).strftime("%H:%M:%S.%f")[:-3]
        level = log.get("level", "INFO")
        message = log.get("message", "")
        
        classes = "log-entry"
        if level == "ERROR":
            classes += " error"
        elif level == "WARNING":
            classes += " warning"
        elif level == "INFO":
            classes += " info"
        
        return Label(
            f"[{timestamp}] [{level}] {message}",
            classes=classes
        )
    
    # @phoenix-canon: node-43cb8709
    def watch_logs(self, logs: list):
        """React to log changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        log_container = self.query_one(".log-container", VerticalScroll)
        log_container.remove_children()
        
        for log in logs[-20:]:  # Show last 20
            log_container.mount(self._create_log_entry(log))
        
        # Auto-scroll to bottom
        log_container.scroll_end(animate=False)
    
    # @phoenix-canon: node-43cb8709
    def watch_visible(self, visible: bool):
        """React to visibility changes.
        
        REQUIREMENT: The _update_ui_from_state method MUST check 
        is_mounted before accessing children to avoid lifecycle errors.
        """
        # @phoenix-canon: node-43cb8709
        if not self.is_mounted:
            return
        
        if visible:
            self.add_class("visible")
        else:
            self.remove_class("visible")
    
    def log(self, message: str, level: str = "INFO"):
        """Add log entry."""
        log_entry = {
            "timestamp": datetime.now(),
            "level": level,
            "message": message,
        }
        
        self.logs.append(log_entry)
        
        # Trim if too many
        if len(self.logs) > self.max_logs:
            self.logs = self.logs[-self.max_logs:]
    
    def info(self, message: str):
        """Log info message."""
        self.log(message, "INFO")
    
    def warning(self, message: str):
        """Log warning message."""
        self.log(message, "WARNING")
    
    def error(self, message: str):
        """Log error message."""
        self.log(message, "ERROR")
    
    def clear(self):
        """Clear all logs."""
        self.logs = []
    
    def toggle(self):
        """Toggle debug panel visibility."""
        self.visible = not self.visible
    
    def show(self):
        """Show debug panel."""
        self.visible = True
    
    def hide(self):
        """Hide debug panel."""
        self.visible = False


class LogEntry(Message):
    """Log entry event.
    
    REQUIREMENT: All event messages MUST inherit from textual.message.Message 
    and call super().__init__().
    """
    
    def __init__(self, message: str, level: str = "INFO"):
        super().__init__()  # REQUIRED for Textual messages
        self.message = message
        self.level = level
