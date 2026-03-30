"""ScrollableLog widget - RichLog with thumb-only scrollbar."""

from textual.message import Message
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

    class Clicked(Message):
        """Emitted when the log is clicked."""
        def __init__(self, y: int, scroll_y: float) -> None:
            self.y = y
            self.scroll_y = scroll_y
            super().__init__()

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        # CRITICAL: Line-associated state MUST live on the component, not in app dicts.
        # When the thread panel opens:
        # 1. OLD MessagesPanel is removed (with its ScrollableLog)
        # 2. NEW MessagesPanelWithThread is mounted (with NEW ScrollableLog at narrower width)
        # 3. Lines re-wrap at the new width -> different line count
        # 4. If thread_roots lived in app._rendered_line_threads dict, it would have STALE indices
        # 5. The NEW component should track its OWN thread_roots as it renders
        #
        # BUG: Currently app stores _rendered_line_threads dict, which gets out of sync when
        #      component changes or width changes. Fix: move thread_roots tracking here.
        self._thread_roots: list[str | None] = []  # thread_root per rendered line
        self._location_lines: dict[str, int] = {}  # location -> line index
        # Pending locations: parallel to RichLog's _deferred_renders, one per write call
        # Each entry is the location string (or None for writes without location)
        # This keeps locations in sync with deferred render order
        self._pending_locations: list[str | None] = []
        # Pending thread_roots: same parallel tracking for thread_roots
        self._pending_thread_roots: list[str | None] = []
        # Pending scroll target (set by scroll_to_location before on_resize fires)
        self._pending_scroll_target: str | None = None

    def on_click(self, event) -> None:
        """Handle click and emit Clicked message."""
        _dbg(f"ScrollableLog.on_click: y={event.y} scroll_y={self.scroll_y}")
        self.post_message(self.Clicked(y=event.y, scroll_y=self.scroll_y))

    class ScrolledToTop(Message):
        """Emitted when user scrolls near the top (for infinite scroll)."""
        pass

    def on_scroll(self, event) -> None:
        """Detect when scrolled to top and emit ScrolledToTop for infinite scroll."""
        # When scroll_y is close to 0, we're at the top
        if self.scroll_y < 5:
            self.post_message(self.ScrolledToTop())

    def write(self, content, width: int | None = None, expand: bool = False, shrink: bool = True, scroll_end: bool | None = None, *, location: str = "", thread_root: str | None = None) -> "ScrollableLog":
        """Write content, tracking location and thread_root for later use.

        Args:
            content: Rich renderable or string
            width: Width to render (passed to RichLog)
            expand: Expand to widget width (passed to RichLog)
            shrink: Shrink to fit width (passed to RichLog)
            scroll_end: Auto-scroll to end (passed to RichLog)
            location: Optional location identifier (e.g., msgid) for scroll-to-message
            thread_root: Optional thread_root if this line is part of a thread
        
        DESIGN: thread_root MUST be tracked here, not in app dict.
        When width changes (thread panel opens), lines re-wrap and indices change.
        Only the component itself knows its actual rendered lines.
        """
        # Track for deferred renders - must add to pending even if empty
        # to keep indices in sync with _deferred_renders
        if not self._size_known:
            self._pending_locations.append(location or None)
            self._pending_thread_roots.append(thread_root)
            _dbg(f"ScrollableLog.write: DEFERRED location={location[:8] if location else 'None'}, thread_root={thread_root[:8] if thread_root else 'None'}, pending={len(self._pending_locations)}")

        before = len(self.lines)
        result = super().write(content, width=width, expand=expand, shrink=shrink, scroll_end=scroll_end)
        added = len(self.lines) - before

        # If render was NOT deferred, track now with correct line index
        if self._size_known:
            if location:
                if location not in self._location_lines:
                    self._location_lines[location] = before
                    _dbg(f"ScrollableLog.write: TRACKED location={location[:8]} -> line {before}")
            # Track thread_root for each line added (handles wrapping)
            if thread_root:
                for i in range(before, before + max(1, added)):
                    if i >= len(self._thread_roots):
                        self._thread_roots.extend([None] * (i - len(self._thread_roots) + 1))
                    self._thread_roots[i] = thread_root

        return result

    def clear(self) -> None:
        """Clear content and location tracking."""
        super().clear()
        self._thread_roots.clear()
        self._location_lines.clear()
        self._pending_locations.clear()
        self._pending_thread_roots.clear()

    def on_resize(self, event) -> None:
        """Process deferred renders and apply pending locations/thread_roots.

        RichLog defers writes until the widget is sized. When the resize event
        fires, RichLog processes the deferred renders. We need to apply our
        pending data to the correct line indices after processing.
        
        CRITICAL: This is where thread_roots get populated after width changes.
        When thread panel opens, width shrinks, lines re-wrap, and THIS method
        builds the correct thread_roots list for the new line count.
        """
        # Check if this is the first sizing
        if event.size.width and not self._size_known:
            # Size becomes known - RichLog will process deferred renders
            # Set flag first so our write() knows size is known
            self._size_known = True

            # Get the deferred renders and pending data
            deferred = list(self._deferred_renders)
            pending_locs = list(self._pending_locations)
            pending_roots = list(self._pending_thread_roots)

            _dbg(f"ScrollableLog.on_resize: processing {len(deferred)} deferred renders, {len(pending_locs)} locations, {len(pending_roots)} roots")

            # Clear the queues (RichLog does this internally too)
            self._deferred_renders.clear()

            # Process each deferred render, tracking line indices
            for i, (dr, loc, root) in enumerate(zip(deferred, pending_locs, pending_roots)):
                before = len(self.lines)
                # Write the deferred render (dr is tuple of content, width, expand, shrink, scroll_end)
                super().write(*dr)
                after = len(self.lines)
                added = after - before
                # Track location if present
                if loc:
                    if loc not in self._location_lines:
                        self._location_lines[loc] = before
                        _dbg(f"  [{i}] location={loc[:8]} -> line {before} (added {added} lines)")
                # Track thread_root for all lines produced by this render
                if root:
                    for line_idx in range(before, after):
                        if line_idx >= len(self._thread_roots):
                            self._thread_roots.extend([None] * (line_idx - len(self._thread_roots) + 1))
                        self._thread_roots[line_idx] = root

            # Clear pending
            self._pending_locations.clear()
            self._pending_thread_roots.clear()
            _dbg(f"ScrollableLog.on_resize: done, {len(self._location_lines)} locations, {len(self._thread_roots)} thread_roots")
            
            # Check for pending scroll target
            if self._pending_scroll_target:
                target = self._pending_scroll_target
                self._pending_scroll_target = None
                line_index = self._location_lines.get(target)
                if line_index is not None:
                    _dbg(f"  on_resize: pending scroll to {target[:8]} at line {line_index}")
                    self.app.call_later(self._do_scroll, line_index)
        else:
            # Already sized - just let RichLog handle it
            super().on_resize(event)

    def thread_root_at(self, line_index: int) -> str | None:
        """Get thread_root at a line index, or None if not a thread line.
        
        This is the CORRECT way to check for thread_roots - querying the component
        directly instead of using stale data from an app dict.
        """
        if 0 <= line_index < len(self._thread_roots):
            return self._thread_roots[line_index]
        return None


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
        # If deferred renders exist, set pending target and let on_resize handle it
        if self._deferred_renders and not self._size_known:
            _dbg(f"scroll_to_location({location[:8]}): deferred renders exist, setting pending target")
            self._pending_scroll_target = location
            return True  # Will scroll when on_resize fires
        
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