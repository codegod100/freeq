# /home/nandi/code/freeq/freeq Py/spec/codegen Completion Fix


## Requirements

# Code Generation Completion Fix

## Overview
The Phoenix code generation pipeline has a partial/incomplete state where `src/generated/` contains only a `widgets/` subdirectory but is missing all critical application files. The `python -m src.generated.app` command fails with `No module named src.generated.app` because `app.py` does not exist in the generated output.

## Current State Analysis

- Pipeline status shows `codegen: complete` but output is incomplete
- `src/generated/` exists but contains ONLY: `widgets/` subdirectory
- `src/generated/__init__.py` is MISSING (package not importable)
- `src/generated/app.py` is MISSING (main entry point absent)
- `src/generated/models.py` is MISSING (data models absent)
- `src/generated/screens/` is MISSING (UI screens absent)
- All domain modules are MISSING (authentication/, broker/, channel/, etc.)
- Backup directory `src/generated.backup.1775807805/` contains complete valid code

## Requirement: REQ-CGF-001 Package Structure
- SHALL ensure `src/generated/__init__.py` exists to make `src.generated` a valid Python package
- SHALL include standard package exports in `__init__.py` for clean imports

## Requirement: REQ-CGF-002 Main Application Entry Point
- SHALL generate `src/generated/app.py` as the main application entry point
- SHALL ensure `app.py` contains `if __name__ == "__main__":` block for `python -m src.generated.app` execution
- SHALL ensure `app.py` includes the `FreeQApp` class with proper Textual App inheritance

## Requirement: REQ-CGF-003 Data Models
- SHALL generate `src/generated/models.py` with all dataclass definitions
- SHALL include AppState, Session, UIState, BufferState, ChannelState, Message, User, Thread models
- SHALL ensure all models use correct field names per Phoenix canonical requirements

## Requirement: REQ-CGF-004 Domain Modules
- SHALL generate all domain subdirectories in `src/generated/`:
  - authentication/ - OAuth and credential management
  - broker/ - Connection broker integration
  - buffer/ - Message buffer management
  - channel/ - Channel state and operations
  - cli/ - Command line interface handling
  - component/ - UI component management
  - connection/ - IRC connection management
  - content/ - Content rendering
  - debug/ - Debug utilities
  - definitions/ - Type definitions
  - displaying/ - Message display logic
  - emoji/ - Emoji support
  - event/ - Event handling
  - feature/ - Feature flags
  - history/ - Message history
  - input/ - Input handling
  - keyboard/ - Keyboard shortcuts
  - layout/ - UI layout management
  - lazy/ - Lazy loading
  - loading/ - Loading states
  - message/ - Message domain
  - raw/ - Raw protocol handling
  - reactions/ - Message reactions
  - rendering/ - Text rendering
  - reply/ - Reply handling
  - requirements/ - Requirements domain
  - screens/ - Textual screens (AuthScreen, etc.)
  - sending/ - Message sending
  - session/ - Session management
  - state/ - State management
  - streaming/ - Streaming content
  - thread/ - Thread management
  - url/ - URL handling
  - user/ - User domain
  - whois/ - WHOIS handling

## Requirement: REQ-CGF-005 UI Components
- SHALL generate `src/generated/widgets/` with all widget implementations:
  - BufferSidebar with reactive watch_buffers method
  - MessageList with message display capabilities
  - InputBar for user input
  - UserList for channel user display
  - LoadingOverlay for loading states
  - MessageItem for individual message rendering
  - DebugPanel for debug information
  - ContextMenu for right-click actions
  - EmojiPicker for emoji selection
  - ThreadPanel for thread display

## Requirement: REQ-CGF-006 Screen Components
- SHALL generate `src/generated/screens/` directory with:
  - AuthScreen for authentication UI
  - All screen classes referenced in app.py

## Requirement: REQ-CGF-007 Import Path Compatibility
- SHALL ensure all internal imports use relative imports (e.g., `from .models import ...`)
- SHALL ensure `app.py` can be executed via `python -m src.generated.app`
- SHALL ensure no broken import references exist in generated code

## Requirement: REQ-CGF-008 Verification
- SHALL verify that `python -c "from src.generated import app"` executes without ImportError
- SHALL verify that `python -m src.generated.app --help` executes without ModuleNotFoundError
- SHALL verify all domain modules are importable without errors

## Implementation Priority
1. Generate `__init__.py` to establish package validity
2. Generate `app.py` for main entry point
3. Generate `models.py` for data layer
4. Generate all domain modules
5. Generate screens/ and complete widgets/
6. Verify all imports work correctly

## Success Criteria
- `python -m src.generated.app` launches the application without `ModuleNotFoundError`
- All Phoenix canonical requirements from `.phoenix/canonical.md` are reflected in generated code
- Generated code matches structure and patterns from `src/generated.backup.1775807805/`

