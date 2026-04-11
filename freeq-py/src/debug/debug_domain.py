# 🟢 GREEN: Debug Domain (IU-1c093eb5)
# Description: Implements debug functionality with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Log message collection
#   2. Log level filtering
#   3. Debug panel UI integration
#   4. Log export

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class LogLevel(Enum):
    """Log level severity."""
    DEBUG = 10
    INFO = 20
    WARNING = 30
    ERROR = 40
    CRITICAL = 50


@dataclass
class LogEntry:
    """Single log entry."""
    timestamp: datetime
    level: LogLevel
    category: str
    message: str
    source: Optional[str] = None
    data: Optional[Dict] = None


@dataclass
class Debug:
    """Debug domain entity."""
    id: str
    logs: List[LogEntry] = field(default_factory=list)
    max_entries: int = 1000
    min_level: LogLevel = LogLevel.INFO
    enabled_categories: Set[str] = field(default_factory=set)
    disabled_categories: Set[str] = field(default_factory=set)
    visible: bool = False
    auto_scroll: bool = True
    filtered_count: int = 0


# === DEBUG OPERATIONS ===

def process(item: Debug) -> Debug:
    """Process debug state and apply filters."""
    filtered = 0
    visible_logs = []
    
    for entry in item.logs:
        # Check level filter
        if entry.level.value < item.min_level.value:
            filtered += 1
            continue
        
        # Check category filters
        if item.disabled_categories and entry.category in item.disabled_categories:
            filtered += 1
            continue
        
        if item.enabled_categories and entry.category not in item.enabled_categories:
            filtered += 1
            continue
        
        visible_logs.append(entry)
    
    # Trim to max
    if len(visible_logs) > item.max_entries:
        visible_logs = visible_logs[-item.max_entries:]
    
    return Debug(
        id=item.id,
        logs=visible_logs,
        max_entries=item.max_entries,
        min_level=item.min_level,
        enabled_categories=item.enabled_categories.copy(),
        disabled_categories=item.disabled_categories.copy(),
        visible=item.visible,
        auto_scroll=item.auto_scroll,
        filtered_count=filtered
    )


def log(
    debug: Debug,
    level: LogLevel,
    category: str,
    message: str,
    source: Optional[str] = None,
    data: Optional[Dict] = None
) -> Debug:
    """Add a log entry."""
    new_logs = debug.logs.copy()
    new_logs.append(LogEntry(
        timestamp=datetime.now(),
        level=level,
        category=category,
        message=message,
        source=source,
        data=data
    ))
    
    # Trim to max
    if len(new_logs) > debug.max_entries:
        new_logs = new_logs[-debug.max_entries:]
    
    return Debug(
        id=debug.id,
        logs=new_logs,
        max_entries=debug.max_entries,
        min_level=debug.min_level,
        enabled_categories=debug.enabled_categories.copy(),
        disabled_categories=debug.disabled_categories.copy(),
        visible=debug.visible,
        auto_scroll=debug.auto_scroll,
        filtered_count=debug.filtered_count
    )


def debug(debug_state: Debug, category: str, message: str, **kwargs) -> Debug:
    """Log debug level message."""
    return log(debug_state, LogLevel.DEBUG, category, message, **kwargs)


def info(debug_state: Debug, category: str, message: str, **kwargs) -> Debug:
    """Log info level message."""
    return log(debug_state, LogLevel.INFO, category, message, **kwargs)


def warning(debug_state: Debug, category: str, message: str, **kwargs) -> Debug:
    """Log warning level message."""
    return log(debug_state, LogLevel.WARNING, category, message, **kwargs)


def error(debug_state: Debug, category: str, message: str, **kwargs) -> Debug:
    """Log error level message."""
    return log(debug_state, LogLevel.ERROR, category, message, **kwargs)


