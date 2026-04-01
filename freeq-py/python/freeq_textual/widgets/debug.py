"""Proactive debug logging with failure anticipation.

Adds logging at likely failure points to catch bugs before they manifest.

Failure heuristics:
- Widget lifecycle mismatches (mounted but not ready)
- State desync (buffer claims to have messages but _renderable_lines returns 0)
- Width anomalies (0, negative, or sudden large changes)
- Race conditions (events during unmount)
- Content pipeline failures (empty after processing)
- Slot type mismatches (variant not allowed)
- Network event ordering issues
- State mutation during render
"""

import datetime
import functools
import time
from typing import Callable, Any
from contextlib import contextmanager

# Optional callback for real-time debug output (e.g., DebugPanel)
_debug_callback: Callable[[str], None] | None = None

# THE ONE AND ONLY LOG FILE
_LOG_FILE = "/tmp/freeq.log"

# Track recent operations for correlation
_operation_context: dict[str, Any] = {}

# Timing history for anomaly detection
_timing_history: dict[str, list[float]] = {}


def set_debug_callback(callback: Callable[[str], None] | None) -> None:
    """Set or clear the debug callback for real-time output."""
    global _debug_callback
    _debug_callback = callback


def _dbg(msg: str, level: str = "DEBUG") -> None:
    """Debug logging with level and context."""
    timestamped = f"{datetime.datetime.now().isoformat()} [{level}] {msg}"
    with open(_LOG_FILE, "a") as f:
        f.write(f"{timestamped}\n")
    if _debug_callback:
        _debug_callback(f"[{level}] {msg}")


def _info(msg: str) -> None:
    """Info - normal operations."""
    _dbg(msg, "INFO")


def _warn(msg: str) -> None:
    """Warning - something suspicious but not fatal."""
    _dbg(msg, "WARN")


def _error(msg: str) -> None:
    """Error - something definitely wrong."""
    _dbg(msg, "ERROR")


def set_context(key: str, value: Any) -> None:
    """Set context for correlation across async operations."""
    _operation_context[key] = value


def get_context(key: str) -> Any:
    """Get context value."""
    return _operation_context.get(key)


def clear_context(key: str) -> None:
    """Clear context value."""
    _operation_context.pop(key, None)


@contextmanager
def log_operation(operation: str, **context):
    """Context manager for logging operation lifecycle.
    
    Usage:
        with log_operation("render", buffer="#test"):
            do_render()
    
    Logs start, completion, and any exceptions with full context.
    """
    start = time.time()
    op_id = f"{operation}_{int(start * 1000) % 10000}"
    
    # Set context for correlation
    for k, v in context.items():
        set_context(f"{op_id}.{k}", v)
    
    _dbg(f"[{op_id}] START {operation} {context}")
    
    try:
        yield op_id
        elapsed = time.time() - start
        _dbg(f"[{op_id}] COMPLETE {operation} ({elapsed:.3f}s)")
    except Exception as e:
        elapsed = time.time() - start
        _error(f"[{op_id}] FAILED {operation} after {elapsed:.3f}s: {type(e).__name__}: {e}")
        _error(f"[{op_id}] CONTEXT: {_operation_context}")
        raise
    finally:
        # Clean up context
        for k in list(_operation_context.keys()):
            if k.startswith(f"{op_id}."):
                del _operation_context[k]


def validate_invariant(condition: bool, message: str, **context) -> None:
    """Validate an invariant and log violation if false.
    
    Usage:
        validate_invariant(width > 0, "width must be positive", width=width, buffer=buffer)
    """
    if not condition:
        _error(f"INVARIANT VIOLATION: {message} context={context}")


def validate_warning(condition: bool, message: str, **context) -> None:
    """Validate a soft condition and warn if false."""
    if not condition:
        _warn(f"SUSPICIOUS: {message} context={context}")


def check_render_pipeline(
    buffer_key: str,
    raw_line_count: int,
    rendered_line_count: int,
    width: int,
) -> None:
    """Check message rendering pipeline for anomalies."""
    # Check 1: width anomalies
    if width == 0:
        _error(f"RENDER: width=0 for {buffer_key} - widget not laid out!")
    elif width < 0:
        _error(f"RENDER: negative width={width} for {buffer_key}")
    elif width > 500:
        _warn(f"RENDER: suspiciously large width={width} for {buffer_key}")
    
    # Check 2: line count mismatch
    if raw_line_count == 0:
        _warn(f"RENDER: zero lines for {buffer_key} - empty buffer or error?")
    elif rendered_line_count == 0 and raw_line_count > 0:
        _error(f"RENDER: all lines disappeared! raw={raw_line_count}, rendered=0")
    
    # Check 3: significant loss
    loss_ratio = 1 - (rendered_line_count / max(raw_line_count, 1))
    if loss_ratio > 0.5:
        _warn(f"RENDER: {loss_ratio:.0%} lines lost! raw={raw_line_count}, rendered={rendered_line_count}")


