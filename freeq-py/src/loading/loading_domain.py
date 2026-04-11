# 🟢 GREEN: Loading Domain (IU-3affebce) / Lazy Domain
# Description: Implements lazy loading and virtualization with 6 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Lazy loading of messages
#   2. Virtual scrolling
#   3. Load indicators
#   4. Progressive loading
#   5. Cache management for loaded content
#   6. Loading state tracking

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set, Callable, Any
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class LoadState(Enum):
    """Loading state for items."""
    NOT_LOADED = auto()
    LOADING = auto()
    LOADED = auto()
    ERROR = auto()
    CACHED = auto()


@dataclass
class LoadProgress:
    """Progress information for loading operation."""
    total: int = 0
    loaded: int = 0
    percentage: float = 0.0
    stage: str = ""
    message: str = ""
    start_time: Optional[datetime] = None
    estimated_time_remaining: Optional[float] = None


@dataclass
class VirtualItem:
    """Item in virtual list."""
    id: str
    state: LoadState = LoadState.NOT_LOADED
    height: int = 20  # Estimated height in rows
    data: Optional[Any] = None
    load_error: Optional[str] = None
    loaded_at: Optional[datetime] = None


@dataclass
class VirtualViewport:
    """Viewport into virtual list."""
    start_index: int = 0
    end_index: int = 0
    total_height: int = 0
    visible_height: int = 24
    scroll_offset: int = 0


@dataclass
class Loading:
    """Loading/Lazy domain entity."""
    id: str
    items: Dict[str, VirtualItem] = field(default_factory=dict)
    item_order: List[str] = field(default_factory=list)
    viewport: VirtualViewport = field(default_factory=VirtualViewport)
    progress: LoadProgress = field(default_factory=LoadProgress)
    batch_size: int = 50
    cache_size: int = 200
    loading_queue: List[str] = field(default_factory=list)
    loaded_ids: Set[str] = field(default_factory=set)
    is_loading: bool = False
    cancel_requested: bool = False
    error: Optional[str] = None


# === LAZY LOADING ===

def process(item: Loading) -> Loading:
    """Process loading state and update progress.
    
    Recalculates loading percentage and viewport.
    """
    total = len(item.items)
    loaded = sum(1 for i in item.items.values() if i.state == LoadState.LOADED)
    percentage = (loaded / total * 100) if total > 0 else 0.0
    
    # Calculate viewport
    visible_count = item.viewport.visible_height // 20  # Assume 20px per item
    end = min(item.viewport.start_index + visible_count, total)
    
    new_progress = LoadProgress(
        total=total,
        loaded=loaded,
        percentage=percentage,
        stage=item.progress.stage,
        message=item.progress.message,
        start_time=item.progress.start_time,
        estimated_time_remaining=item.progress.estimated_time_remaining
    )
    
    new_viewport = VirtualViewport(
        start_index=item.viewport.start_index,
        end_index=end,
        total_height=total * 20,
        visible_height=item.viewport.visible_height,
        scroll_offset=item.viewport.scroll_offset
    )
    
    return Loading(
        id=item.id,
        items=item.items,
        item_order=item.item_order,
        viewport=new_viewport,
        progress=new_progress,
        batch_size=item.batch_size,
        cache_size=item.cache_size,
        loading_queue=item.loading_queue.copy(),
        loaded_ids=item.loaded_ids.copy(),
        is_loading=item.is_loading,
        cancel_requested=item.cancel_requested,
        error=item.error
    )


def add_item(loading: Loading, item_id: str, height: int = 20) -> Loading:
    """Add an item to be lazy loaded."""
    if item_id in loading.items:
        return loading
    
    new_items = dict(loading.items)
    new_items[item_id] = VirtualItem(id=item_id, height=height)
    
    new_order = loading.item_order.copy()
    new_order.append(item_id)
    
    return Loading(
        id=loading.id,
        items=new_items,
        item_order=new_order,
        viewport=loading.viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=loading.loading_queue.copy(),
        loaded_ids=loading.loaded_ids.copy(),
        is_loading=loading.is_loading,
        cancel_requested=loading.cancel_requested,
        error=loading.error
    )


def mark_loading(loading: Loading, item_id: str) -> Loading:
    """Mark an item as currently loading."""
    if item_id not in loading.items:
        return loading
    
    new_items = dict(loading.items)
    item = new_items[item_id]
    new_items[item_id] = VirtualItem(
        id=item.id,
        state=LoadState.LOADING,
        height=item.height,
        data=item.data,
        load_error=item.load_error,
        loaded_at=item.loaded_at
    )
    
    new_queue = loading.loading_queue.copy()
    if item_id not in new_queue:
        new_queue.append(item_id)
    
    return Loading(
        id=loading.id,
        items=new_items,
        item_order=loading.item_order,
        viewport=loading.viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=new_queue,
        loaded_ids=loading.loaded_ids.copy(),
        is_loading=True,
        cancel_requested=loading.cancel_requested,
        error=loading.error
    )


