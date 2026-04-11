# 🟢 GREEN: Displaying Domain (IU-ebf66c7a)
# Description: Implements display management with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Track visible range
#   2. Handle scroll position
#   3. Dirty region tracking
#   4. Display optimization

from dataclasses import dataclass, field
from typing import Optional, List, Tuple, Dict

# === TYPES ===

@dataclass
class DisplayRegion:
    """A region of the display."""
    top: int
    left: int
    bottom: int
    right: int
    is_dirty: bool = True


@dataclass
class Displaying:
    """Displaying domain entity."""
    id: str
    visible_range: Tuple[int, int] = (0, 0)  # start_line, end_line
    total_lines: int = 0
    rendered_lines: int = 0
    dirty_regions: List[DisplayRegion] = field(default_factory=list)
    cache_size: int = 0
    scroll_position: int = 0
    total_height: int = 0
    visible_height: int = 24
    optimizations_enabled: bool = True


# === DISPLAYING OPERATIONS ===

def process(item: Displaying) -> Displaying:
    """Process display state and compute visible range."""
    end = min(item.scroll_position + item.visible_height, item.total_lines)
    
    return Displaying(
        id=item.id,
        visible_range=(item.scroll_position, end),
        total_lines=item.total_lines,
        rendered_lines=item.rendered_lines,
        dirty_regions=item.dirty_regions.copy(),
        cache_size=item.cache_size,
        scroll_position=item.scroll_position,
        total_height=item.total_height,
        visible_height=item.visible_height,
        optimizations_enabled=item.optimizations_enabled
    )


def scroll_to(display: Displaying, position: int) -> Displaying:
    """Scroll to specific position."""
    max_scroll = max(0, display.total_lines - display.visible_height)
    new_pos = max(0, min(position, max_scroll))
    
    end = min(new_pos + display.visible_height, display.total_lines)
    
    # Mark new visible region as dirty
    dirty = display.dirty_regions.copy()
    dirty.append(DisplayRegion(new_pos, 0, end, 80, is_dirty=True))
    
    return Displaying(
        id=display.id,
        visible_range=(new_pos, end),
        total_lines=display.total_lines,
        rendered_lines=display.rendered_lines,
        dirty_regions=dirty,
        cache_size=display.cache_size,
        scroll_position=new_pos,
        total_height=display.total_height,
        visible_height=display.visible_height,
        optimizations_enabled=display.optimizations_enabled
    )


def scroll_by(display: Displaying, delta: int) -> Displaying:
    """Scroll by delta lines."""
    return scroll_to(display, display.scroll_position + delta)


def mark_dirty(display: Displaying, top: int, bottom: int) -> Displaying:
    """Mark a region as dirty."""
    dirty = display.dirty_regions.copy()
    dirty.append(DisplayRegion(top, 0, bottom, 80, is_dirty=True))
    
    return Displaying(
        id=display.id,
        visible_range=display.visible_range,
        total_lines=display.total_lines,
        rendered_lines=display.rendered_lines,
        dirty_regions=dirty,
        cache_size=display.cache_size,
        scroll_position=display.scroll_position,
        total_height=display.total_height,
        visible_height=display.visible_height,
        optimizations_enabled=display.optimizations_enabled
    )


def clear_dirty(display: Displaying) -> Displaying:
    """Clear all dirty regions."""
    return Displaying(
        id=display.id,
        visible_range=display.visible_range,
        total_lines=display.total_lines,
        rendered_lines=display.rendered_lines,
        dirty_regions=[],
        cache_size=display.cache_size,
        scroll_position=display.scroll_position,
        total_height=display.total_height,
        visible_height=display.visible_height,
        optimizations_enabled=display.optimizations_enabled
    )


def update_total_lines(display: Displaying, total: int) -> Displaying:
    """Update total line count."""
    # Adjust scroll if needed
    max_scroll = max(0, total - display.visible_height)
    new_scroll = min(display.scroll_position, max_scroll)
    
    return Displaying(
        id=display.id,
        visible_range=(new_scroll, min(new_scroll + display.visible_height, total)),
        total_lines=total,
        rendered_lines=display.rendered_lines,
        dirty_regions=display.dirty_regions,
        cache_size=display.cache_size,
        scroll_position=new_scroll,
        total_height=total * 20,  # Assume 20px per line
        visible_height=display.visible_height,
        optimizations_enabled=display.optimizations_enabled
    )


def resize(display: Displaying, width: int, height: int) -> Displaying:
    """Handle terminal resize."""
    end = min(display.scroll_position + height, display.total_lines)
    
    return Displaying(
        id=display.id,
        visible_range=(display.scroll_position, end),
        total_lines=display.total_lines,
        rendered_lines=display.rendered_lines,
        dirty_regions=[DisplayRegion(0, 0, display.total_lines, width, is_dirty=True)],
        cache_size=display.cache_size,
        scroll_position=display.scroll_position,
        total_height=display.total_height,
        visible_height=height,
        optimizations_enabled=display.optimizations_enabled
    )


def is_line_visible(display: Displaying, line: int) -> bool:
    """Check if a line is in the visible range."""
    return display.visible_range[0] <= line < display.visible_range[1]


def get_visible_lines(display: Displaying) -> Tuple[int, int]:
    """Get visible line range."""
    return display.visible_range


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "ebf66c7a5d4e3c2b1a0f9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8",
    "name": "Displaying Domain",
    "risk_tier": "low",
}
