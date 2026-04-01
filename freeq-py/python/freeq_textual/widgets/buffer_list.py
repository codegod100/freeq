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
        _dbg(f"BufferList.update_buffers: clearing {len(list(self.children))} items, adding {len(buffers)} new items")
        
        self.clear()
        for buffer in buffers:
            label = buffer.name
            if buffer.unread:
                label = f"{label} ({buffer.unread})"
            item = ListItem(Static(label), name=buffer.name)
            if buffer.name == active:
                item.add_class("active")
            self.append(item)
            _dbg(f"BufferList.update_buffers: added item '{label}' (active={buffer.name == active})")
        
        _dbg(f"BufferList.update_buffers: done, total children={len(list(self.children))}")