# 🟢 GREEN: Component Domain (IU-8b046021)
# Description: Implements component registry with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Component registration
#   2. Component lifecycle
#   3. Component state management
#   4. Component dependencies

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Callable
from enum import Enum, auto

# === TYPES ===

class ComponentState(Enum):
    """Component lifecycle states."""
    UNINITIALIZED = auto()
    INITIALIZING = auto()
    READY = auto()
    ACTIVE = auto()
    SUSPENDED = auto()
    DESTROYING = auto()
    DESTROYED = auto()


@dataclass
class Component:
    """A single component."""
    id: str
    name: str
    state: ComponentState = ComponentState.UNINITIALIZED
    dependencies: List[str] = field(default_factory=list)
    dependents: List[str] = field(default_factory=list)
    state_data: Dict[str, Any] = field(default_factory=dict)
    init_fn: Optional[Callable] = None
    destroy_fn: Optional[Callable] = None


@dataclass
class ComponentDomain:
    """Component domain entity."""
    id: str
    components: Dict[str, Component] = field(default_factory=dict)
    active_components: List[str] = field(default_factory=list)
    initialization_order: List[str] = field(default_factory=list)


# === COMPONENT OPERATIONS ===

def process(item: ComponentDomain) -> ComponentDomain:
    """Process component domain state."""
    return ComponentDomain(
        id=item.id,
        components=dict(item.components),
        active_components=[c for c in item.active_components if c in item.components],
        initialization_order=item.initialization_order.copy()
    )


def register(
    domain: ComponentDomain,
    component_id: str,
    name: str,
    dependencies: List[str] = None,
    init_fn: Callable = None,
    destroy_fn: Callable = None
) -> ComponentDomain:
    """Register a new component."""
    new_components = dict(domain.components)
    new_components[component_id] = Component(
        id=component_id,
        name=name,
        state=ComponentState.UNINITIALIZED,
        dependencies=dependencies or [],
        dependents=[],
        init_fn=init_fn,
        destroy_fn=destroy_fn
    )
    
    # Update dependents on dependencies
    for dep_id in (dependencies or []):
        if dep_id in new_components:
            dep = new_components[dep_id]
            if component_id not in dep.dependents:
                new_components[dep_id] = Component(
                    id=dep.id,
                    name=dep.name,
                    state=dep.state,
                    dependencies=dep.dependencies,
                    dependents=dep.dependents + [component_id],
                    state_data=dep.state_data,
                    init_fn=dep.init_fn,
                    destroy_fn=dep.destroy_fn
                )
    
    return ComponentDomain(
        id=domain.id,
        components=new_components,
        active_components=domain.active_components.copy(),
        initialization_order=domain.initialization_order.copy()
    )


def initialize(domain: ComponentDomain, component_id: str) -> ComponentDomain:
    """Initialize a component."""
    if component_id not in domain.components:
        return domain
    
    new_components = dict(domain.components)
    comp = new_components[component_id]
    
    # Check dependencies are ready
    for dep_id in comp.dependencies:
        if dep_id in new_components:
            dep = new_components[dep_id]
            if dep.state != ComponentState.READY and dep.state != ComponentState.ACTIVE:
                # Dependency not ready, can't initialize
                return domain
    
    new_components[component_id] = Component(
        id=comp.id,
        name=comp.name,
        state=ComponentState.INITIALIZING,
        dependencies=comp.dependencies,
        dependents=comp.dependents,
        state_data=comp.state_data,
        init_fn=comp.init_fn,
        destroy_fn=comp.destroy_fn
    )
    
    return ComponentDomain(
        id=domain.id,
        components=new_components,
        active_components=domain.active_components.copy(),
        initialization_order=domain.initialization_order.copy()
    )


def mark_ready(domain: ComponentDomain, component_id: str) -> ComponentDomain:
    """Mark a component as ready."""
    if component_id not in domain.components:
        return domain
    
    new_components = dict(domain.components)
    comp = new_components[component_id]
    
    new_components[component_id] = Component(
        id=comp.id,
        name=comp.name,
        state=ComponentState.READY,
        dependencies=comp.dependencies,
        dependents=comp.dependents,
        state_data=comp.state_data,
        init_fn=comp.init_fn,
        destroy_fn=comp.destroy_fn
    )
    
    new_active = domain.active_components.copy()
    if component_id not in new_active:
        new_active.append(component_id)
    
    new_order = domain.initialization_order.copy()
    if component_id not in new_order:
        new_order.append(component_id)
    
    return ComponentDomain(
        id=domain.id,
        components=new_components,
        active_components=new_active,
        initialization_order=new_order
    )


def activate(domain: ComponentDomain, component_id: str) -> ComponentDomain:
    """Activate a component."""
    if component_id not in domain.components:
        return domain
    
    new_components = dict(domain.components)
    comp = new_components[component_id]
    
    if comp.state != ComponentState.READY:
        return domain
    
    new_components[component_id] = Component(
        id=comp.id,
        name=comp.name,
        state=ComponentState.ACTIVE,
        dependencies=comp.dependencies,
        dependents=comp.dependents,
        state_data=comp.state_data,
        init_fn=comp.init_fn,
        destroy_fn=comp.destroy_fn
    )
    
    return ComponentDomain(
        id=domain.id,
        components=new_components,
        active_components=domain.active_components.copy(),
        initialization_order=domain.initialization_order.copy()
    )


def deactivate(domain: ComponentDomain, component_id: str) -> ComponentDomain:
    """Deactivate a component."""
    if component_id not in domain.components:
        return domain
    
    new_components = dict(domain.components)
    comp = new_components[component_id]
    
    new_components[component_id] = Component(
        id=comp.id,
        name=comp.name,
        state=ComponentState.SUSPENDED,
        dependencies=comp.dependencies,
        dependents=comp.dependents,
        state_data=comp.state_data,
        init_fn=comp.init_fn,
        destroy_fn=comp.destroy_fn
    )
    
    new_active = [c for c in domain.active_components if c != component_id]
    
    return ComponentDomain(
        id=domain.id,
        components=new_components,
        active_components=new_active,
        initialization_order=domain.initialization_order.copy()
    )


def destroy(domain: ComponentDomain, component_id: str) -> ComponentDomain:
    """Destroy a component."""
    if component_id not in domain.components:
        return domain
    
    # Check no dependents
    comp = domain.components[component_id]
    if comp.dependents:
        # Can't destroy if there are dependents
        return domain
    
    new_components = dict(domain.components)
    del new_components[component_id]
    
    new_active = [c for c in domain.active_components if c != component_id]
    new_order = [c for c in domain.initialization_order if c != component_id]
    
    return ComponentDomain(
        id=domain.id,
        components=new_components,
        active_components=new_active,
        initialization_order=new_order
    )


def get_component_state(domain: ComponentDomain, component_id: str) -> Optional[ComponentState]:
    """Get state of a component."""
    if component_id in domain.components:
        return domain.components[component_id].state
    return None


def is_ready(domain: ComponentDomain, component_id: str) -> bool:
    """Check if a component is ready."""
    state = get_component_state(domain, component_id)
    return state in (ComponentState.READY, ComponentState.ACTIVE)


def get_initialization_order(domain: ComponentDomain) -> List[str]:
    """Get components in initialization order."""
    return domain.initialization_order.copy()


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "8b046021f3a9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3",
    "name": "Component Domain",
    "risk_tier": "low",
}
