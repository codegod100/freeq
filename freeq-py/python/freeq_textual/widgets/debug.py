"""Debug logging utilities."""

import datetime


# Debug logging - writes to /tmp/freeq-tui.log for troubleshooting thread panel issues
# Can be disabled by commenting out the body or redirecting to null
def _dbg(msg: str) -> None:
    with open("/tmp/freeq-tui.log", "a") as f:
        f.write(f"{datetime.datetime.now().isoformat()} {msg}\n")