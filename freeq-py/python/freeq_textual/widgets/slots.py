"""Slot-based component framework.

Architecture:
- Slots are containers that can hold one component at a time
- Components register themselves and can be loaded into slots
- Slots manage component lifecycle (mount/unmount)
- Such framework. Much reactive. Very slot.
"""

from typing import Any, Callable, Type
from textual.containers import Vertical
from textual.widget import Widget
from textual.reactive import reactive

from ..widgets.debug import _dbg


class Slot(Vertical):
    """A slot that can hold one component at a time.
    
    Slots provide:
    - Exclusive component hosting (one at a time)
    - Lifecycle management (mount/unmount callbacks)
    - Reactive content switching
    - Visual distinction when empty vs occupied
    
    Usage:
        # In compose()
        yield Slot(id="message-actions", empty_height=0)
        
        # Load component into slot
        slot.load_component('context_menu', msgid=msgid)
        
        # Clear slot
        slot.clear()
    """
    
    DEFAULT_CSS = """
    Slot {
        width: 1fr;
        height: auto;
        display: none;  /* Hidden when empty */
    }
    
    Slot.occupied {
        display: block;
        border-top: solid $panel-lighten-2;
        background: $surface-darken-1;
    }
    """
    
    # Reactive state - changes trigger CSS class updates
    has_content: reactive[bool] = reactive(False)
    
    def __init__(
        self,
        *args,
        empty_height: int = 0,
        on_load: Callable[[], None] | None = None,
        on_clear: Callable[[], None] | None = None,
        **kwargs
    ) -> None:
        super().__init__(*args, **kwargs)
        self._empty_height = empty_height
        self._on_load = on_load
        self._on_clear = on_clear
        self._current_component: Widget | None = None
        self._current_component_name: str | None = None
    
    def watch_has_content(self, has_content: bool) -> None:
        """Update CSS classes when content changes."""
        self.toggle_class(has_content, "occupied")
        if not has_content:
            self.styles.height = self._empty_height
        else:
            self.styles.height = "auto"
    
    def load_component(
        self,
        component_name: str,
        *args,
        on_close: Callable[[], None] | None = None,
        **kwargs
    ) -> Widget | None:
        """Load a component into this slot.
        
        Args:
            component_name: Registered component name
            *args: Positional args for component constructor
            on_close: Optional callback when component closes
            **kwargs: Keyword args for component constructor
            
        Returns:
            The mounted component widget, or None if failed
        """
        from . import ComponentRegistry
        
        # Get component class from registry
        component_class = ComponentRegistry._components.get(component_name)
        if not component_class:
            _dbg(f"Slot: component '{component_name}' not found in registry")
            return None
        
        # Clear existing first
        self.clear()
        
        # Create component instance
        try:
            # Merge on_close with kwargs if provided
            if on_close:
                kwargs['on_close'] = on_close
            
            component = component_class(*args, **kwargs)
        except Exception as e:
            _dbg(f"Slot: failed to create component '{component_name}': {e}")
            return None
        
        # Mount and track
        self._current_component = component
        self._current_component_name = component_name
        self.mount(component)
        self.has_content = True
        
        if self._on_load:
            self._on_load()
        
        _dbg(f"Slot: loaded '{component_name}' into {self.id}")
        return component
    
    def clear(self) -> None:
        """Clear the slot - remove current component."""
        if self._current_component:
            self._current_component.remove()
            self._current_component = None
            self._current_component_name = None
            self.has_content = False
            
            if self._on_clear:
                self._on_clear()
            
            _dbg(f"Slot: cleared {self.id}")
    
    def reload(self) -> Widget | None:
        """Reload current component (useful for refreshing)."""
        if self._current_component_name:
            return self.load_component(self._current_component_name)
        return None
    
    @property
    def is_occupied(self) -> bool:
        """Check if slot has a component."""
        return self._current_component is not None
    
    @property
    def current_component(self) -> Widget | None:
        """Get current component, if any."""
        return self._current_component
    
    @property
    def current_component_name(self) -> str | None:
        """Get name of current component, if any."""
        return self._current_component_name