def mark_loaded(loading: Loading, item_id: str, data: Any) -> Loading:
    """Mark an item as loaded with data."""
    if item_id not in loading.items:
        return loading
    
    new_items = dict(loading.items)
    item = new_items[item_id]
    new_items[item_id] = VirtualItem(
        id=item.id,
        state=LoadState.LOADED,
        height=item.height,
        data=data,
        load_error=None,
        loaded_at=datetime.now()
    )
    
    new_queue = [q for q in loading.loading_queue if q != item_id]
    new_loaded = loading.loaded_ids | {item_id}
    
    return Loading(
        id=loading.id,
        items=new_items,
        item_order=loading.item_order,
        viewport=loading.viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=new_queue,
        loaded_ids=new_loaded,
        is_loading=len(new_queue) > 0,
        cancel_requested=loading.cancel_requested,
        error=loading.error
    )


def mark_error(loading: Loading, item_id: str, error: str) -> Loading:
    """Mark an item as failed to load."""
    if item_id not in loading.items:
        return loading
    
    new_items = dict(loading.items)
    item = new_items[item_id]
    new_items[item_id] = VirtualItem(
        id=item.id,
        state=LoadState.ERROR,
        height=item.height,
        data=item.data,
        load_error=error,
        loaded_at=item.loaded_at
    )
    
    new_queue = [q for q in loading.loading_queue if q != item_id]
    
    return Loading(
        id=loading.id,
        items=new_items,
        item_order=loading.item_order,
        viewport=loading.viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=new_queue,
        loaded_ids=loading.loaded_ids.copy(),
        is_loading=len(new_queue) > 0,
        cancel_requested=loading.cancel_requested,
        error=loading.error
    )


def scroll_to(loading: Loading, offset: int) -> Loading:
    """Scroll to offset and update viewport."""
    visible_count = loading.viewport.visible_height // 20
    start = offset // 20
    end = min(start + visible_count, len(loading.item_order))
    
    new_viewport = VirtualViewport(
        start_index=start,
        end_index=end,
        total_height=len(loading.item_order) * 20,
        visible_height=loading.viewport.visible_height,
        scroll_offset=offset
    )
    
    # Queue visible items for loading
    new_queue = loading.loading_queue.copy()
    for i in range(start, end):
        if i < len(loading.item_order):
            item_id = loading.item_order[i]
            item = loading.items.get(item_id)
            if item and item.state == LoadState.NOT_LOADED and item_id not in new_queue:
                new_queue.append(item_id)
    
    return Loading(
        id=loading.id,
        items=loading.items,
        item_order=loading.item_order,
        viewport=new_viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=new_queue,
        loaded_ids=loading.loaded_ids.copy(),
        is_loading=len(new_queue) > 0 or loading.is_loading,
        cancel_requested=loading.cancel_requested,
        error=loading.error
    )


def get_visible_items(loading: Loading) -> List[str]:
    """Get list of visible item IDs in viewport."""
    return [
        loading.item_order[i]
        for i in range(loading.viewport.start_index, loading.viewport.end_index)
        if i < len(loading.item_order)
    ]


def get_items_to_load(loading: Loading) -> List[str]:
    """Get next batch of items to load."""
    return loading.loading_queue[:loading.batch_size]


def clear_cache(loading: Loading) -> Loading:
    """Clear loaded data from items outside viewport (LRU)."""
    new_items = {}
    visible = set(get_visible_items(loading))
    
    for item_id, item in loading.items.items():
        if item_id in visible or item.state != LoadState.LOADED:
            new_items[item_id] = item
        else:
            # Convert back to NOT_LOADED to free memory
            new_items[item_id] = VirtualItem(
                id=item.id,
                state=LoadState.NOT_LOADED,
                height=item.height,
                data=None,  # Free data
                load_error=item.load_error,
                loaded_at=None
            )
    
    return Loading(
        id=loading.id,
        items=new_items,
        item_order=loading.item_order,
        viewport=loading.viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=loading.loading_queue.copy(),
        loaded_ids=visible,  # Keep only visible as loaded
        is_loading=loading.is_loading,
        cancel_requested=loading.cancel_requested,
        error=loading.error
    )


def cancel_loading(loading: Loading) -> Loading:
    """Request cancellation of loading operations."""
    return Loading(
        id=loading.id,
        items=loading.items,
        item_order=loading.item_order,
        viewport=loading.viewport,
        progress=loading.progress,
        batch_size=loading.batch_size,
        cache_size=loading.cache_size,
        loading_queue=[],  # Clear queue
        loaded_ids=loading.loaded_ids.copy(),
        is_loading=False,
        cancel_requested=True,
        error=loading.error
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "3affebce0717f6f97919809262fd74942c974ef94c2aecc9283decb114b78072",
    "name": "Loading Domain",
    "risk_tier": "high",
}
