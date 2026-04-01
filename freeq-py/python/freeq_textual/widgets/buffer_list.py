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
        
        # PROVABLE BUG: clear() and remove_items() both fail on Textual ListView
        # See: previous INVARIANT VIOLATION logs showing 16 items instead of 8
        # 
        # SOLUTION: Sync instead of clear/recreate
        # - Get current items by name
        # - Add new items that don't exist
        # - Remove items no longer in buffers
        # - Update active state on all
        
        current_items = {item.name: item for item in self.children if hasattr(item, 'name')}
        new_buffer_names = {b.name for b in buffers}
        
        _dbg(f"BufferList.update_buffers: syncing {len(current_items)} current vs {len(buffers)} new")
        
        # Remove items no longer in buffers (work backwards to avoid index issues)
        for name, item in list(current_items.items()):
            if name not in new_buffer_names:
                _dbg(f"BufferList.update_buffers: removing '{name}' (no longer in buffers)")
                item.remove()
        
        # Add new items or update existing
        for buffer in buffers:
            label = buffer.name
            if buffer.unread:
                label = f"{label} ({buffer.unread})"
            
            if buffer.name in current_items:
                # Update existing item label and active state
                item = current_items[buffer.name]
                static = item.query_one(Static)
                static.update(label)
                if buffer.name == active:
                    item.add_class("active")
                else:
                    item.remove_class("active")
                _dbg(f"BufferList.update_buffers: updated '{label}' (active={buffer.name == active})")
            else:
                # Create new item
                item = ListItem(Static(label), name=buffer.name)
                if buffer.name == active:
                    item.add_class("active")
                self.append(item)
                _dbg(f"BufferList.update_buffers: added '{label}' (active={buffer.name == active})")
        
        final_count = len(list(self.children))
        _dbg(f"BufferList.update_buffers: done, total children={final_count}")