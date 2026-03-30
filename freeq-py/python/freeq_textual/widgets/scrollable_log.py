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

    def on_resize(self, event) -> None:
        """Process deferred renders and apply pending locations.

        RichLog defers writes until the widget is sized. When the resize event
        fires, RichLog processes the deferred renders. We need to apply our
        pending locations to the correct line indices after processing.
        """
        # Check if this is the first sizing
        if event.size.width and not self._size_known:
            # Size becomes known - RichLog will process deferred renders
            # Set flag first so our write() knows size is known
            self._size_known = True

            # Get the deferred renders and pending locations
            deferred = list(self._deferred_renders)
            pending = list(self._pending_locations)

            _dbg(f"ScrollableLog.on_resize: processing {len(deferred)} deferred renders, {len(pending)} pending locations")

            # Clear the queues (RichLog does this internally too)
            self._deferred_renders.clear()

            # Process each deferred render, tracking line indices
            for i, (dr, loc) in enumerate(zip(deferred, pending)):
                before = len(self.lines)
                # Write the deferred render (dr is tuple of content, width, expand, shrink, scroll_end)
                super().write(*dr)
                after = len(self.lines)
                # Track location if present
                if loc:
                    if loc not in self._location_lines:
                        self._location_lines[loc] = before
                        _dbg(f"  [{i}] location={loc[:8]} -> line {before} (added {after - before} lines)")

            # Clear pending locations
            self._pending_locations.clear()
            _dbg(f"ScrollableLog.on_resize: done, {len(self._location_lines)} locations tracked")
        else:
            # Already sized - just let RichLog handle it
            super().on_resize(event)


    def scroll_to_location(self, location: str) -> bool:
        """Scroll to make the line with given location visible.
        
        Called when opening a thread to scroll to the thread root message.
        The location is the msgid of the message to scroll to.
        
        DEFERRED RENDERS FIX:
        RichLog defers ALL writes until the widget has been sized (_size_known=True).
        When opening a thread panel, the new ScrollableLog hasn't been sized yet, so
        all our write() calls get queued in _deferred_renders. This means self.lines
        is empty when we try to scroll - nothing has actually been rendered.
        
        The on_resize handler processes deferred renders and applies pending locations.
        But if scroll_to_location is called before resize fires, we process them here.
        
        Args:
            location: Location identifier (e.g., msgid)
        
        Returns:
            True if location found and scrolled, False otherwise
        """
        # Process any deferred renders first (fallback if on_resize hasn't fired yet)
        if self._deferred_renders and self.size.width:
            _dbg(f"scroll_to_location: processing deferred renders (fallback)")
            # Manually process like on_resize does
            self._size_known = True
            deferred = list(self._deferred_renders)
            pending = list(self._pending_locations)
            self._deferred_renders.clear()
            self._pending_locations.clear()
            
            for dr, loc in zip(deferred, pending):
                before = len(self.lines)
                super().write(*dr)
                if loc and loc not in self._location_lines:
                    self._location_lines[loc] = before
        

        line_index = self._location_lines.get(location)
        if line_index is None:
            _dbg(f"scroll_to_location({location[:8]}): NOT FOUND in {len(self._location_lines)} locations")
            _dbg(f"  available locations: {list(self._location_lines.keys())[:5]}...")
            return False

        _dbg(f"scroll_to_location({location[:8]}): found at line {line_index}, total lines={len(self.lines)}, virtual_size={self.virtual_size}")
        _dbg(f"  scrolling to y={line_index}")

        # Scroll to the line (line_index is 0-based row in lines list)
        # RichLog stores lines as Strip objects, we need to scroll to virtual y
        # Use call_later to ensure the widget has rendered before scrolling
        self.app.call_later(self._do_scroll, line_index)
        return True

    def _do_scroll(self, y: int) -> None:
        """Actually perform the scroll after render is complete."""
        self.scroll_to(y=y, animate=False)
        _dbg(f"  _do_scroll(y={y}): scroll_y={self.scroll_y}, virtual_size={self.virtual_size}")

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