class SlottedMessageItem(Vertical):
    """Message with a slot below it for actions.
    
    This combines MessageItem + Slot into a single unit:
    - message_area: displays the message
    - actions_slot: slot for loading components like ContextMenu
    
    Usage:
        item = SlottedMessageItem(content, msgid="abc123")
        
        # Load context menu into slot
        item.actions_slot.load_component('context_menu', msgid="abc123")
        
        # Clear when done
        item.actions_slot.clear()
    """
    
    DEFAULT_CSS = """
    SlottedMessageItem {
        width: 1fr;
        height: auto;
    }
    
    SlottedMessageItem .message-area {
        height: auto;
        width: 1fr;
    }
    
    SlottedMessageItem Slot {
        width: 1fr;
    }
    """
    
    def __init__(
        self,
        content: Any,
        msgid: str | None = None,
        thread_root: str | None = None,
        **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._content = content
        self._msgid = msgid
        self._thread_root = thread_root
        self._actions_slot: Slot | None = None
    
    def compose(self):
        from textual.widgets import Static
        from rich.text import Text
        
        # Message content
        if isinstance(self._content, str):
            yield Static(self._content, classes="message-area")
        elif isinstance(self._content, Text):
            yield Static(str(self._content), classes="message-area")
        else:
            yield Static(str(self._content), classes="message-area")
        
        # Actions slot (initially empty, hidden)
        yield Slot(
            id=f"slot-{self._msgid[:8] if self._msgid else 'none'}",
            empty_height=0,
            classes="actions-slot"
        )
    
    def on_mount(self) -> None:
        """Capture reference to slot after mount."""
        try:
            self._actions_slot = self.query_one(Slot)
        except Exception:
            pass
    
    @property
    def actions_slot(self) -> Slot | None:
        """Get the actions slot for this message."""
        return self._actions_slot
    
    @property
    def msgid(self) -> str | None:
        return self._msgid
    
    @property
    def thread_root(self) -> str | None:
        return self._thread_root


class SlotManager:
    """Global slot management for the app.
    
    Provides centralized slot tracking and exclusive slot behavior
    (only one slot active at a time across the entire app).
    """
    
    def __init__(self) -> None:
        self._slots: dict[str, Slot] = {}
        self._active_slot: Slot | None = None
    
    def register(self, slot_id: str, slot: Slot) -> None:
        """Register a slot with the manager."""
        self._slots[slot_id] = slot
    
    def load_exclusive(
        self,
        slot_id: str,
        component_name: str,
        *args,
        **kwargs
    ) -> Widget | None:
        """Load component into slot, clearing any other active slot.
        
        This ensures only one slot is occupied at a time app-wide.
        """
        slot = self._slots.get(slot_id)
        if not slot:
            _dbg(f"SlotManager: slot '{slot_id}' not found")
            return None
        
        # Clear any existing active slot
        if self._active_slot and self._active_slot != slot:
            self._active_slot.clear()
        
        # Load into new slot
        def on_close():
            self._active_slot = None
        
        kwargs['on_close'] = on_close
        component = slot.load_component(component_name, *args, **kwargs)
        
        if component:
            self._active_slot = slot
        
        return component
    
    def clear_active(self) -> None:
        """Clear whichever slot is currently active."""
        if self._active_slot:
            self._active_slot.clear()
            self._active_slot = None
    
    def get_slot(self, slot_id: str) -> Slot | None:
        """Get a registered slot by ID."""
        return self._slots.get(slot_id)
    
    @property
    def active_slot(self) -> Slot | None:
        """Get the currently active slot, if any."""
        return self._active_slot


# Global slot manager instance
slot_manager = SlotManager()
