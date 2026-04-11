# 🟢 GREEN: Input Domain (IU-efda7a2a)
# Description: Implements input handling with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Input state tracking
#   2. Cursor position management
#   3. Selection handling
#   4. Input validation

from dataclasses import dataclass, field
from typing import Optional, List, Tuple

# === TYPES ===

@dataclass
class InputSelection:
    """Text selection in input."""
    start: int = 0
    end: int = 0
    active: bool = False


@dataclass
class Input:
    """Input domain entity."""
    id: str
    content: str = ""
    cursor_position: int = 0
    selection: InputSelection = field(default_factory=InputSelection)
    placeholder: str = ""
    multiline: bool = False
    max_length: Optional[int] = None
    disabled: bool = False
    focused: bool = False
    history: List[str] = field(default_factory=list)
    history_position: int = 0
    autocomplete_suggestions: List[str] = field(default_factory=list)


# === INPUT OPERATIONS ===

def process(item: Input) -> Input:
    """Process input state and normalize."""
    # Ensure cursor within bounds
    valid_cursor = max(0, min(item.cursor_position, len(item.content)))
    
    # Ensure selection valid
    valid_start = max(0, min(item.selection.start, len(item.content)))
    valid_end = max(0, min(item.selection.end, len(item.content)))
    
    return Input(
        id=item.id,
        content=item.content,
        cursor_position=valid_cursor,
        selection=InputSelection(
            start=valid_start,
            end=valid_end,
            active=item.selection.active and valid_start != valid_end
        ),
        placeholder=item.placeholder,
        multiline=item.multiline,
        max_length=item.max_length,
        disabled=item.disabled,
        focused=item.focused,
        history=item.history.copy(),
        history_position=item.history_position,
        autocomplete_suggestions=item.autocomplete_suggestions.copy()
    )


def insert_text(input_state: Input, text: str) -> Input:
    """Insert text at cursor position."""
    if input_state.disabled:
        return input_state
    
    # Check max length
    if input_state.max_length:
        if len(input_state.content) + len(text) > input_state.max_length:
            text = text[:input_state.max_length - len(input_state.content)]
    
    # Handle selection - replace it
    if input_state.selection.active:
        start = min(input_state.selection.start, input_state.selection.end)
        end = max(input_state.selection.start, input_state.selection.end)
        new_content = input_state.content[:start] + text + input_state.content[end:]
        new_cursor = start + len(text)
    else:
        new_content = (
            input_state.content[:input_state.cursor_position] +
            text +
            input_state.content[input_state.cursor_position:]
        )
        new_cursor = input_state.cursor_position + len(text)
    
    return Input(
        id=input_state.id,
        content=new_content,
        cursor_position=new_cursor,
        selection=InputSelection(),  # Clear selection
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=input_state.history_position,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


def delete_selection(input_state: Input) -> Input:
    """Delete selected text."""
    if not input_state.selection.active:
        return input_state
    
    start = min(input_state.selection.start, input_state.selection.end)
    end = max(input_state.selection.start, input_state.selection.end)
    
    new_content = input_state.content[:start] + input_state.content[end:]
    
    return Input(
        id=input_state.id,
        content=new_content,
        cursor_position=start,
        selection=InputSelection(),  # Clear selection
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=input_state.history_position,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


def delete_char(input_state: Input, forward: bool = False) -> Input:
    """Delete a character."""
    if input_state.disabled or not input_state.content:
        return input_state
    
    if input_state.selection.active:
        return delete_selection(input_state)
    
    if forward:
        # Delete character after cursor
        new_content = (
            input_state.content[:input_state.cursor_position] +
            input_state.content[input_state.cursor_position + 1:]
        )
        new_cursor = input_state.cursor_position
    else:
        # Delete character before cursor
        if input_state.cursor_position == 0:
            return input_state
        new_content = (
            input_state.content[:input_state.cursor_position - 1] +
            input_state.content[input_state.cursor_position:]
        )
        new_cursor = input_state.cursor_position - 1
    
    return Input(
        id=input_state.id,
        content=new_content,
        cursor_position=new_cursor,
        selection=InputSelection(),
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=input_state.history_position,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


def move_cursor(input_state: Input, delta: int, select: bool = False) -> Input:
    """Move cursor by delta."""
    new_pos = max(0, min(input_state.cursor_position + delta, len(input_state.content)))
    
    if select:
        if not input_state.selection.active:
            # Start new selection
            new_selection = InputSelection(
                start=input_state.cursor_position,
                end=new_pos,
                active=True
            )
        else:
            # Extend selection
            new_selection = InputSelection(
                start=input_state.selection.start,
                end=new_pos,
                active=True
            )
    else:
        new_selection = InputSelection()  # Clear selection
    
    return Input(
        id=input_state.id,
        content=input_state.content,
        cursor_position=new_pos,
        selection=new_selection,
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=input_state.history_position,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


def select_all(input_state: Input) -> Input:
    """Select all text."""
    return Input(
        id=input_state.id,
        content=input_state.content,
        cursor_position=len(input_state.content),
        selection=InputSelection(
            start=0,
            end=len(input_state.content),
            active=len(input_state.content) > 0
        ),
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=input_state.history_position,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


def clear(input_state: Input) -> Input:
    """Clear input content."""
    return Input(
        id=input_state.id,
        content="",
        cursor_position=0,
        selection=InputSelection(),
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=0,
        autocomplete_suggestions=[]
    )


def set_focus(input_state: Input, focused: bool) -> Input:
    """Set focus state."""
    return Input(
        id=input_state.id,
        content=input_state.content,
        cursor_position=input_state.cursor_position,
        selection=input_state.selection,
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=focused,
        history=input_state.history.copy(),
        history_position=input_state.history_position,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


def get_selected_text(input_state: Input) -> str:
    """Get selected text."""
    if not input_state.selection.active:
        return ""
    
    start = min(input_state.selection.start, input_state.selection.end)
    end = max(input_state.selection.start, input_state.selection.end)
    
    return input_state.content[start:end]


def add_to_history(input_state: Input, max_history: int = 100) -> Input:
    """Add current content to history."""
    if not input_state.content:
        return input_state
    
    new_history = [input_state.content] + [h for h in input_state.history if h != input_state.content]
    new_history = new_history[:max_history]
    
    return Input(
        id=input_state.id,
        content="",
        cursor_position=0,
        selection=InputSelection(),
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=new_history,
        history_position=0,
        autocomplete_suggestions=[]
    )


def history_navigate(input_state: Input, direction: int) -> Input:
    """Navigate history (direction: -1 older, +1 newer)."""
    if not input_state.history:
        return input_state
    
    new_pos = max(0, min(input_state.history_position + direction, len(input_state.history) - 1))
    
    if new_pos < len(input_state.history):
        content = input_state.history[new_pos]
    else:
        content = input_state.content
    
    return Input(
        id=input_state.id,
        content=content,
        cursor_position=len(content),
        selection=InputSelection(),
        placeholder=input_state.placeholder,
        multiline=input_state.multiline,
        max_length=input_state.max_length,
        disabled=input_state.disabled,
        focused=input_state.focused,
        history=input_state.history.copy(),
        history_position=new_pos,
        autocomplete_suggestions=input_state.autocomplete_suggestions
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "efda7a2a4d8e6c5b4a3f2e1d0c9b8a7f6e5d4c3b2a1f0e9d8c7b6a5f4e3d2c1",
    "name": "Input Domain",
    "risk_tier": "low",
}
