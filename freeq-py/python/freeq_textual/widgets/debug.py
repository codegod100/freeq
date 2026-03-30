"""Debug logging utilities.

SINGLE LOG FILE POLICY:
=======================
ALL logging goes to /tmp/freeq.log ONLY.

WHY SINGLE LOG FILE:
- Easy to find and tail
- No confusion about which log to check
- One place to grep for errors
- User explicitly rejected multiple log files

DO NOT create additional log files!
DO NOT log to different files for different modules!
ALL FRIENDS LOG TO THE SAME PLACE!
"""

import datetime
from typing import Callable

# Optional callback for real-time debug output (e.g., DebugPanel)
_debug_callback: Callable[[str], None] | None = None

# THE ONE AND ONLY LOG FILE - DO NOT CHANGE THIS PATH
_LOG_FILE = "/tmp/freeq.log"


def set_debug_callback(callback: Callable[[str], None] | None) -> None:
    """Set or clear the debug callback for real-time output."""
    global _debug_callback
    _debug_callback = callback


def _dbg(msg: str) -> None:
    """Debug logging - writes to THE ONE LOG FILE and optional callback."""
    timestamped = f"{datetime.datetime.now().isoformat()} {msg}"
    with open(_LOG_FILE, "a") as f:
        f.write(f"{timestamped}\n")
    if _debug_callback:
        _debug_callback(msg)  # Without timestamp for cleaner panel display