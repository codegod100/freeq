# 🟢 GREEN: Layout Domain (IU-0c915f52)
# Description: Implements layout management with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Panel size configuration
#   2. Responsive layout adjustments
#   3. Layout persistence
#   4. Layout presets

from dataclasses import dataclass, field
from typing import Optional, List, Dict
from enum import Enum, auto

# === TYPES ===

class LayoutPreset(Enum):
    """Predefined layout configurations."""
    COMPACT = "compact"      # Minimal sidebar, focus on chat
    BALANCED = "balanced"    # Equal panels
    WIDE_SIDEBAR = "wide_sidebar"  # Large sidebar for buffer list
    FULLSCREEN = "fullscreen"  # Chat only, no sidebars
    DEBUG = "debug"          # Include debug panel


@dataclass
class PanelSizes:
    """Size configuration for panels."""
    sidebar_width: int = 25  # Percentage
    main_width: int = 60     # Percentage
    userlist_width: int = 15 # Percentage
    input_height: int = 3    # Lines
    debug_height: int = 10   # Lines
    thread_width: int = 50   # Percentage


@dataclass
class Layout:
    """Layout domain entity."""
    id: str
    sizes: PanelSizes = field(default_factory=PanelSizes)
    preset: LayoutPreset = LayoutPreset.BALANCED
    responsive: bool = True
    min_width: int = 80    # Terminal columns
    min_height: int = 24   # Terminal rows
    saved: bool = False
    custom: bool = False
    name: Optional[str] = None


# === PRESET CONFIGURATIONS ===

PRESETS = {
    LayoutPreset.COMPACT: PanelSizes(
        sidebar_width=15,
        main_width=70,
        userlist_width=15,
        input_height=3,
        debug_height=10,
        thread_width=40
    ),
    LayoutPreset.BALANCED: PanelSizes(
        sidebar_width=25,
        main_width=60,
        userlist_width=15,
        input_height=3,
        debug_height=10,
        thread_width=50
    ),
    LayoutPreset.WIDE_SIDEBAR: PanelSizes(
        sidebar_width=35,
        main_width=50,
        userlist_width=15,
        input_height=3,
        debug_height=10,
        thread_width=50
    ),
    LayoutPreset.FULLSCREEN: PanelSizes(
        sidebar_width=0,
        main_width=100,
        userlist_width=0,
        input_height=3,
        debug_height=0,
        thread_width=50
    ),
    LayoutPreset.DEBUG: PanelSizes(
        sidebar_width=20,
        main_width=50,
        userlist_width=15,
        input_height=3,
        debug_height=15,
        thread_width=40
    ),
}


# === LAYOUT OPERATIONS ===

def process(item: Layout) -> Layout:
    """Process layout and normalize sizes."""
    sizes = item.sizes
    
    # Ensure percentages sum to 100
    total = sizes.sidebar_width + sizes.main_width + sizes.userlist_width
    if total != 100 and sizes.sidebar_width > 0:
        # Adjust main to fill remaining
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=100 - sizes.sidebar_width - sizes.userlist_width,
            userlist_width=sizes.userlist_width,
            input_height=sizes.input_height,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    
    return Layout(
        id=item.id,
        sizes=sizes,
        preset=item.preset,
        responsive=item.responsive,
        min_width=item.min_width,
        min_height=item.min_height,
        saved=item.saved,
        custom=item.custom,
        name=item.name
    )


def apply_preset(layout: Layout, preset: LayoutPreset) -> Layout:
    """Apply a layout preset."""
    sizes = PRESETS.get(preset, PRESETS[LayoutPreset.BALANCED])
    
    return Layout(
        id=layout.id,
        sizes=sizes,
        preset=preset,
        responsive=layout.responsive,
        min_width=layout.min_width,
        min_height=layout.min_height,
        saved=False,
        custom=False,
        name=preset.value
    )


