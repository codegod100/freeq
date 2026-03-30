"""Debug panel widget - shows recent events below chat input."""

from textual.widgets import Static
from textual.containers import ScrollableContainer


class DebugPanel(ScrollableContainer):
    """A scrollable panel that shows recent debug events."""
    
    DEFAULT_CSS = """
    DebugPanel {
        height: 6;
        background: $surface;
        padding: 0 1;
        dock: bottom;
    }
    
    DebugPanel > Static {
        color: yellow;
    }
    """
    
    MAX_LINES = 100
    
    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._static = Static("", id="debug-content")
        self._lines: list[str] = []
        self._initialized = False
    
    def compose(self):
        yield self._static
    
    def on_mount(self) -> None:
        self._initialized = True
        self._static.update("[DEBUG PANEL]")
    
    def log(self, msg: str) -> None:
        """Add a log message."""
        if not self._initialized:
            return
        self._lines.append(msg)
        if len(self._lines) > self.MAX_LINES:
            self._lines = self._lines[-self.MAX_LINES:]
        # Update display
        self._static.update("\n".join(self._lines[-20:]))
        # Scroll to bottom
        self.scroll_end(animate=False)
    
    def clear_log(self) -> None:
        """Clear the log."""
        self._lines.clear()
        self._static.update("")