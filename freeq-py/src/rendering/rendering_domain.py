# 🟢 GREEN: Rendering Domain (IU-076cfed2)
# Description: Implements message rendering pipelines with 4 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Render active buffer on switch
#   2. Message formatting pipeline
#   3. Color scheme application
#   4. Rendering optimization (dirty regions)

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set, Tuple
from enum import Enum, auto

# === TYPES ===

class RenderStage(Enum):
    """Rendering pipeline stages."""
    SOURCE = "source"
    PARSE = "parse"
    TRANSFORM = "transform"
    FORMAT = "format"
    OUTPUT = "output"


@dataclass
class RenderStyle:
    """Style definition for rendering."""
    color: Optional[str] = None
    background: Optional[str] = None
    bold: bool = False
    italic: bool = False
    underline: bool = False
    strikethrough: bool = False
    blink: bool = False
    reverse: bool = False


@dataclass
class RenderedLine:
    """A single rendered line."""
    text: str
    styles: List[Tuple[int, int, RenderStyle]] = field(default_factory=list)
    is_dirty: bool = True
    line_number: int = 0


@dataclass
class RenderContext:
    """Context for rendering operations."""
    width: int = 80
    height: int = 24
    theme: str = "dark"
    timestamp_format: str = "%H:%M"
    nick_column_width: int = 16
    show_joins_parts: bool = True
    show_nick_changes: bool = True
    show_timestamps: bool = True
    color_scheme: Dict[str, str] = field(default_factory=dict)


@dataclass
class Rendering:
    """Rendering domain entity."""
    id: str
    context: RenderContext = field(default_factory=RenderContext)
    lines: List[RenderedLine] = field(default_factory=list)
    dirty_regions: List[Tuple[int, int]] = field(default_factory=list)
    visible_range: Tuple[int, int] = (0, 0)
    buffer_id: Optional[str] = None
    total_lines: int = 0
    cached_hash: Optional[str] = None
    stage: RenderStage = RenderStage.SOURCE


# === RENDERING PIPELINE ===

def process(item: Rendering) -> Rendering:
    """Process rendering state and recompute dirty regions.
    
    Updates visible range and marks lines for re-rendering.
    """
    # Compute visible range
    start = item.visible_range[0]
    end = min(start + item.context.height, item.total_lines)
    
    # Mark lines in visible range as dirty
    new_lines = []
    for i, line in enumerate(item.lines):
        new_line = RenderedLine(
            text=line.text,
            styles=line.styles,
            is_dirty=start <= i <= end,
            line_number=i
        )
        new_lines.append(new_line)
    
    # Compute dirty regions
    dirty = [(start, end)] if start < end else []
    
    return Rendering(
        id=item.id,
        context=item.context,
        lines=new_lines,
        dirty_regions=dirty,
        visible_range=(start, end),
        buffer_id=item.buffer_id,
        total_lines=item.total_lines,
        cached_hash=item.cached_hash,
        stage=item.stage
    )


def set_buffer(rendering: Rendering, buffer_id: str, total_lines: int) -> Rendering:
    """Set active buffer for rendering."""
    return Rendering(
        id=rendering.id,
        context=rendering.context,
        lines=[],  # Will be repopulated
        dirty_regions=[(0, rendering.context.height)],
        visible_range=(0, rendering.context.height),
        buffer_id=buffer_id,
        total_lines=total_lines,
        cached_hash=None,  # Force re-render
        stage=RenderStage.SOURCE
    )


def scroll_to(rendering: Rendering, line: int) -> Rendering:
    """Scroll to specific line number."""
    max_start = max(0, rendering.total_lines - rendering.context.height)
    new_start = max(0, min(line, max_start))
    new_end = min(new_start + rendering.context.height, rendering.total_lines)
    
    return Rendering(
        id=rendering.id,
        context=rendering.context,
        lines=rendering.lines,
        dirty_regions=[(new_start, new_end)],
        visible_range=(new_start, new_end),
        buffer_id=rendering.buffer_id,
        total_lines=rendering.total_lines,
        cached_hash=None,
        stage=rendering.stage
    )


def add_line(rendering: Rendering, text: str, styles: List[Tuple[int, int, RenderStyle]] = None) -> Rendering:
    """Add a new line to render."""
    new_lines = rendering.lines.copy()
    new_lines.append(RenderedLine(
        text=text,
        styles=styles or [],
        is_dirty=True,
        line_number=len(new_lines)
    ))
    
    new_total = rendering.total_lines + 1
    
    return Rendering(
        id=rendering.id,
        context=rendering.context,
        lines=new_lines,
        dirty_regions=rendering.dirty_regions + [(new_total - 1, new_total)],
        visible_range=rendering.visible_range,
        buffer_id=rendering.buffer_id,
        total_lines=new_total,
        cached_hash=None,
        stage=rendering.stage
    )


def clear(rendering: Rendering) -> Rendering:
    """Clear all rendered content."""
    return Rendering(
        id=rendering.id,
        context=rendering.context,
        lines=[],
        dirty_regions=[],
        visible_range=(0, 0),
        buffer_id=None,
        total_lines=0,
        cached_hash=None,
        stage=RenderStage.SOURCE
    )


def set_context(rendering: Rendering, context: RenderContext) -> Rendering:
    """Update rendering context."""
    return Rendering(
        id=rendering.id,
        context=context,
        lines=rendering.lines,
        dirty_regions=[(0, rendering.total_lines)],
        visible_range=rendering.visible_range,
        buffer_id=rendering.buffer_id,
        total_lines=rendering.total_lines,
        cached_hash=None,  # Force re-render
        stage=rendering.stage
    )


def format_timestamp(timestamp: str, context: RenderContext) -> str:
    """Format timestamp according to context."""
    if not context.show_timestamps:
        return ""
    return timestamp


def format_nickname(nick: str, width: int, context: RenderContext) -> str:
    """Format nickname to fixed width."""
    if len(nick) > width - 2:
        nick = nick[:width-3] + ">"
    return f"{nick:>{width}}"


def apply_color_scheme(text: str, color_key: str, context: RenderContext) -> str:
    """Apply color from scheme to text."""
    color = context.color_scheme.get(color_key, "default")
    return f"[{color}]{text}[/{color}]"


def create_default_rendering(id: str = "default", width: int = 80, height: int = 24) -> Rendering:
    """Create rendering with default settings."""
    context = RenderContext(width=width, height=height)
    
    return Rendering(
        id=id,
        context=context,
        lines=[],
        dirty_regions=[],
        visible_range=(0, 0),
        buffer_id=None,
        total_lines=0,
        cached_hash=None,
        stage=RenderStage.SOURCE
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "076cfed268e01e6b952d5153fdf4199aa4854068dc781126f80f9da6ad21e7da",
    "name": "Rendering Domain",
    "risk_tier": "high",
}
