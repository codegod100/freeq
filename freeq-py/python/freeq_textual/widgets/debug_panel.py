"""Debug panel widget - shows recent events below chat input."""

from textual.widgets import RichLog
from rich.text import Text


class DebugPanel(RichLog):
    """A scrollable panel that shows recent debug events."""
    
    DEFAULT_CSS = """
    DebugPanel {
        height: 6;
        background: $surface;
        color: yellow;
        padding: 0 1;
        dock: bottom;
    }
    """
    
    MAX_LINES = 100
    
    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs, wrap=True, highlight=True, markup=False)
        self._initialized = False
    
    def on_mount(self) -> None:
        self._initialized = True
        self.write(Text("[DEBUG PANEL]", style="bold yellow"))
    
    def log(self, msg: str) -> None:
        """Add a log message."""
        if not self._initialized:
            return
        self.write(Text(msg, style="yellow"))
        # Auto-scroll to bottom
        self.scroll_end(animate=False)
    
    def clear_log(self) -> None:
        """Clear the log."""
        super().clear()