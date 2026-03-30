"""Debug logging utilities."""

import datetime
from typing import Callable

# Optional callback for real-time debug output (e.g., DebugPanel)
_debug_callback: Callable[[str], None] | None = None


def set_debug_callback(callback: Callable[[str], None] | None) -> None:
    """Set or clear the debug callback for real-time output."""
    global _debug_callback
    _debug_callback = callback


def _dbg(msg: str) -> None:
    """Debug logging - writes to /tmp/freeq-tui.log and optional callback."""
    timestamped = f"{datetime.datetime.now().isoformat()} {msg}"
    with open("/tmp/freeq-tui.log", "a") as f:
        f.write(f"{timestamped}\n")
    if _debug_callback:
        _debug_callback(msg)  # Without timestamp for cleaner panel display