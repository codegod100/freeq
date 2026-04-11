# /home/nandi/code/freeq/freeq Py/spec/sidebar Css Pseudo Element Fix


## Requirements

# Sidebar CSS Pseudo-Element Fix

## Overview
Fix CSS parser error in BufferSidebar widget caused by unsupported `::before` pseudo-element syntax in Textual CSS (TCSS).

## Error Details
- **File**: `/home/nandi/code/freeq/freeq-py/src/generated/widgets/sidebar.py`
- **Location**: BufferSidebar.DEFAULT_CSS, Line 30
- **Error**: `Expected selector or { (found '::before {\n')`
- **Root Cause**: Textual CSS does not support CSS pseudo-elements (`::before`, `::after`)

## Requirement: REQ-001 - Remove Incompatible CSS Rule
- The CSS rule `BufferSidebar .buffer-item.channel::before` SHALL be removed from DEFAULT_CSS
- The rule containing `content: "#";` SHALL be deleted entirely
- All other CSS rules in BufferSidebar.DEFAULT_CSS SHALL remain unchanged

## Requirement: REQ-002 - Preserve Channel Prefix Functionality
- Channel name prefixing with "#" SHALL continue to work via existing Python logic
- The `_render_buffers` method already prepends "#" to channel names (lines 129-131)
- Python implementation SHALL handle the prefix: `if buffer.is_channel and not display_name.startswith("#"): display_name = f"#{display_name}"`

## Requirement: REQ-003 - CSS Syntax Validation
- All CSS in DEFAULT_CSS SHALL use valid Textual CSS (TCSS) syntax only
- CSS rules SHALL NOT use pseudo-elements (`::before`, `::after`, `::first-line`, etc.)
- CSS rules SHALL NOT use pseudo-classes that are unsupported by Textual
- Valid selectors include: element types, IDs (`#id`), classes (`.class`), and descendant combinators

## Affected Code Location
- **File**: `/home/nandi/code/freeq/freeq-py/src/generated/widgets/sidebar.py`
- **Canon ID**: `@phoenix-canon: node-c385163a-css`
- **Lines to Remove**: 30-32 (the `.buffer-item.channel::before` rule)

## CSS Context (Lines to Preserve)
BufferSidebar {
    width: 100%;
    height: 100%;
    background: $surface-darken-1;
    border-right: solid $primary;
}
BufferSidebar #sidebar-title {
    dock: top;
    height: 1;
    content-align: center middle;
    background: $primary;
    color: $text;
}
BufferSidebar #buffer-list {
    width: 100%;
    height: 1fr;
}
BufferSidebar .buffer-item {
    height: 1;
    padding: 0 1;
}
BufferSidebar .buffer-item.selected {
    background: $primary-darken-2;
    color: $text-accent;
}
BufferSidebar .buffer-item.unread {
    text-style: bold;
}
/* REMOVE THIS RULE: */
BufferSidebar .buffer-item.channel::before {
    content: "#";
}

## Implementation Note
The removal of this CSS rule is safe because:
1. The Python code in `_render_buffers()` already adds "#" to channel display names
2. The CSS rule was redundant and never functioned (caused parser error)
3. Textual CSS does not support content generation via pseudo-elements

## Verification Steps
1. Run `.venv/bin/python -m src.generated.app`
2. Verify no CSS parser errors appear
3. Verify channel names in sidebar display with "#" prefix
4. Verify non-channel buffers (queries/PMs) do not have "#" prefix

