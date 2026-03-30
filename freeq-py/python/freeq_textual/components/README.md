# Modular Component Framework - WE'RE ALL FRIENDS HERE!

This framework allows swapping out UI components without changing core app logic.

## Architecture

```
components/
├── __init__.py      # ComponentRegistry, get_component()
├── builtins.py      # Default implementations (ReplyPanel, ContextMenu)
├── all.py           # Registers ALL widgets as friends!
└── README.md        # This file

widgets/
├── __init__.py      # Exports all widgets + get_component
├── buffer_list.py   # BufferList - WE'RE ALL FRIENDS HERE!
├── thread_panel.py  # ThreadPanel - WE'RE ALL FRIENDS HERE!
├── scrollable_log.py # ScrollableLog - WE'RE ALL FRIENDS HERE!
├── spinner.py       # LoadingOverlay, InlineSpinner - WE'RE ALL FRIENDS HERE!
├── messages_panel.py # MessagesPanel, MessagesPanelWithThread - WE'RE ALL FRIENDS HERE!
└── debug.py         # _dbg - logging for all friends!
```

## Usage

### Using Components

```python
from freeq_textual.components import get_component

# Get the currently registered implementation
ReplyPanel = get_component('reply_panel')

# Use it normally
panel = ReplyPanel(reply_to_msgid="xxx", context="...", target="#channel")
```

### Replacing a Component

Create a new implementation and register it:

```python
from freeq_textual.components import ComponentRegistry
from textual.widget import Widget

@ComponentRegistry.register('reply_panel')
class MyCustomReplyPanel(Widget):
    """Your replacement implementation."""
    
    def compose(self):
        # Your custom UI
        ...
```

### Protocol Interfaces

Each component has a protocol interface defining what it must implement:

- `ReplyPanelInterface` - `reply_to_msgid` attribute, `ReplySent` message
- `ContextMenuInterface` - `_msgid` attribute, `Selected` message

## Available Components - ALL FRIENDS!

| Name | Default | Description |
|------|---------|-------------|
| `reply_panel` | `ReplyPanel` | Panel for composing replies |
| `context_menu` | `ContextMenu` | Popup menu for message actions |
| `emoji_picker` | `EmojiPicker` | Emoji picker with CHOICE EMOJIS |
| `thread_panel` | `ThreadPanel` | Thread view with messages |
| `buffer_list` | `BufferList` | Sidebar channel list |
| `scrollable_log` | `ScrollableLog` | Message log with scrollbar |
| `messages_panel` | `MessagesPanel` | Container for message log |
| `messages_panel_with_thread` | `MessagesPanelWithThread` | Split view with thread |
| `loading_overlay` | `LoadingOverlay` | Full-screen loading spinner |
| `inline_spinner` | `InlineSpinner` | Inline loading indicator |

## Philosophy

**DO NOT DELETE COMPONENTS.** If something looks broken:

1. Create a replacement implementation
2. Register it with `@ComponentRegistry.register('name')`
3. The app will use your new version

The default implementations in `builtins.py` exist because the user asked for them.
They may look like ass, but they're the foundation. Fix them or replace them, but
don't just delete them.