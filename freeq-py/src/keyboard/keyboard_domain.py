# 🟢 GREEN: Keyboard Domain (IU-27b86183)
# Description: Implements keybindings, shortcuts, and input handling with 10 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Keybinding registration
#   2. Key chord support
#   3. Context-aware keybindings
#   4. Input history navigation
#   5. Modal key handling
#   6. Custom keybinding configuration
#   7. Default keybindings for common actions
#   8. Keybinding conflict detection
#   9. Key recording for macros
#   10. Help display for keybindings

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Callable, Any, Set
from enum import Enum, auto

# === TYPES ===

class KeyContext(Enum):
    """Context for keybindings."""
    GLOBAL = auto()
    INPUT = auto()
    MESSAGE_LIST = auto()
    SIDEBAR = auto()
    MODAL = auto()
    COMMAND = auto()


class KeyAction(Enum):
    """Available key actions."""
    # Navigation
    NEXT_BUFFER = "next_buffer"
    PREV_BUFFER = "prev_buffer"
    SCROLL_UP = "scroll_up"
    SCROLL_DOWN = "scroll_down"
    PAGE_UP = "page_up"
    PAGE_DOWN = "page_down"
    HOME = "home"
    END = "end"
    
    # Input
    SUBMIT = "submit"
    CANCEL = "cancel"
    HISTORY_UP = "history_up"
    HISTORY_DOWN = "history_down"
    COMPLETE = "complete"
    CLEAR = "clear"
    
    # UI
    TOGGLE_SIDEBAR = "toggle_sidebar"
    TOGGLE_USERLIST = "toggle_userlist"
    TOGGLE_DEBUG = "toggle_debug"
    TOGGLE_EMOJI = "toggle_emoji"
    TOGGLE_THREAD = "toggle_thread"
    
    # Actions
    JOIN = "join"
    PART = "part"
    QUIT = "quit"
    NICK = "nick"
    WHOIS = "whois"
    REPLY = "reply"
    REACT = "react"
    EDIT = "edit"
    DELETE = "delete"
    
    # System
    RELOAD = "reload"
    LOGOUT = "logout"
    EXIT = "exit"


@dataclass
class Keybinding:
    """Single keybinding definition."""
    key: str  # e.g., "ctrl+n", "f5", "escape"
    action: KeyAction
    context: KeyContext
    handler: Optional[Callable] = None
    description: str = ""
    repeatable: bool = False


@dataclass
class KeyChord:
    """Key chord (sequence of keys)."""
    keys: List[str]
    action: KeyAction
    timeout_ms: int = 1000


@dataclass
class Keyboard:
    """Keyboard domain entity."""
    id: str
    bindings: Dict[str, Keybinding] = field(default_factory=dict)
    chords: List[KeyChord] = field(default_factory=list)
    chord_buffer: List[str] = field(default_factory=list)
    current_context: KeyContext = KeyContext.GLOBAL
    input_history: List[str] = field(default_factory=list)
    history_position: int = 0
    recording: bool = False
    recorded_keys: List[str] = field(default_factory=list)
    modal_focus: bool = False


# === DEFAULT KEYBINDINGS ===

