"""ScrollableLog widget - RichLog with thumb-only scrollbar."""

from textual.widgets import RichLog

from .debug import _dbg


class ScrollableLog(RichLog):
    """A RichLog with thumb-only scrollbar (transparent track) and no horizontal scroll.
    
    HORIZONTAL SCROLL:
    We hide the horizontal scrollbar (overflow-x: hidden) because we handle line wrapping
    explicitly via the width parameter in write(). All content should fit within the container
    width, so there's no need for horizontal scrolling.
    
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
        # Pending locations: parallel to RichLog's _deferred_renders, one per write call
        # Each entry is the location string (or None for writes without location)
        # This keeps locations in sync with deferred render order
        self._pending_locations: list[str | None] = []
    
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
        # Track location for deferred renders - must add to pending even if empty
        # to keep indices in sync with _deferred_renders
        if not self._size_known:
            self._pending_locations.append(location or None)
            _dbg(f"ScrollableLog.write: DEFERRED location={location[:8] if location else 'None'}, pending_count={len(self._pending_locations)}")
        
        before = len(self.lines)
        result = super().write(content, width=width, expand=expand, shrink=shrink, scroll_end=scroll_end)
        added = len(self.lines) - before
        
        # If render was NOT deferred, track location now with correct line index
        if location and self._size_known:
            if location not in self._location_lines:
                self._location_lines[location] = before
                _dbg(f"ScrollableLog.write: TRACKED location={location[:8]} -> line {before}")
        
        
        return result
    
    def clear(self) -> None:
        """Clear content and location tracking."""
        super().clear()
        self._location_lines.clear()
        self._pending_locations.clear()
    
    
    def scroll_to_location(self, location: str) -> bool:
        """Scroll to make the line with given location visible.
        
        Called when opening a thread to scroll to the thread root message.
        The location is the msgid of the message to scroll to.
        
        DEFERRED RENDERS FIX:
        RichLog defers ALL writes until the widget has been sized (_size_known=True).
        When opening a thread panel, the new ScrollableLog hasn't been sized yet, so
        all our write() calls get queued in _deferred_renders. This means self.lines
        is empty when we try to scroll - nothing has actually been rendered.
        
        LOCATION TRACKING FIX:
        When writes are deferred, we can't track the line index (it's always 0).
        So we store locations in _pending_locations during deferred writes, then
        apply them with correct line indices when processing deferred renders.
        
        Args:
            location: Location identifier (e.g., msgid)
        
        Returns:
            True if location found and scrolled, False otherwise
        """
        # Process any deferred renders first (happens when log hasn't been sized yet)
        if self._deferred_renders:
            _dbg(f"scroll_to_location: processing {len(self._deferred_renders)} deferred renders, {len(self._pending_locations)} pending locations")
            _dbg(f"  pending_locations = {self._pending_locations[:5]}... (showing first 5)")
            # Force size to be known so deferred renders process
            if not self._size_known and self.size.width:
                self._size_known = True
            # Process deferred renders, applying pending locations (parallel lists)
            pending_idx = 0
            deferred = list(self._deferred_renders)
            self._deferred_renders.clear()
            for i, dr in enumerate(deferred):
                before = len(self.lines)
                _dbg(f"  deferred[{i}]: before={before}, dr has {len(dr)} elements")
                self.write(*dr)  # This will add lines now that _size_known is True
                after = len(self.lines)
                # Apply pending location if present (None for writes without location)
                if pending_idx < len(self._pending_locations):
                    loc = self._pending_locations[pending_idx]
                    _dbg(f"  pending[{pending_idx}] = {loc!r}, lines went {before} -> {after}")
                    if loc and loc not in self._location_lines:
                        self._location_lines[loc] = before
                        _dbg(f"    mapped {loc[:8]} -> line {before}")
                    pending_idx += 1
            self._pending_locations.clear()
        
        line_index = self._location_lines.get(location)
        if line_index is None:
            _dbg(f"scroll_to_location({location[:8]}): NOT FOUND in {len(self._location_lines)} locations")
            _dbg(f"  available locations: {list(self._location_lines.keys())[:5]}...")
            return False
        
        _dbg(f"scroll_to_location({location[:8]}): found at line {line_index}, total lines={len(self.lines)}, virtual_size={self.virtual_size}")
        _dbg(f"  scrolling to y={line_index}")
        
        # Scroll to the line (line_index is 0-based row in lines list)
        # RichLog stores lines as Strip objects, we need to scroll to virtual y
        self.scroll_to(y=line_index, animate=False)
        _dbg(f"  after scroll: scroll_y={self.scroll_y}")
        return True
    
    def location_line(self, location: str) -> int | None:
        """Get the line index for a location, or None if not found."""
        return self._location_lines.get(location)

    DEFAULT_CSS = """
    ScrollableLog {
        border: none;
        overflow-x: hidden;
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