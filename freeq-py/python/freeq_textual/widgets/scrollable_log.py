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
    
    LOCATION SCROLLING:
    
    When opening a thread panel, we want the main log to scroll to show the thread root message.
    This is done by tracking the msgid of each message and storing which line it appears on.
    
    Flow:
    1. App calls log.write(line, width=w, location=msgid) for each rendered line
    2. ScrollableLog stores _location_lines[msgid] = line_index
    3. When thread opens, app sets _scroll_mode="message" and _scroll_target_msgid=thread_root
    4. _render_active_buffer() calls log.scroll_to_location(msgid)
    5. scroll_to_location() scrolls to make that line visible
    
    This allows clicking a reply indicator to open the thread AND scroll to the original message.
    
    NOTE: Terminal mouse selection works for copying text - hold and drag to select,
    then use terminal's copy shortcut (usually Ctrl+Shift+C or Cmd+C).
    """

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._location_lines: dict[str, int] = {}  # location -> line index
    
    def write(self, content, width: int | None = None, expand: bool = False, shrink: bool = True, scroll_end: bool | None = None, *, location: str = "") -> "ScrollableLog":
        """Write content, optionally tracking location for later scrolling.
        
        Args:
            content: Rich renderable or string
            width: Width to render (passed to RichLog)
            expand: Expand to widget width (passed to RichLog)
            shrink: Shrink to fit width (passed to RichLog)
            scroll_end: Auto-scroll to end (passed to RichLog)
            location: Optional location identifier (e.g., msgid) to scroll to later
        """
        before = len(self.lines)
        result = super().write(content, width=width, expand=expand, shrink=shrink, scroll_end=scroll_end)
        added = len(self.lines) - before
        
        if location:
            # Track first line where this location appears
            if location not in self._location_lines:
                self._location_lines[location] = before
        
        
        return result
    
    def clear(self) -> None:
        """Clear content and location tracking."""
        super().clear()
        self._location_lines.clear()
    
    
    def scroll_to_location(self, location: str) -> bool:
        """Scroll to make the line with given location visible.
        
        Called when opening a thread to scroll to the thread root message.
        The location is the msgid of the message to scroll to.
        
        Args:
            location: Location identifier (e.g., msgid)
        
        Returns:
            True if location found and scrolled, False otherwise
        """
        line_index = self._location_lines.get(location)
        if line_index is None:
            return False
        
        # Scroll to the line (line_index is 0-based row in lines list)
        # RichLog stores lines as Strip objects, we need to scroll to virtual y
        self.scroll_to(y=line_index, animate=False)
        return True
    
    def location_line(self, location: str) -> int | None:
        """Get the line index for a location, or None if not found."""
        return self._location_lines.get(location)

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