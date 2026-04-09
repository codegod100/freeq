# 🟢 GREEN: Tests for Lazy Domain
# Risk Tier: HIGH

import pytest
from lazy_domain import (
    _phoenix, Lazy, VirtualItem, VirtualRange, LazyViewport,
    VirtualItemState, process, init_items, measure_item, scroll_to,
    get_visible_items, get_total_height, get_scroll_position_for_index
)

# 🟢 GREEN: Traceability
def test_traceability():
    assert _phoenix is not None
    assert "lazy" in _phoenix["name"].lower()


# 🟢 GREEN: Initialization tests
def test_init_items():
    """Test initializing virtual items."""
    lazy = Lazy(id="test")
    result = init_items(lazy, count=100, item_height=50)
    
    assert len(result.items) == 100
    assert result.total_count == 100
    assert result.item_height_estimate == 50
    assert result.items[0].estimated_height == 50


# 🟢 GREEN: Process tests
def test_process_updates_visible_range():
    """Test that process updates visible range based on scroll."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=100, item_height=50)
    
    # Scroll to middle
    lazy = scroll_to(lazy, 500)
    
    # Should have visible items around position 500
    assert lazy.visible_range.start > 0
    assert lazy.visible_range.end > lazy.visible_range.start


def test_process_calculates_offsets():
    """Test that process calculates item offsets."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=10, item_height=50)
    lazy = measure_item(lazy, 0, 40)
    lazy = measure_item(lazy, 1, 60)
    lazy = process(lazy)
    
    # Item 1 should be at offset 40
    assert lazy.items[1].offset == 40
    # Item 2 should be at offset 40 + 60 = 100
    assert lazy.items[2].offset == 100


# 🟢 GREEN: Measurement tests
def test_measure_item():
    """Test measuring item height."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=10, item_height=50)
    
    result = measure_item(lazy, 0, 75)
    
    assert result.items[0].actual_height == 75
    assert result.items[0].state == VirtualItemState.MEASURED
    assert result.measured_count == 1


def test_measure_item_updates_estimate():
    """Test that measuring updates average height estimate."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=10, item_height=50)
    
    lazy = measure_item(lazy, 0, 100)
    lazy = measure_item(lazy, 1, 100)
    
    assert lazy.item_height_estimate == 100  # Average of measured heights


# 🟢 GREEN: Scroll tests
def test_scroll_to():
    """Test scrolling to offset."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=100, item_height=50)
    
    result = scroll_to(lazy, 250)
    
    assert result.viewport.scroll_top == 250
    assert result.viewport.scroll_bottom == 250 + result.viewport.height
    assert result.scroll_direction == 1  # Scrolled down


def test_scroll_direction_up():
    """Test scroll direction detection when scrolling up."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=100, item_height=50)
    lazy = scroll_to(lazy, 500)
    
    result = scroll_to(lazy, 250)
    
    assert result.scroll_direction == -1  # Scrolled up


# 🟢 GREEN: Visibility tests
def test_get_visible_items():
    """Test getting visible items."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=100, item_height=50)
    lazy = scroll_to(lazy, 0)  # At top
    
    visible = get_visible_items(lazy)
    
    # Should have items visible in viewport + overscan
    assert len(visible) > 0
    assert len(visible) <= lazy.visible_range.total


# 🟢 GREEN: Height calculation tests
def test_get_total_height():
    """Test total height calculation."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=10, item_height=50)
    
    height = get_total_height(lazy)
    
    assert height == 500  # 10 items * 50 height


def test_get_total_height_with_measurements():
    """Test height with some measured items."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=3, item_height=50)
    lazy = measure_item(lazy, 0, 100)
    
    height = get_total_height(lazy)
    
    assert height == 200  # 100 + 50 + 50


# 🟢 GREEN: Scroll position tests
def test_get_scroll_position_for_index():
    """Test calculating scroll position for item index."""
    lazy = Lazy(id="test")
    lazy = init_items(lazy, count=10, item_height=50)
    lazy = measure_item(lazy, 0, 100)
    lazy = measure_item(lazy, 1, 60)
    lazy = process(lazy)
    
    pos = get_scroll_position_for_index(lazy, 2)
    
    assert pos == 160  # 100 + 60


def test_process_transforms_input():
    """Ensure process creates new object (backwards compatibility)."""
    lazy = Lazy(id="123")
    lazy = init_items(lazy, count=10, item_height=50)
    result = process(lazy)
    assert result is not lazy
