"""Debug panel widget - shows recent events below chat input."""

from textual.widgets import Static
from textual.message import Message


class DebugPanel(Static):
    """A panel that shows recent debug events."""
    
    DEFAULT_CSS = """
    DebugPanel {
        height: 6;
        background: $surface;
        color: yellow;
        padding: 0 1;
        overflow-y: auto;
        dock: bottom;
    }
    """
    
    MAX_LINES = 50
    
    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._lines: list[str] = []
    
    def log(self, msg: str) -> None:
        """Add a log message."""
        self._lines.append(msg)
        if len(self._lines) > self.MAX_LINES:
            self._lines = self._lines[-self.MAX_LINES:]
        self.update("\n".join(self._lines[-10:]))  # Show last 10 lines
    
    def clear(self) -> None:
        """Clear the log."""
        self._lines.clear()
        self.update("")