def set_level(debug: Debug, level: LogLevel) -> Debug:
    """Set minimum log level."""
    return Debug(
        id=debug.id,
        logs=debug.logs,
        max_entries=debug.max_entries,
        min_level=level,
        enabled_categories=debug.enabled_categories.copy(),
        disabled_categories=debug.disabled_categories.copy(),
        visible=debug.visible,
        auto_scroll=debug.auto_scroll,
        filtered_count=debug.filtered_count
    )


def enable_category(debug: Debug, category: str) -> Debug:
    """Enable a log category."""
    new_enabled = debug.enabled_categories | {category}
    new_disabled = debug.disabled_categories - {category}
    
    return Debug(
        id=debug.id,
        logs=debug.logs,
        max_entries=debug.max_entries,
        min_level=debug.min_level,
        enabled_categories=new_enabled,
        disabled_categories=new_disabled,
        visible=debug.visible,
        auto_scroll=debug.auto_scroll,
        filtered_count=debug.filtered_count
    )


def disable_category(debug: Debug, category: str) -> Debug:
    """Disable a log category."""
    new_enabled = debug.enabled_categories - {category}
    new_disabled = debug.disabled_categories | {category}
    
    return Debug(
        id=debug.id,
        logs=debug.logs,
        max_entries=debug.max_entries,
        min_level=debug.min_level,
        enabled_categories=new_enabled,
        disabled_categories=new_disabled,
        visible=debug.visible,
        auto_scroll=debug.auto_scroll,
        filtered_count=debug.filtered_count
    )


def toggle_visibility(debug: Debug) -> Debug:
    """Toggle debug panel visibility."""
    return Debug(
        id=debug.id,
        logs=debug.logs,
        max_entries=debug.max_entries,
        min_level=debug.min_level,
        enabled_categories=debug.enabled_categories.copy(),
        disabled_categories=debug.disabled_categories.copy(),
        visible=not debug.visible,
        auto_scroll=debug.auto_scroll,
        filtered_count=debug.filtered_count
    )


def clear(debug: Debug) -> Debug:
    """Clear all logs."""
    return Debug(
        id=debug.id,
        logs=[],
        max_entries=debug.max_entries,
        min_level=debug.min_level,
        enabled_categories=debug.enabled_categories.copy(),
        disabled_categories=debug.disabled_categories.copy(),
        visible=debug.visible,
        auto_scroll=debug.auto_scroll,
        filtered_count=0
    )


def format_entry(entry: LogEntry, show_timestamp: bool = True, show_level: bool = True) -> str:
    """Format a log entry as string."""
    parts = []
    
    if show_timestamp:
        parts.append(entry.timestamp.strftime("%H:%M:%S.%f")[:-3])
    
    if show_level:
        parts.append(f"[{entry.level.name}]")
    
    parts.append(f"[{entry.category}]")
    parts.append(entry.message)
    
    return " ".join(parts)


def export_logs(debug: Debug, level: Optional[LogLevel] = None) -> str:
    """Export logs as formatted string."""
    lines = []
    
    for entry in debug.logs:
        if level and entry.level.value < level.value:
            continue
        lines.append(format_entry(entry))
    
    return "\n".join(lines)


def get_logs_by_category(debug: Debug, category: str) -> List[LogEntry]:
    """Get all logs for a category."""
    return [e for e in debug.logs if e.category == category]


def get_logs_by_level(debug: Debug, level: LogLevel) -> List[LogEntry]:
    """Get all logs at or above a level."""
    return [e for e in debug.logs if e.level.value >= level.value]


def create_default_debug(id: str = "default") -> Debug:
    """Create debug with default settings."""
    return Debug(
        id=id,
        logs=[],
        max_entries=1000,
        min_level=LogLevel.INFO,
        enabled_categories=set(),
        disabled_categories=set(),
        visible=False,
        auto_scroll=True,
        filtered_count=0
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "1c093eb5f6a7d8e9c0b1a2f3e4d5c6b7a8f9e0d1c2b3a4f5e6d7c8b9a0f1e2d3",
    "name": "Debug Domain",
    "risk_tier": "low",
}
