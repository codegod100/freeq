"""Sum type slot framework - type-safe component slots.

Architecture:
- Each slot is a sum type (variant) that defines valid component types
- Slots are typed: ContextSlot can only hold context components
- Variants encode what can be loaded, preventing runtime errors
- Much type-safe. Very sum-type. So algebraic.

Example:
    class MessageActionsSlot(SumSlot):
        variants = [ContextMenu, EmojiPicker, ReplyPanel]
    
    # Only ContextMenu, EmojiPicker, or ReplyPanel can load
    slot.load(ContextMenu, msgid=msgid)
    slot.load(EmojiPicker)  # Type-safe variant
"""

from __future__ import annotations

from typing import Any, Callable, TypeVar, Generic, get_type_hints
from textual.containers import Vertical
from textual.widget import Widget
from textual.reactive import reactive

from ..widgets.debug import _dbg


T = TypeVar('T', bound=Widget)


class SlotVariant:
    """Base class for slot variants.
    
    Each variant defines:
    - The component class that can be loaded
    - How to construct it (args/kwargs mapping)
    - Lifecycle callbacks
    """
    
    def __init__(
        self,
        component_class: type[T],
        *args: Any,
        on_close: Callable[[], None] | None = None,
        **kwargs: Any
    ):
        self.component_class = component_class
        self.args = args
        self.kwargs = kwargs
        self.on_close = on_close
    
    def create(self) -> T:
        """Create the component instance."""
        return self.component_class(*self.args, **self.kwargs)
    
    def close(self) -> None:
        """Call close callback."""
        if self.on_close:
            self.on_close()


class SumSlot(Vertical, Generic[T]):
    """A sum-type slot that can hold one of several variant component types.
    
    The variants define what can be loaded. Type-safe at construction time.
    
    Usage:
        class MessageSlot(SumSlot[ContextMenu | EmojiPicker]):
            pass
        
        slot = MessageSlot()
        slot.load_variant(ContextMenu, msgid="abc123")
    """
    
    DEFAULT_CSS = """
    SumSlot {
        width: 1fr;
        height: auto;
        display: none;
    }
    
    SumSlot.occupied {
        display: block;
    }
    
    SumSlot.occupied.variant-context_menu {
        background: $surface-darken-1;
        border-top: solid $panel-lighten-2;
    }
    
    SumSlot.occupied.variant-emoji_picker {
        background: $success-darken-2;
        border-top: solid $success;
    }
    """
    
    has_content: reactive[bool] = reactive(False)
    current_variant: reactive[str | None] = reactive(None)
    
    def __init__(
        self,
        *args,
        allowed_variants: list[type[Widget]] | None = None,
        empty_height: int = 0,
        **kwargs
    ) -> None:
        super().__init__(*args, **kwargs)
        self._allowed_variants = allowed_variants or []
        self._empty_height = empty_height
        self._current_component: Widget | None = None
        self._current_variant_name: str | None = None
    
    def watch_has_content(self, has_content: bool) -> None:
        """Update CSS when content changes."""
        self.toggle_class(has_content, "occupied")
        if not has_content:
            self.styles.height = self._empty_height
            self.remove_class(f"variant-{self._current_variant_name}")
        else:
            self.styles.height = "auto"
            if self._current_variant_name:
                self.add_class(f"variant-{self._current_variant_name}")
    
    def watch_current_variant(self, variant: str | None) -> None:
        """Update variant CSS class."""
        # Remove old variant class
        for v in self._allowed_variants:
            self.remove_class(f"variant-{v.__name__.lower()}")
        # Add new variant class
        if variant:
            self.add_class(f"variant-{variant}")
    
    def load_variant(
        self,
        component_class: type[T],
        *args: Any,
        on_close: Callable[[], None] | None = None,
        **kwargs: Any
    ) -> T | None:
        """Load a specific variant component into the slot.
        
        Args:
            component_class: The component class to load (must be in allowed_variants)
            *args: Constructor args
            on_close: Callback when component closes
            **kwargs: Constructor kwargs
            
        Returns:
            The mounted component, or None if variant not allowed
        """
        # Type check: is this variant allowed?
        if self._allowed_variants and component_class not in self._allowed_variants:
            _dbg(f"SumSlot: variant {component_class.__name__} not allowed in {self.id}")
            _dbg(f"  allowed: {[v.__name__ for v in self._allowed_variants]}")
            return None
        
        # Clear existing
        self.clear()
        
        # Create variant wrapper
        variant = SlotVariant(component_class, *args, on_close=on_close, **kwargs)
        
        # Mount component
        try:
            component = variant.create()
            self._current_component = component
            self._current_variant_name = component_class.__name__.lower()
            self.mount(component)
            
            self.has_content = True
            self.current_variant = self._current_variant_name
            
            _dbg(f"SumSlot: loaded variant {component_class.__name__} into {self.id}")
            return component
            
        except Exception as e:
            _dbg(f"SumSlot: failed to create {component_class.__name__}: {e}")
            return None
    
    def load(
        self,
        component: Widget,
        variant_name: str | None = None,
        on_close: Callable[[], None] | None = None
    ) -> Widget | None:
        """Load a pre-constructed component (for dynamic loading).
        
        Less type-safe than load_variant() but more flexible.
        """
        self.clear()
        
        self._current_component = component
        self._current_variant_name = variant_name or type(component).__name__.lower()
        self.mount(component)
        
        self.has_content = True
        self.current_variant = self._current_variant_name
        
        # Store on_close for later
        self._on_close = on_close
        
        _dbg(f"SumSlot: loaded component {type(component).__name__} into {self.id}")
        return component
    
    def clear(self) -> None:
        """Clear the slot."""
        if self._current_component:
            # Call close callback
            if hasattr(self, '_on_close') and self._on_close:
                self._on_close()
            
            self._current_component.remove()
            self._current_component = None
            self._current_variant_name = None
            self.has_content = False
            self.current_variant = None
            
            _dbg(f"SumSlot: cleared {self.id}")
    
    @property
    def is_occupied(self) -> bool:
        return self._current_component is not None
    
    @property
    def current_component(self) -> Widget | None:
        return self._current_component
    
    @property
    def current_variant_name(self) -> str | None:
        return self._current_variant_name
    
    @property
    def allowed_variants(self) -> list[type[Widget]]:
        return self._allowed_variants.copy()