def check_widget_state(widget, operation: str) -> None:
    """Check widget is in valid state for operation."""
    name = getattr(widget, 'id', None) or getattr(widget, 'name', type(widget).__name__)
    
    if not widget.is_mounted:
        _warn(f"WIDGET: {name} not mounted during {operation}")
    
    if hasattr(widget, 'size'):
        w, h = widget.size
        if w == 0 or h == 0:
            _warn(f"WIDGET: {name} has zero size ({w}x{h}) during {operation}")
            # NEW: Detailed diagnostics for zero-width cases
            if w == 0 and hasattr(widget, 'parent') and widget.parent:
                parent = widget.parent
                parent_name = getattr(parent, 'id', None) or type(parent).__name__
                pw, ph = parent.size if hasattr(parent, 'size') else (0, 0)
                _warn(f"WIDGET_DETAIL: {name} parent={parent_name} parent_size={pw}x{ph}")
                # Log siblings
                if hasattr(parent, 'children'):
                    for i, sibling in enumerate(parent.children):
                        sib_name = getattr(sibling, 'id', None) or type(sibling).__name__
                        if hasattr(sibling, 'size'):
                            sw, sh = sibling.size
                            display = getattr(sibling, 'display', '?')
                            _warn(f"WIDGET_DETAIL: sibling[{i}]={sib_name} size={sw}x{sh} display={display}")
    
    if hasattr(widget, 'is_active') and not widget.is_active:
        _warn(f"WIDGET: {name} not active during {operation}")


def check_slot_operation(slot, variant_class, success: bool) -> None:
    """Check slot operation result."""
    slot_id = getattr(slot, 'id', 'unknown')
    slot_type = getattr(slot, 'slot_type_name', type(slot).__name__)
    
    if not success:
        allowed = getattr(slot, 'allowed_variants', [])
        _error(f"SLOT: failed to load {variant_class.__name__} into {slot_id}")
        _error(f"SLOT: type={slot_type}, allowed={[c.__name__ for c in allowed]}")
    else:
        _dbg(f"SLOT: loaded {variant_class.__name__} into {slot_id}")


def check_message_flow(
    operation: str,
    msgid: str | None,
    buffer: str,
    expected_buffer: str | None = None,
) -> None:
    """Check message routing correctness."""
    if expected_buffer and buffer != expected_buffer:
        _error(f"ROUTING: message routed to wrong buffer! op={operation} msgid={msgid[:8] if msgid else None} got={buffer} expected={expected_buffer}")
    
    if not msgid:
        _warn(f"ROUTING: {operation} with no msgid on {buffer} - untrackable!")


def check_event_timing(
    event_type: str,
    buffer: str,
    last_event_time: float | None,
) -> float:
    """Check for event timing anomalies. Returns current time."""
    now = time.time()
    
    if last_event_time:
        delta = now - last_event_time
        if delta < 0.001:
            _warn(f"TIMING: {event_type} on {buffer} burst ({delta:.4f}s since last)")
        elif delta > 60:
            _warn(f"TIMING: {event_type} on {buffer} after long gap ({delta:.1f}s)")
    
    return now


def log_state_snapshot(app, label: str) -> None:
    """Log current app state for debugging."""
    try:
        _dbg(f"SNAPSHOT[{label}]: active_buffer={app.active_buffer}")
        _dbg(f"SNAPSHOT[{label}]: buffers={list(app.buffers.keys())}")
        _dbg(f"SNAPSHOT[{label}]: messages.keys={list(app.messages.keys())}")
        _dbg(f"SNAPSHOT[{label}]: thread_panel_open={app._thread_panel_is_open()}")
        _dbg(f"SNAPSHOT[{label}]: screen.mounted={app.screen.is_mounted if app.screen else False}")
    except Exception as e:
        _error(f"SNAPSHOT[{label}]: failed to capture: {e}")


def trace_method(cls, method_name: str):
    """Decorator to trace method calls on a class.
    
    Usage:
        class MyWidget:
            @trace_method(MyWidget, "on_mount")
            def on_mount(self):
                pass
    """
    original = getattr(cls, method_name)
    
    @functools.wraps(original)
    def wrapper(self, *args, **kwargs):
        name = getattr(self, 'id', None) or type(self).__name__
        _dbg(f"TRACE: {type(self).__name__}.{method_name} on {name}")
        try:
            result = original(self, *args, **kwargs)
            _dbg(f"TRACE: {type(self).__name__}.{method_name} on {name} OK")
            return result
        except Exception as e:
            _error(f"TRACE: {type(self).__name__}.{method_name} on {name} FAILED: {e}")
            raise
    
    setattr(cls, method_name, wrapper)
    return wrapper


# Additional heuristic functions for specific failure points

def check_network_event_order(
    event_type: str,
    expected_state: str,
    actual_state: str,
) -> None:
    """Check network events arrive in expected order."""
    if expected_state != actual_state:
        _warn(f"NETWORK: event {event_type} arrived in state {actual_state}, expected {expected_state}")


def check_content_encoding(
    content: str,
    source: str,
) -> None:
    """Check content for encoding issues."""
    if '\ufffd' in content:
        _warn(f"ENCODING: replacement char found in {source} - possible encoding issue")
    
    if any(ord(c) > 0x10FFFF for c in content):
        _error(f"ENCODING: invalid unicode in {source}")


def check_memory_pressure(
    buffer_count: int,
    message_count: int,
) -> None:
    """Check for potential memory issues."""
    if buffer_count > 100:
        _warn(f"MEMORY: {buffer_count} buffers - potential leak?")
    
    if message_count > 10000:
        _warn(f"MEMORY: {message_count} messages - consider pruning")


def log_correlation_id(
    operation: str,
    correlation_id: str,
) -> None:
    """Log correlation ID for tracing async operations."""
    _dbg(f"CORRELATION: {operation} id={correlation_id}")
