"""ScrollableLog widget - RichLog with thumb-only scrollbar."""

from textual.widgets import RichLog


class ScrollableLog(RichLog):
    """A RichLog with thumb-only scrollbar (transparent track).
    
    WRAPPING FIXES:
    
    1. RichLog.wrap defaults to False, which OVERRIDES Text.overflow settings.
       When wrap=False, RichLog forces no_wrap=True and overflow="ignore" on all Text objects.
       This breaks our Text(no_wrap=False, overflow="fold") wrapping for single long words.
       Solution: Pass wrap=True to RichLog (done in compose() of MessagesPanel* widgets).
    
    2. RichLog.write() needs explicit width parameter for correct wrapping.
       Without width, it measures the renderable and uses its natural width, which can exceed
       the container width and cause horizontal scrolling instead of wrapping.
       Solution: Pass width=log.size.width to write() calls.
    
    NOTE: Terminal mouse selection works for copying text - hold and drag to select,
    then use terminal's copy shortcut (usually Ctrl+Shift+C or Cmd+C).
    """

    DEFAULT_CSS = """
    ScrollableLog {
        border: none;
        overflow-x: auto;
        overflow-y: auto;
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