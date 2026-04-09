# 🟢 GREEN: Raw Domain (IU-9cb0e851)
# Description: Implements raw IRC view with 2 requirements
# Risk Tier: LOW
# Requirements:
#   1. Display raw IRC protocol messages
#   2. Filter raw messages

from dataclasses import dataclass, field
from typing import Optional, List
from datetime import datetime

# === TYPES ===

@dataclass
class RawLine:
    """A single raw IRC line."""
    timestamp: datetime
    direction: str  # 'in' or 'out'
    raw_line: str
    is_filtered: bool = False


@dataclass
class Raw:
    """Raw domain entity."""
    id: str
    lines: List[RawLine] = field(default_factory=list)
    visible: bool = False
    filter_in: Optional[str] = None
    filter_out: Optional[str] = None
    max_lines: int = 1000
    show_timestamps: bool = True
    show_direction: bool = True
    filtered_count: int = 0


# === RAW OPERATIONS ===

def process(item: Raw) -> Raw:
    """Process raw view and apply filters."""
    filtered = 0
    new_lines = []
    
    for line in item.lines:
        is_filtered = False
        
        if item.filter_in and item.filter_in.lower() not in line.raw_line.lower():
            is_filtered = True
        
        if item.filter_out and item.filter_out.lower() in line.raw_line.lower():
            is_filtered = True
        
        if not is_filtered:
            new_lines.append(RawLine(
                timestamp=line.timestamp,
                direction=line.direction,
                raw_line=line.raw_line,
                is_filtered=False
            ))
        else:
            filtered += 1
    
    return Raw(
        id=item.id,
        lines=new_lines,
        visible=item.visible,
        filter_in=item.filter_in,
        filter_out=item.filter_out,
        max_lines=item.max_lines,
        show_timestamps=item.show_timestamps,
        show_direction=item.show_direction,
        filtered_count=filtered
    )


def add_line(raw: Raw, direction: str, line: str) -> Raw:
    """Add a raw line."""
    new_lines = raw.lines.copy()
    new_lines.append(RawLine(
        timestamp=datetime.now(),
        direction=direction,
        raw_line=line
    ))
    
    # Trim to max
    if len(new_lines) > raw.max_lines:
        new_lines = new_lines[-raw.max_lines:]
    
    return Raw(
        id=raw.id,
        lines=new_lines,
        visible=raw.visible,
        filter_in=raw.filter_in,
        filter_out=raw.filter_out,
        max_lines=raw.max_lines,
        show_timestamps=raw.show_timestamps,
        show_direction=raw.show_direction,
        filtered_count=raw.filtered_count
    )


def set_filter(raw: Raw, filter_in: Optional[str] = None, filter_out: Optional[str] = None) -> Raw:
    """Set filters for raw view."""
    return Raw(
        id=raw.id,
        lines=raw.lines,
        visible=raw.visible,
        filter_in=filter_in,
        filter_out=filter_out,
        max_lines=raw.max_lines,
        show_timestamps=raw.show_timestamps,
        show_direction=raw.show_direction,
        filtered_count=raw.filtered_count
    )


def toggle_visibility(raw: Raw) -> Raw:
    """Toggle raw view visibility."""
    return Raw(
        id=raw.id,
        lines=raw.lines,
        visible=not raw.visible,
        filter_in=raw.filter_in,
        filter_out=raw.filter_out,
        max_lines=raw.max_lines,
        show_timestamps=raw.show_timestamps,
        show_direction=raw.show_direction,
        filtered_count=raw.filtered_count
    )


def clear(raw: Raw) -> Raw:
    """Clear all raw lines."""
    return Raw(
        id=raw.id,
        lines=[],
        visible=raw.visible,
        filter_in=raw.filter_in,
        filter_out=raw.filter_out,
        max_lines=raw.max_lines,
        show_timestamps=raw.show_timestamps,
        show_direction=raw.show_direction,
        filtered_count=0
    )


def format_line(line: RawLine, show_time: bool = True, show_dir: bool = True) -> str:
    """Format a raw line for display."""
    parts = []
    
    if show_time:
        parts.append(line.timestamp.strftime("%H:%M:%S"))
    
    if show_dir:
        parts.append("<<" if line.direction == "in" else ">>")
    
    parts.append(line.raw_line)
    
    return " ".join(parts)


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "9cb0e8514a7d9f5ed9071f11c5d4ce5b8b7bd9a0e0e2a0c3f6d1a4b9c8d7e5f4",
    "name": "Raw Domain",
    "risk_tier": "low",
}
