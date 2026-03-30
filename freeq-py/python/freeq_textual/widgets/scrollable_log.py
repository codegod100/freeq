"""ScrollableLog widget - RichLog with padding between text and scrollbar."""

from textual.widgets import RichLog


class ScrollableLog(RichLog):
    """A RichLog with padding between text and scrollbar."""

    DEFAULT_CSS = """
    ScrollableLog {
        border: none;
        overflow-x: hidden;
        width: 1fr;
        min-width: 0;
        padding: 0 3 0 1;
        scrollbar-gutter: stable;
        scrollbar-size: 1 1;
    }
    """