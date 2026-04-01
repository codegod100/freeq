"""Finite slot type system - components are variants of slot classes.

Architecture:
- Fixed set of slot classes (InlineActions, SidePanel, Overlay, Content)
- Components register as valid variants for specific slot types
- Type-safe loading: slot.load_variant(ComponentClass)
- Each slot type has distinct visual behavior and positioning

Such finite. Much variant. Very type-safe.
"""

from __future__ import annotations

from typing import Any, Callable, TypeVar, Generic
from textual.containers import Vertical, Horizontal
from textual.widget import Widget
from textual.reactive import reactive

from ..widgets.debug import _dbg


T = TypeVar('T', bound=Widget)


class SlotType:
    """Base class for slot types - defines visual behavior and allowed variants."""
    
    # Override in subclasses
    allowed_variants: list[type[Widget]] = []
    default_css: str = ""
    container_class = Vertical


class InlineActionsSlotType(SlotType):
    """Slot type for inline action bars below messages.
    
    Visual: Thin horizontal bar, below content, expands message height
    """
    
    default_css = """
    InlineActionsSlot {
        width: 1fr;
        height: auto;
        display: none;
    }
    
    InlineActionsSlot.occupied {
        display: block;
        background: $surface-darken-1;
        border-top: solid $panel-lighten-2;
        padding: 0 1;
    }
    """
    
    container_class = Horizontal
    
    def __init__(self) -> None:
        # Import variants
        from ..components.builtins import ContextMenu
        from .emoji_picker import EmojiPicker
        
        self.allowed_variants = [ContextMenu, EmojiPicker]


class SidePanelSlotType(SlotType):
    """Slot type for side panels (right-side overlays).
    
    Visual: Fixed width panel, right side, overlays content
    """
    
    default_css = """
    SidePanelSlot {
        width: 30%;
        min-width: 24;
        max-width: 50;
        height: 1fr;
        display: none;
    }
    
    SidePanelSlot.occupied {
        display: block;
        border: round $primary;
        background: $surface;
        padding: 0 1;
    }
    
    SidePanelSlot.occupied.variant-thread_panel {
        border: round $success;
    }
    
    SidePanelSlot.occupied.variant-reply_panel {
        border: round $primary;
    }
    """
    
    container_class = Vertical
    
    def __init__(self) -> None:
        from ..widgets.thread_panel import ThreadPanel
        from ..components.builtins import ReplyPanel
        
        self.allowed_variants = [ThreadPanel, ReplyPanel]


class OverlaySlotType(SlotType):
    """Slot type for floating overlays/modals.
    
    Visual: Floating, centered or positioned, modal behavior
    """
    
    default_css = """
    OverlaySlot {
        layer: overlay;
        width: auto;
        height: auto;
        display: none;
    }
    
    OverlaySlot.occupied {
        display: block;
    }
    """
    
    container_class = Vertical
    
    def __init__(self) -> None:
        # Overlays can hold modals, dialogs, etc.
        self.allowed_variants = []  # Populated dynamically


class ContentSlotType(SlotType):
    """Slot type for main content areas.
    
    Visual: Full-width, scrollable, main content
    """
    
    default_css = """
    ContentSlot {
        width: 1fr;
        height: 1fr;
        display: none;
    }
    
    ContentSlot.occupied {
        display: block;
    }
    """
    
    container_class = Vertical
    
    def __init__(self) -> None:
        # Messages, system notices, etc.
        from ..widgets.thread_panel import ThreadMessage
        self.allowed_variants = [ThreadMessage]  # Base content types


# Map slot type names to classes
SLOT_TYPES: dict[str, type[SlotType]] = {
    'inline_actions': InlineActionsSlotType,
    'side_panel': SidePanelSlotType,
    'overlay': OverlaySlotType,
    'content': ContentSlotType,
}


