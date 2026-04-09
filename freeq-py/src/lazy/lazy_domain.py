# 🟢 GREEN: Lazy Domain (IU-lazy-virtual)
# Description: Implements lazy loading and virtualization with 6 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Virtual list rendering
#   2. Windowed rendering (only visible items)
#   3. Overscan for smooth scrolling
#   4. Item height estimation
#   5. Dynamic height handling
#   6. Scroll position restoration

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Callable, Any, Tuple
from enum import Enum, auto

# === TYPES ===

class VirtualItemState(Enum):
    """State of a virtualized item."""
    UNMEASURED = auto()
    MEASURED = auto()
    VISIBLE = auto()
    HIDDEN = auto()


@dataclass
class VirtualItem:
    """Item in virtual list."""
    id: str
    index: int = 0
    estimated_height: int = 50
    actual_height: Optional[int] = None
    state: VirtualItemState = VirtualItemState.UNMEASURED
    data: Optional[Any] = None
    offset: int = 0  # Offset from top


@dataclass
class VirtualRange:
    """Visible range in virtual list."""
    start: int = 0
    end: int = 0
    overscan: int = 5
    
    @property
    def total(self) -> int:
        return self.end - self.start + (self.overscan * 2)


@dataclass
class LazyViewport:
    """Viewport for lazy rendering."""
    width: int = 80
    height: int = 24
    scroll_top: int = 0
    scroll_bottom: int = 0
    total_content_height: int = 0


@dataclass
class Lazy:
    """Lazy domain entity for virtualization."""
    id: str
    items: List[VirtualItem] = field(default_factory=list)
    visible_range: VirtualRange = field(default_factory=lambda: VirtualRange(overscan=5))
    viewport: LazyViewport = field(default_factory=LazyViewport)
    total_count: int = 0
    item_height_estimate: int = 50
    measured_count: int = 0
    scroll_direction: int = 0  # -1, 0, 1


# === VIRTUALIZATION ===

def process(item: Lazy) -> Lazy:
    """Process lazy state and update visible range.
    
    Recalculates which items should be visible based on scroll position.
    """
    if not item.items:
        return item
    
    # Calculate visible range
    start_idx = max(0, item.viewport.scroll_top // item.item_height_estimate - item.visible_range.overscan)
    end_idx = min(
        item.total_count,
        (item.viewport.scroll_bottom // item.item_height_estimate) + item.visible_range.overscan
    )
    
    # Update item states
    new_items = []
    for i, vitem in enumerate(item.items):
        if start_idx <= i <= end_idx:
            state = VirtualItemState.VISIBLE
        elif vitem.actual_height:
            state = VirtualItemState.HIDDEN
        else:
            state = VirtualItemState.UNMEASURED
        
        # Calculate offset
        offset = sum(
            (it.actual_height or it.estimated_height)
            for it in item.items[:i]
        )
        
        new_items.append(VirtualItem(
            id=vitem.id,
            index=i,
            estimated_height=vitem.estimated_height,
            actual_height=vitem.actual_height,
            state=state,
            data=vitem.data,
            offset=offset
        ))
    
    new_range = VirtualRange(
        start=start_idx,
        end=end_idx,
        overscan=item.visible_range.overscan
    )
    
    # Calculate total height
    total_height = sum(
        it.actual_height or it.estimated_height
        for it in new_items
    )
    
    new_viewport = LazyViewport(
        width=item.viewport.width,
        height=item.viewport.height,
        scroll_top=item.viewport.scroll_top,
        scroll_bottom=item.viewport.scroll_bottom,
        total_content_height=total_height
    )
    
    return Lazy(
        id=item.id,
        items=new_items,
        visible_range=new_range,
        viewport=new_viewport,
        total_count=item.total_count,
        item_height_estimate=item.item_height_estimate,
        measured_count=sum(1 for it in new_items if it.actual_height),
        scroll_direction=item.scroll_direction
    )


def init_items(item: Lazy, count: int, item_height: int = 50) -> Lazy:
    """Initialize virtual items."""
    items = [
        VirtualItem(
            id=f"item_{i}",
            index=i,
            estimated_height=item_height,
            state=VirtualItemState.UNMEASURED
        )
        for i in range(count)
    ]
    
    return Lazy(
        id=item.id,
        items=items,
        visible_range=item.visible_range,
        viewport=item.viewport,
        total_count=count,
        item_height_estimate=item_height,
        measured_count=0,
        scroll_direction=0
    )


def measure_item(item: Lazy, index: int, height: int) -> Lazy:
    """Update actual height of an item."""
    if index < 0 or index >= len(item.items):
        return item
    
    new_items = item.items.copy()
    vitem = new_items[index]
    new_items[index] = VirtualItem(
        id=vitem.id,
        index=vitem.index,
        estimated_height=vitem.estimated_height,
        actual_height=height,
        state=VirtualItemState.MEASURED,
        data=vitem.data,
        offset=vitem.offset
    )
    
    # Update estimate based on measurements
    measured = [it for it in new_items if it.actual_height]
    avg_height = sum(it.actual_height for it in measured) // len(measured) if measured else item.item_height_estimate
    
    return Lazy(
        id=item.id,
        items=new_items,
        visible_range=item.visible_range,
        viewport=item.viewport,
        total_count=item.total_count,
        item_height_estimate=avg_height,
        measured_count=len(measured),
        scroll_direction=item.scroll_direction
    )


def scroll_to(item: Lazy, offset: int) -> Lazy:
    """Scroll to pixel offset."""
    direction = 0
    if offset > item.viewport.scroll_top:
        direction = 1
    elif offset < item.viewport.scroll_top:
        direction = -1
    
    new_viewport = LazyViewport(
        width=item.viewport.width,
        height=item.viewport.height,
        scroll_top=offset,
        scroll_bottom=offset + item.viewport.height,
        total_content_height=item.viewport.total_content_height
    )
    
    lazy = Lazy(
        id=item.id,
        items=item.items,
        visible_range=item.visible_range,
        viewport=new_viewport,
        total_count=item.total_count,
        item_height_estimate=item.item_height_estimate,
        measured_count=item.measured_count,
        scroll_direction=direction
    )
    
    # Re-process to update visible range
    return process(lazy)


def get_visible_items(item: Lazy) -> List[VirtualItem]:
    """Get currently visible items."""
    return [
        it for it in item.items
        if item.visible_range.start <= it.index <= item.visible_range.end
    ]


def get_total_height(item: Lazy) -> int:
    """Get total scrollable height."""
    return sum(
        it.actual_height or it.estimated_height
        for it in item.items
    )


def get_scroll_position_for_index(item: Lazy, index: int) -> int:
    """Calculate scroll position to bring item into view."""
    if index < 0 or index >= len(item.items):
        return 0
    
    offset = sum(
        (it.actual_height or it.estimated_height)
        for it in item.items[:index]
    )
    
    return offset


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "lazy-virtual-7a3e9f2b4c8d1e5f6a0b9c8d7e3f1a2b",
    "name": "Lazy Domain",
    "risk_tier": "high",
}