class MessageActionsSlot(SumSlot):
    """Slot for message actions - can hold ContextMenu, EmojiPicker, etc."""
    
    DEFAULT_CSS = """
    MessageActionsSlot {
        width: 1fr;
        height: auto;
        display: none;
    }
    
    MessageActionsSlot.occupied {
        display: block;
        background: $surface-darken-1;
        border-top: solid $panel-lighten-2;
        padding: 0 1;
    }
    """
    
    def __init__(self, *args, **kwargs) -> None:
        # Import here to avoid circular imports
        from ..components.builtins import ContextMenu
        from .emoji_picker import EmojiPicker
        
        super().__init__(*args, **kwargs)
        # Define allowed variants at initialization
        self._allowed_variants = [ContextMenu, EmojiPicker]


class ThreadPanelSlot(SumSlot):
    """Slot for thread panel - can hold ThreadPanel."""
    
    DEFAULT_CSS = """
    ThreadPanelSlot {
        width: 30%;
        min-width: 24;
        max-width: 50;
        height: 1fr;
        display: none;
    }
    
    ThreadPanelSlot.occupied {
        display: block;
        border: round $success;
        background: $surface;
        padding: 0 1;
    }
    """
    
    def __init__(self, *args, **kwargs) -> None:
        from ..widgets.thread_panel import ThreadPanel
        super().__init__(*args, **kwargs)
        self._allowed_variants = [ThreadPanel]


class ComposedSlotMessage(Vertical):
    """Message with typed slot below it.
    
    Uses SumSlot for type-safe slot operations.
    """
    
    DEFAULT_CSS = """
    ComposedSlotMessage {
        width: 1fr;
        height: auto;
    }
    
    ComposedSlotMessage .message-content {
        width: 1fr;
        height: auto;
    }
    """
    
    def __init__(
        self,
        content: Any,
        msgid: str | None = None,
        thread_root: str | None = None,
        slot_type: type[SumSlot] = MessageActionsSlot,
        **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self._content = content
        self._msgid = msgid
        self._thread_root = thread_root
        self._slot_type = slot_type
        self._actions_slot: SumSlot | None = None
    
    def compose(self):
        from textual.widgets import Static
        from rich.text import Text
        
        # Message content
        content_str = str(self._content) if isinstance(self._content, (str, Text)) else str(self._content)
        yield Static(content_str, classes="message-content")
        
        # Typed slot
        yield self._slot_type(id=f"slot-{self._msgid[:8] if self._msgid else 'none'}")
    
    def on_mount(self) -> None:
        try:
            self._actions_slot = self.query_one(SumSlot)
        except Exception:
            pass
    
    @property
    def actions_slot(self) -> SumSlot | None:
        return self._actions_slot
    
    @property
    def msgid(self) -> str | None:
        return self._msgid
    
    @property
    def thread_root(self) -> str | None:
        return self._thread_root


# Sum type slot manager for exclusive slot coordination
class SumSlotManager:
    """Global manager for sum-type slots.
    
    Ensures only one slot of a given type is active at a time.
    """
    
    def __init__(self) -> None:
        self._slots: dict[str, SumSlot] = {}
        self._active_by_type: dict[str, SumSlot] = {}
    
    def register(self, slot_id: str, slot: SumSlot) -> None:
        """Register a slot."""
        self._slots[slot_id] = slot
    
    def load_variant_exclusive(
        self,
        slot_id: str,
        component_class: type[T],
        *args: Any,
        **kwargs: Any
    ) -> T | None:
        """Load variant, clearing other slots of same type."""
        slot = self._slots.get(slot_id)
        if not slot:
            return None
        
        slot_type = type(slot).__name__
        
        # Clear other slots of same type
        if slot_type in self._active_by_type:
            other = self._active_by_type[slot_type]
            if other != slot:
                other.clear()
        
        # Load into this slot
        def on_close():
            if self._active_by_type.get(slot_type) == slot:
                self._active_by_type.pop(slot_type, None)
        
        component = slot.load_variant(component_class, *args, on_close=on_close, **kwargs)
        
        if component:
            self._active_by_type[slot_type] = slot
        
        return component
    
    def clear_all_of_type(self, slot_type: str) -> None:
        """Clear all slots of a specific type."""
        for slot_id, slot in self._slots.items():
            if type(slot).__name__ == slot_type and slot.is_occupied:
                slot.clear()
        self._active_by_type.pop(slot_type, None)
    
    def get_slot(self, slot_id: str) -> SumSlot | None:
        return self._slots.get(slot_id)


# Global sum slot manager
sum_slot_manager = SumSlotManager()