def set_panel_size(layout: Layout, panel: str, size: int) -> Layout:
    """Set size for a specific panel."""
    sizes = layout.sizes
    
    if panel == "sidebar":
        sizes = PanelSizes(
            sidebar_width=size,
            main_width=sizes.main_width,
            userlist_width=sizes.userlist_width,
            input_height=sizes.input_height,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    elif panel == "main":
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=size,
            userlist_width=sizes.userlist_width,
            input_height=sizes.input_height,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    elif panel == "userlist":
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=sizes.main_width,
            userlist_width=size,
            input_height=sizes.input_height,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    elif panel == "input":
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=sizes.main_width,
            userlist_width=sizes.userlist_width,
            input_height=size,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    elif panel == "debug":
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=sizes.main_width,
            userlist_width=sizes.userlist_width,
            input_height=sizes.input_height,
            debug_height=size,
            thread_width=sizes.thread_width
        )
    
    return Layout(
        id=layout.id,
        sizes=sizes,
        preset=LayoutPreset.CUSTOM if layout.preset != LayoutPreset.CUSTOM else layout.preset,
        responsive=layout.responsive,
        min_width=layout.min_width,
        min_height=layout.min_height,
        saved=False,
        custom=True,
        name=layout.name or "custom"
    )


def resize_for_terminal(layout: Layout, width: int, height: int) -> Layout:
    """Adjust layout for terminal size."""
    if not layout.responsive:
        return layout
    
    if width < layout.min_width or height < layout.min_height:
        # Use compact layout for small terminals
        return apply_preset(layout, LayoutPreset.COMPACT)
    
    # Use current layout - it's fine
    return layout


def toggle_panel(layout: Layout, panel: str) -> Layout:
    """Toggle visibility of a panel."""
    sizes = layout.sizes
    
    if panel == "sidebar":
        new_width = 0 if sizes.sidebar_width > 0 else 25
        sizes = PanelSizes(
            sidebar_width=new_width,
            main_width=100 - new_width - sizes.userlist_width,
            userlist_width=sizes.userlist_width,
            input_height=sizes.input_height,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    elif panel == "userlist":
        new_width = 0 if sizes.userlist_width > 0 else 15
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=100 - sizes.sidebar_width - new_width,
            userlist_width=new_width,
            input_height=sizes.input_height,
            debug_height=sizes.debug_height,
            thread_width=sizes.thread_width
        )
    elif panel == "debug":
        sizes = PanelSizes(
            sidebar_width=sizes.sidebar_width,
            main_width=sizes.main_width,
            userlist_width=sizes.userlist_width,
            input_height=sizes.input_height,
            debug_height=0 if sizes.debug_height > 0 else 10,
            thread_width=sizes.thread_width
        )
    
    return Layout(
        id=layout.id,
        sizes=sizes,
        preset=layout.preset,
        responsive=layout.responsive,
        min_width=layout.min_width,
        min_height=layout.min_height,
        saved=False,
        custom=True,
        name=layout.name
    )


def mark_saved(layout: Layout) -> Layout:
    """Mark layout as saved."""
    return Layout(
        id=layout.id,
        sizes=layout.sizes,
        preset=layout.preset,
        responsive=layout.responsive,
        min_width=layout.min_width,
        min_height=layout.min_height,
        saved=True,
        custom=layout.custom,
        name=layout.name
    )


def to_css_sizes(sizes: PanelSizes) -> Dict[str, str]:
    """Convert sizes to CSS-style percentages."""
    return {
        "sidebar": f"{sizes.sidebar_width}%",
        "main": f"{sizes.main_width}%",
        "userlist": f"{sizes.userlist_width}%",
        "input": f"{sizes.input_height}lh",
        "debug": f"{sizes.debug_height}lh",
        "thread": f"{sizes.thread_width}%",
    }


def create_default_layout(id: str = "default") -> Layout:
    """Create layout with default settings."""
    return Layout(
        id=id,
        sizes=PRESETS[LayoutPreset.BALANCED],
        preset=LayoutPreset.BALANCED,
        responsive=True,
        min_width=80,
        min_height=24,
        saved=False,
        custom=False,
        name="balanced"
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "0c915f528a7d5edb15812d226dc4984ccb9eaa505d76306167b009de1694ff0f",
    "name": "Layout Domain",
    "risk_tier": "low",
}
