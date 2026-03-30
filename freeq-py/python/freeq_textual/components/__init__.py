"""Modular component framework for freeq-textual.

This framework allows swapping out UI components without changing core app logic.
Components are registered by name and can be selected via config.

USAGE:
    from freeq_textual.components import ComponentRegistry
    
    # Register a custom reply panel
    @ComponentRegistry.register('reply_panel')
    class MyReplyPanel(Widget):
        ...
    
    # Or use built-in components
    from freeq_textual.components import get_component
    ReplyPanel = get_component('reply_panel')
"""

from typing import Protocol, Type, Any
from textual.widget import Widget


class ReplyPanelInterface(Protocol):
    """Protocol for reply panel components."""
    reply_to_msgid: str
    
    class ReplySent:
        text: str
        reply_to_msgid: str
        target: str


class ContextMenuInterface(Protocol):
    """Protocol for context menu components."""
    _msgid: str | None
    
    class Selected:
        action: str
        msgid: str | None


class ComponentRegistry:
    """Registry for swappable UI components.
    
    DO NOT just delete components because they look broken.
    Register replacements here instead.
    """
    
    _components: dict[str, type[Widget]] = {}
    
    @classmethod
    def register(cls, name: str) -> callable:
        """Decorator to register a component implementation.
        
        @ComponentRegistry.register('reply_panel')
        class MyReplyPanel(Widget):
            ...
        """
        def decorator(widget_class: type[Widget]) -> type[Widget]:
            cls._components[name] = widget_class
            return widget_class
        return decorator
    
    @classmethod
    def get(cls, name: str) -> type[Widget]:
        """Get a component by name. Raises KeyError if not found."""
        if name not in cls._components:
            raise KeyError(
                f"Component '{name}' not registered. "
                f"Available: {list(cls._components.keys())}. "
                f"DO NOT just delete this - register a replacement."
            )
        return cls._components[name]
    
    @classmethod
    def list(cls) -> list[str]:
        """List all registered component names."""
        return list(cls._components.keys())


def get_component(name: str) -> type[Widget]:
    """Get a component class by name."""
    return ComponentRegistry.get(name)


# Import built-in implementations to register them
from . import builtins  # noqa: F401