class TypedSlot(Widget, Generic[T]):
    """A slot instance of a specific slot type.
    
    Each slot is an instance of a slot type, and can hold variants
    allowed by that slot type.
    
    Usage:
        slot = TypedSlot('inline_actions', id='msg-123-actions')
        slot.load_variant(ContextMenu, msgid='abc123')
    """
    
    has_content: reactive[bool] = reactive(False)
    current_variant: reactive[str | None] = reactive(None)
    
    def __init__(
        self,
        slot_type_name: str,
        *args,
        empty_height: int = 0,
        **kwargs
    ) -> None:
        # Get slot type class
        slot_type_class = SLOT_TYPES.get(slot_type_name)
        if not slot_type_class:
            raise ValueError(f"Unknown slot type: {slot_type_name}")
        
        self._slot_type = slot_type_class()
        self._slot_type_name = slot_type_name
        self._empty_height = empty_height
        self._current_component: Widget | None = None
        self._current_variant_name: str | None = None
        
        # Use container class from slot type
        container_class = self._slot_type.container_class
        
        # Initialize container
        super().__init__(*args, **kwargs)
        
        # Apply slot type CSS
        self._base_styles = self._slot_type.default_css
    
    def compose(self):
        """Compose the slot container."""
        # Empty slot - components mounted dynamically via load_variant()
        if False:
            yield  # Make this a generator, but yield nothing initially
    
    def watch_has_content(self, has_content: bool) -> None:
        """Update CSS when content changes."""
        if has_content:
            self.add_class("occupied")
        else:
            self.remove_class("occupied")
        if not has_content:
            self.styles.height = self._empty_height
            if self._current_variant_name:
                self.remove_class(f"variant-{self._current_variant_name}")
        else:
            self.styles.height = "auto"
            if self._current_variant_name:
                self.add_class(f"variant-{self._current_variant_name}")
    
    def watch_current_variant(self, variant: str | None) -> None:
        """Update variant CSS class."""
        # Remove old variant classes
        for allowed in self._slot_type.allowed_variants:
            self.remove_class(f"variant-{allowed.__name__.lower()}")
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
        """Load a component variant into this slot."""
        from .debug import check_slot_operation, validate_invariant
        
        # Type check
        if component_class not in self._slot_type.allowed_variants:
            check_slot_operation(self, component_class, success=False)
            return None
        
        # Pre-condition: check state
        validate_invariant(
            self.is_mounted,
            f"slot {self.id} not mounted during load_variant",
            slot=self.id,
            component=component_class.__name__
        )
        
        # Clear existing
        self.clear()
        
        # Create and mount
        try:
            component = component_class(*args, **kwargs)
            self._current_component = component
            self._current_variant_name = component_class.__name__.lower()
            
            self.mount(component)
            
            self.has_content = True
            self.current_variant = self._current_variant_name
            self._on_close = on_close
            
            check_slot_operation(self, component_class, success=True)
            return component
            
        except Exception as e:
            _dbg(f"TypedSlot: failed to create {component_class.__name__}: {e}")
            check_slot_operation(self, component_class, success=False)
            return None
    
    def clear(self) -> None:
        """Clear the slot."""
        if self._current_component:
            if hasattr(self, '_on_close') and self._on_close:
                self._on_close()
            
            self._current_component.remove()
            self._current_component = None
            self._current_variant_name = None
            self.has_content = False
            self.current_variant = None
            
            _dbg(f"TypedSlot: cleared {self._slot_type_name}")
    
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
    def slot_type_name(self) -> str:
        return self._slot_type_name
    
    @property
    def allowed_variants(self) -> list[type[Widget]]:
        return self._slot_type.allowed_variants.copy()


class InlineActionsSlot(TypedSlot):
    """Convenience constructor for inline actions slots."""
    
    def __init__(self, *args, **kwargs) -> None:
        super().__init__('inline_actions', *args, **kwargs)


class SidePanelSlot(TypedSlot):
    """Convenience constructor for side panel slots."""
    
    def __init__(self, *args, **kwargs) -> None:
        super().__init__('side_panel', *args, **kwargs)


class OverlaySlot(TypedSlot):
    """Convenience constructor for overlay slots."""
    
    def __init__(self, *args, **kwargs) -> None:
        super().__init__('overlay', *args, **kwargs)


class ContentSlot(TypedSlot):
    """Convenience constructor for content slots."""
    
    def __init__(self, *args, **kwargs) -> None:
        super().__init__('content', *args, **kwargs)


class SlotVariantRegistry:
    """Registry for slot type variant mappings.
    
    Allows dynamic registration of component variants to slot types.
    """
    
    _variants: dict[str, list[type[Widget]]] = {
        'inline_actions': [],
        'side_panel': [],
        'overlay': [],
        'content': [],
    }
    
    @classmethod
    def register(cls, slot_type: str, component_class: type[Widget]) -> None:
        """Register a component as valid variant for slot type."""
        if slot_type not in cls._variants:
            raise ValueError(f"Unknown slot type: {slot_type}")
        
        if component_class not in cls._variants[slot_type]:
            cls._variants[slot_type].append(component_class)
            _dbg(f"SlotVariantRegistry: registered {component_class.__name__} for {slot_type}")
    
    @classmethod
    def get_variants(cls, slot_type: str) -> list[type[Widget]]:
        """Get all registered variants for slot type."""
        return cls._variants.get(slot_type, [])
    
    @classmethod
    def is_valid(cls, slot_type: str, component_class: type[Widget]) -> bool:
        """Check if component is valid variant for slot type."""
        return component_class in cls._variants.get(slot_type, [])


# Global slot coordinator
class SlotCoordinator:
    """Coordinates slots across the app.
    
    - Ensures only one slot per type is active (optional)
    - Manages slot IDs
    - Handles exclusive slot loading
    """
    
    def __init__(self) -> None:
        self._slots: dict[str, TypedSlot] = {}
        self._active_by_type: dict[str, TypedSlot] = {}
    
    def register(self, slot_id: str, slot: TypedSlot) -> None:
        """Register a slot with coordinator."""
        self._slots[slot_id] = slot
    
    def load_exclusive(
        self,
        slot_id: str,
        component_class: type[T],
        *args: Any,
        **kwargs: Any
    ) -> T | None:
        """Load component, clearing other slots of same type."""
        slot = self._slots.get(slot_id)
        if not slot:
            return None
        
        slot_type = slot.slot_type_name
        
        # Clear other slots of this type
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
    
    def clear_type(self, slot_type: str) -> None:
        """Clear all slots of a specific type."""
        for slot in self._slots.values():
            if slot.slot_type_name == slot_type and slot.is_occupied:
                slot.clear()
        self._active_by_type.pop(slot_type, None)
    
    def get_slot(self, slot_id: str) -> TypedSlot | None:
        return self._slots.get(slot_id)


# Global coordinator instance
slot_coordinator = SlotCoordinator()
