"""BufferList widget - sidebar showing list of buffers (channels and DMs).

WE'RE ALL FRIENDS HERE! This widget is registered in components/all.py

DESIGN PRINCIPLE: Components manage their OWN state!
BAD: Global state like app.active_buffer - gets stale, causes bugs
GOOD: Component handles selection, emits Selected message with buffer name

WHY GLOBAL STATE IS BAD:
- Gets out of sync when component unmounts
- Multiple instances fight over same variable
- Hard to debug - who set it? when? where?
- Component can't be reused independently

FRIENDS DON'T LET FRIENDS USE GLOBAL STATE!

BUG HISTORY (proved by debug.py logging):
2026-03-31: INVARIANT VIOLATION: BufferList child count mismatch: expected 8, got 16
- Root cause: ListView.clear() doesn't remove children, only clears selection state
- Fix: Explicit child.remove() loop in update_buffers()
- See: debug.py DOCUMENTATION REQUIREMENT for logging trail
"""

from textual.widgets import ListView, ListItem, Static
from ..components.builtins import AutoLogMixin


class BufferList(AutoLogMixin, ListView):
    """Sidebar widget showing list of buffers (channels and DMs).
    
    REGRESSION FIX: Changed from 15% to fixed width 20
    - Mixing percentages with 1fr in Horizontal caused layout conflicts
    - When MessagesPanel uses 1fr, percentage-based siblings can cause 1fr to calc as 0
    - Fixed width allows proper fractional space calculation
    """
    
    DEFAULT_CSS = """
    BufferList {
        width: 20;
        min-width: 14;
        max-width: 24;
        height: 1fr;
    }
    """

    def update_buffers(self, buffers: list, active: str) -> None:
        """Update the buffer list with current buffers and mark active one."""
        from .debug import _dbg
        
        pre_clear_count = len(list(self.children))
        _dbg(f"BufferList.update_buffers: clearing {pre_clear_count} items, adding {len(buffers)} new items")
        
        # BUG PROVED BY LOG: INVARIANT VIOLATION: BufferList child count mismatch: expected 8, got 16
        # ListView.clear() and child.remove() don't work - Textual manages ListView children specially
        # Need to use ListView.remove_items() method (added in PR #4384)
        if self.children:
            indices = list(range(len(self.children)))
            self.remove_items(indices)
        
        # Force immediate removal by clearing internal state
        self._nodes._nodes.clear() if hasattr(self, '_nodes') else None
        
        post_clear_count = len(list(self.children))
        _dbg(f"BufferList.update_buffers: after clear, have {post_clear_count} items (expected 0)")
        
        for buffer in buffers:
            label = buffer.name
            if buffer.unread:
                label = f"{label} ({buffer.unread})"
            item = ListItem(Static(label), name=buffer.name)
            if buffer.name == active:
                item.add_class("active")
            self.append(item)
            _dbg(f"BufferList.update_buffers: added item '{label}' (active={buffer.name == active})")
        
        final_count = len(list(self.children))
        _dbg(f"BufferList.update_buffers: done, total children={final_count}")