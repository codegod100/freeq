"""BufferList widget - sidebar showing list of buffers (channels and DMs)."""

from textual.widgets import ListView, ListItem, Static


class BufferList(ListView):
    """Sidebar widget showing list of buffers (channels and DMs)."""
    
    DEFAULT_CSS = """
    BufferList {
        width: 15%;
        min-width: 14;
        max-width: 24;
    }
    """

    def update_buffers(self, buffers: list, active: str) -> None:
        """Update the buffer list with current buffers and mark active one."""
        self.clear()
        for buffer in buffers:
            label = buffer.name
            if buffer.unread:
                label = f"{label} ({buffer.unread})"
            item = ListItem(Static(label), name=buffer.name)
            if buffer.name == active:
                item.add_class("active")
            self.append(item)