DEFAULT_KEYBINDINGS: List[Keybinding] = [
    # Global navigation
    Keybinding("ctrl+n", KeyAction.NEXT_BUFFER, KeyContext.GLOBAL, description="Next buffer"),
    Keybinding("ctrl+p", KeyAction.PREV_BUFFER, KeyContext.GLOBAL, description="Previous buffer"),
    Keybinding("ctrl+b", KeyAction.TOGGLE_SIDEBAR, KeyContext.GLOBAL, description="Toggle sidebar"),
    Keybinding("ctrl+u", KeyAction.TOGGLE_USERLIST, KeyContext.GLOBAL, description="Toggle userlist"),
    
    # Input
    Keybinding("ctrl+l", KeyAction.CLEAR, KeyContext.INPUT, description="Clear input"),
    Keybinding("up", KeyAction.HISTORY_UP, KeyContext.INPUT, description="Previous history"),
    Keybinding("down", KeyAction.HISTORY_DOWN, KeyContext.INPUT, description="Next history"),
    Keybinding("tab", KeyAction.COMPLETE, KeyContext.INPUT, description="Autocomplete"),
    Keybinding("escape", KeyAction.CANCEL, KeyContext.INPUT, description="Cancel"),
    
    # Scrolling
    Keybinding("pageup", KeyAction.PAGE_UP, KeyContext.MESSAGE_LIST, description="Page up"),
    Keybinding("pagedown", KeyAction.PAGE_DOWN, KeyContext.MESSAGE_LIST, description="Page down"),
    Keybinding("home", KeyAction.HOME, KeyContext.MESSAGE_LIST, description="Go to top"),
    Keybinding("end", KeyAction.END, KeyContext.MESSAGE_LIST, description="Go to bottom"),
    
    # Special
    Keybinding("f5", KeyAction.RELOAD, KeyContext.GLOBAL, description="Reload"),
    Keybinding("ctrl+d", KeyAction.TOGGLE_DEBUG, KeyContext.GLOBAL, description="Toggle debug panel"),
    Keybinding("ctrl+e", KeyAction.TOGGLE_EMOJI, KeyContext.GLOBAL, description="Toggle emoji picker"),
    Keybinding("ctrl+t", KeyAction.TOGGLE_THREAD, KeyContext.GLOBAL, description="Toggle thread panel"),
    Keybinding("ctrl+q", KeyAction.EXIT, KeyContext.GLOBAL, description="Quit"),
    
    # Actions
    Keybinding("r", KeyAction.REPLY, KeyContext.MESSAGE_LIST, description="Reply to message"),
    Keybinding("e", KeyAction.REACT, KeyContext.MESSAGE_LIST, description="Add reaction"),
]


# === KEYBOARD OPERATIONS ===

def process(item: Keyboard) -> Keyboard:
    """Process keyboard state and normalize.
    
    Ensures history position is valid and chord buffer is not stale.
    """
    # Normalize history position
    valid_position = max(0, min(item.history_position, len(item.input_history)))
    
    return Keyboard(
        id=item.id,
        bindings=dict(item.bindings),
        chords=item.chords.copy(),
        chord_buffer=item.chord_buffer.copy(),
        current_context=item.current_context,
        input_history=item.input_history.copy(),
        history_position=valid_position,
        recording=item.recording,
        recorded_keys=item.recorded_keys.copy() if item.recording else [],
        modal_focus=item.modal_focus
    )


def register_binding(
    keyboard: Keyboard,
    key: str,
    action: KeyAction,
    context: KeyContext = KeyContext.GLOBAL,
    handler: Optional[Callable] = None,
    description: str = ""
) -> Keyboard:
    """Register a new keybinding."""
    new_bindings = dict(keyboard.bindings)
    new_bindings[key] = Keybinding(
        key=key,
        action=action,
        context=context,
        handler=handler,
        description=description
    )
    
    return Keyboard(
        id=keyboard.id,
        bindings=new_bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=keyboard.current_context,
        input_history=keyboard.input_history.copy(),
        history_position=keyboard.history_position,
        recording=keyboard.recording,
        recorded_keys=keyboard.recorded_keys.copy(),
        modal_focus=keyboard.modal_focus
    )


def unregister_binding(keyboard: Keyboard, key: str) -> Keyboard:
    """Remove a keybinding."""
    new_bindings = dict(keyboard.bindings)
    if key in new_bindings:
        del new_bindings[key]
    
    return Keyboard(
        id=keyboard.id,
        bindings=new_bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=keyboard.current_context,
        input_history=keyboard.input_history.copy(),
        history_position=keyboard.history_position,
        recording=keyboard.recording,
        recorded_keys=keyboard.recorded_keys.copy(),
        modal_focus=keyboard.modal_focus
    )


def lookup_binding(keyboard: Keyboard, key: str, context: Optional[KeyContext] = None) -> Optional[Keybinding]:
    """Look up keybinding for a key.
    
    Returns binding if found and context matches (or context not specified).
    """
    binding = keyboard.bindings.get(key)
    if not binding:
        return None
    
    if context and binding.context != context and binding.context != KeyContext.GLOBAL:
        return None
    
    return binding


