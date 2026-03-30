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
        padding: 0 1;
        scrollbar-gutter: stable;
        scrollbar-size: 2 1;
    }
    """

    def write(self, *args, **kwargs) -> None:
        """Override write to add trailing padding to Text content."""
        from rich.text import Text
        if args and isinstance(args[0], Text):
            content = args[0]
            # Add 2 spaces padding between text and scrollbar
            if not content.plain.endswith("  "):
                content = Text.assemble(content, "  ")
            args = (content,) + args[1:]
        super().write(*args, **kwargs)