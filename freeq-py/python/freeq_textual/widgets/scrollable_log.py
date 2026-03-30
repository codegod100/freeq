"""ScrollableLog widget - RichLog with thumb-only scrollbar."""

from textual.widgets import RichLog


class ScrollableLog(RichLog):
    """A RichLog with thumb-only scrollbar (transparent track)."""

    DEFAULT_CSS = """
    ScrollableLog {
        border: none;
        overflow-x: hidden;
        width: 1fr;
        min-width: 0;
        padding: 0 1;
        scrollbar-gutter: stable;
        scrollbar-size: 1 1;
        scrollbar-background: $surface;
        scrollbar-background-hover: $surface;
        scrollbar-background-active: $surface;
        scrollbar-color: $panel-lighten-1;
        scrollbar-color-hover: $primary;
        scrollbar-color-active: $primary;
    }
    """