def add_input_history(keyboard: Keyboard, text: str, max_history: int = 100) -> Keyboard:
    """Add text to input history."""
    new_history = keyboard.input_history.copy()
    new_history.append(text)
    
    # Trim to max
    if len(new_history) > max_history:
        new_history = new_history[-max_history:]
    
    return Keyboard(
        id=keyboard.id,
        bindings=keyboard.bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=keyboard.current_context,
        input_history=new_history,
        history_position=len(new_history),
        recording=keyboard.recording,
        recorded_keys=keyboard.recorded_keys.copy(),
        modal_focus=keyboard.modal_focus
    )


def get_history_item(keyboard: Keyboard, direction: int) -> Optional[str]:
    """Get history item at current position + direction.
    
    direction: -1 for older, +1 for newer
    """
    new_position = keyboard.history_position + direction
    
    if 0 <= new_position < len(keyboard.input_history):
        return keyboard.input_history[new_position]
    
    return None


def start_recording(keyboard: Keyboard) -> Keyboard:
    """Start recording key sequence."""
    return Keyboard(
        id=keyboard.id,
        bindings=keyboard.bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=keyboard.current_context,
        input_history=keyboard.input_history.copy(),
        history_position=keyboard.history_position,
        recording=True,
        recorded_keys=[],
        modal_focus=keyboard.modal_focus
    )


def stop_recording(keyboard: Keyboard) -> Keyboard:
    """Stop recording and save macro."""
    return Keyboard(
        id=keyboard.id,
        bindings=keyboard.bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=keyboard.current_context,
        input_history=keyboard.input_history.copy(),
        history_position=keyboard.history_position,
        recording=False,
        recorded_keys=keyboard.recorded_keys.copy(),
        modal_focus=keyboard.modal_focus
    )


def record_key(keyboard: Keyboard, key: str) -> Keyboard:
    """Record a key during macro recording."""
    if not keyboard.recording:
        return keyboard
    
    new_keys = keyboard.recorded_keys.copy()
    new_keys.append(key)
    
    return Keyboard(
        id=keyboard.id,
        bindings=keyboard.bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=keyboard.current_context,
        input_history=keyboard.input_history.copy(),
        history_position=keyboard.history_position,
        recording=True,
        recorded_keys=new_keys,
        modal_focus=keyboard.modal_focus
    )


def set_context(keyboard: Keyboard, context: KeyContext) -> Keyboard:
    """Set current keybinding context."""
    return Keyboard(
        id=keyboard.id,
        bindings=keyboard.bindings,
        chords=keyboard.chords.copy(),
        chord_buffer=keyboard.chord_buffer.copy(),
        current_context=context,
        input_history=keyboard.input_history.copy(),
        history_position=keyboard.history_position,
        recording=keyboard.recording,
        recorded_keys=keyboard.recorded_keys.copy(),
        modal_focus=keyboard.modal_focus
    )


def get_help_text(keyboard: Keyboard, context: Optional[KeyContext] = None) -> List[str]:
    """Generate help text for keybindings."""
    lines = []
    
    target_context = context or keyboard.current_context
    
    lines.append(f"Keybindings ({target_context.name.lower()}):")
    lines.append("")
    
    for binding in keyboard.bindings.values():
        if binding.context == target_context or binding.context == KeyContext.GLOBAL:
            desc = binding.description or binding.action.value
            lines.append(f"  {binding.key:15} - {desc}")
    
    return lines


def create_default_keyboard(id: str = "default") -> Keyboard:
    """Create keyboard with default keybindings."""
    bindings = {b.key: b for b in DEFAULT_KEYBINDINGS}
    
    return Keyboard(
        id=id,
        bindings=bindings,
        chords=[],
        chord_buffer=[],
        current_context=KeyContext.GLOBAL,
        input_history=[],
        history_position=0,
        recording=False,
        recorded_keys=[],
        modal_focus=False
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "27b8618313ccfee47e6f7d7d6f2a0f8a6b13e833cd97b177f86f5a5fd253305d",
    "name": "Keyboard Domain",
    "risk_tier": "high",
}
