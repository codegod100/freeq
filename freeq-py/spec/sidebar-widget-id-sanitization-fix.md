# /home/nandi/code/freeq/freeq Py/spec/sidebar Widget Id Sanitization Fix


## Requirements

# Sidebar Widget ID Sanitization Fix

## Overview
Fix `BadIdentifier` error in SidebarWidget caused by invalid CSS identifier characters in dynamically generated widget IDs. Buffer IDs containing special characters like `#` (e.g., `channel-#general`) result in invalid widget IDs that violate Textual's CSS identifier constraints.

## Error Details
- **File**: `/home/nandi/code/freeq/freeq-py/src/generated/widgets/sidebar.py`
- **Location**: `_create_buffer_item` method, Line 191
- **Error**: `BadIdentifier: 'buffer-channel-#general' is an invalid id; identifiers must contain only letters, numbers, underscores, or hyphens, and must not begin with a number.`
- **Root Cause**: Widget IDs are generated via `id=f"buffer-{buffer_state.id}"` without sanitizing the buffer ID, which may contain characters like `#` from channel names (e.g., `#general`)

## Requirement: REQ-001 - Sanitize Widget IDs in _create_buffer_item
- The `_create_buffer_item` method SHALL sanitize `buffer_state.id` before using it in widget ID construction
- Invalid CSS identifier characters SHALL be replaced with valid alternatives:
  - `#` (hash/pound) SHALL be replaced with `-hash-`
  - `@` (at symbol) SHALL be replaced with `-at-`
  - Any other non-alphanumeric characters (except hyphens and underscores) SHALL be replaced with `-`
- The sanitized ID SHALL be used for both:
  - The `id` parameter in `ListItem` constructor: `id=f"buffer-{sanitized_id}"`
- The original unsanitized `buffer_state.id` SHALL still be used for:
  - Internal tracking in `self._buffer_items` dictionary
  - Event handling and buffer lookup logic

## Requirement: REQ-002 - Consistent ID Sanitization Across Methods
- The `_update_buffer_item` method SHALL use the same sanitization logic when referencing widget IDs
- The `_update_selection_styling` method SHALL use the same sanitization logic when applying CSS classes
- All methods that construct or reference widget IDs SHALL use a shared sanitization function to ensure consistency

## Requirement: REQ-003 - ID Sanitization Function
- A helper method `_sanitize_widget_id(id: str) -> str` SHALL be implemented in SidebarWidget
- The method SHALL replace invalid CSS identifier characters:
  - Replace `#` with `hash` (after hyphen context)
  - Replace `@` with `at` (after hyphen context)  
  - Replace any character not matching `[a-zA-Z0-9_-]` with `-`
- The method SHALL be used consistently wherever widget IDs are constructed

## Affected Code Location
- **File**: `/home/nandi/code/freeq/freeq-py/src/generated/widgets/sidebar.py`
- **Canon ID**: `@phoenix-canon: node-5df2a612` (within _create_buffer_item)

## Code Changes Required

### 1. Add Sanitization Helper Method
Add to SidebarWidget class:
def _sanitize_widget_id(self, buffer_id: str) -> str:
    """Sanitize buffer ID for use as CSS widget identifier.
    
    CSS identifiers must contain only letters, numbers, underscores, or hyphens.
    Replaces invalid characters with valid alternatives.
    """
    sanitized = buffer_id
    # Replace special characters with named tokens
    sanitized = sanitized.replace("#", "-hash-")
    sanitized = sanitized.replace("@", "-at-")
    # Replace any remaining invalid chars with hyphen
    import re
    sanitized = re.sub(r'[^a-zA-Z0-9_-]', '-', sanitized)
    # Collapse multiple consecutive hyphens
    sanitized = re.sub(r'-+', '-', sanitized)
    # Remove leading/trailing hyphens
    sanitized = sanitized.strip('-')
    return sanitized

### 2. Update _create_buffer_item Method
Modify the ListItem construction (line 191):
def _create_buffer_item(self, buffer_state: BufferState) -> ListItem:
    """Create a ListItem for a buffer."""
    display_name = self._format_buffer_name(buffer_state)
    
    # Add unread indicator if needed
    if buffer_state.unread_count > 0:
        display_name = f"{display_name} ({buffer_state.unread_count})"
    
    classes = "buffer-item"
    if buffer_state.has_activity:
        classes += " activity"
    if buffer_state.is_highlighted:
        classes += " highlighted"
    if buffer_state.id == self.active_buffer_id:
        classes += " selected"
    
    # Sanitize ID for CSS identifier compliance
    sanitized_id = self._sanitize_widget_id(buffer_state.id)
    
    return ListItem(
        Label(display_name),
        classes=classes,
        id=f"buffer-{sanitized_id}"
    )

### 3. Update _update_buffer_item Method
Ensure widget lookup uses sanitized ID if applicable (verify consistency).

## Verification Steps
1. Run `.venv/bin/python -m src.generated.app`
2. Verify no `BadIdentifier` errors appear during sidebar buffer creation
3. Verify channels with `#` prefix (e.g., `#general`) display correctly in sidebar
4. Verify queries with `@` prefix (e.g., `@username`) display correctly in sidebar
5. Verify buffer selection and navigation works correctly
6. Verify buffer updates (unread counts, activity indicators) work correctly

## Regression Testing
- Test with buffer IDs containing multiple special characters
- Test with buffer IDs starting with special characters
- Test with empty or minimal buffer names
- Verify CSS styling (selected, highlighted, activity classes) applies correctly to sanitized IDs

