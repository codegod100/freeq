# /home/nandi/code/freeq/freeq Py/spec/module Import Path Correction


## Requirements

# Code Generation Output Path Correction

## Problem Statement

The Phoenix code generation pipeline is incorrectly outputting generated Python files to a nested directory structure:
- **Current (Broken)**: `src/generated/src/generated/app.py`
- **Expected (Correct)**: `src/generated/app.py`

This causes `python -m src.generated.app` to fail with `ModuleNotFoundError: No module named src.generated.app` because:
1. The `__init__.py` is missing from `src/generated/` (top level)
2. The actual module files are nested at `src/generated/src/generated/`
3. Python's module resolution cannot find `src.generated.app` at the expected location

## Requirement: REQ-PATH-001 Correct Output Directory
- SHALL ensure all code generation output is written directly to `src/generated/`
- SHALL NOT create nested `src/generated/src/generated/` directory structure
- SHALL ensure the output path matches the expected Python package structure

## Requirement: REQ-PATH-002 Package Initialization File
- SHALL generate `src/generated/__init__.py` at the top level of the generated package
- SHALL include standard package exports in `__init__.py` for clean imports
- SHALL ensure `from src.generated import app` works without ImportError

## Requirement: REQ-PATH-003 Main Application Entry Point Location
- SHALL generate `src/generated/app.py` at the correct path (not nested)
- SHALL ensure `app.py` contains `if __name__ == "__main__":` block for module execution
- SHALL ensure `python -m src.generated.app` launches without ModuleNotFoundError

## Requirement: REQ-PATH-004 Data Models Location
- SHALL generate `src/generated/models.py` at the correct path (not nested)
- SHALL include all dataclass definitions as specified in codegen-instruction.md

## Requirement: REQ-PATH-005 Widget Components Location
- SHALL generate `src/generated/widgets/__init__.py` at the correct path
- SHALL generate all widget files directly in `src/generated/widgets/`:
  - `sidebar.py` - BufferSidebar widget
  - `message_list.py` - MessageList widget
  - `message_item.py` - MessageItem widget
  - `thread_panel.py` - ThreadPanel widget
  - `user_list.py` - UserList widget
  - `input_bar.py` - InputBar widget
  - `emoji_picker.py` - EmojiPicker widget
  - `debug_panel.py` - DebugPanel widget
  - `loading_overlay.py` - LoadingOverlay widget
  - `context_menu.py` - ContextMenu widget

## Requirement: REQ-PATH-006 Clean Up Nested Structure
- SHALL remove or avoid creating the nested `src/generated/src/` directory
- SHALL ensure no duplicate files exist in both correct and nested locations
- SHALL migrate any correctly-generated files from nested path to correct path

## Requirement: REQ-PATH-007 Import Path Verification
- SHALL verify that `python -c "from src.generated import app"` executes without ImportError
- SHALL verify that `python -c "from src.generated import models"` executes without ImportError
- SHALL verify that `python -c "from src.generated.widgets import sidebar"` executes without ImportError
- SHALL verify that `python -m src.generated.app --help` executes without ModuleNotFoundError

## Requirement: REQ-PATH-008 Codegen Pipeline Configuration
- SHALL fix the codegen output path configuration to prevent duplicate path segments
- SHALL ensure the output base path is `src/generated/` not `src/generated/src/generated/`
- SHALL validate output paths before writing files during code generation

## Success Criteria

- [ ] `src/generated/__init__.py` exists at the correct location
- [ ] `src/generated/app.py` exists at the correct location
- [ ] `src/generated/models.py` exists at the correct location
- [ ] `src/generated/widgets/` directory contains all widget files
- [ ] No nested `src/generated/src/` directory exists
- [ ] `python -m src.generated.app` launches without ModuleNotFoundError
- [ ] All widget imports work correctly from `src.generated.widgets`
- [ ] The codegen pipeline outputs to correct paths in future runs

## Implementation Priority

1. Fix codegen output path configuration to use correct base directory
2. Generate `src/generated/__init__.py` at top level
3. Generate `src/generated/app.py` at correct location
4. Generate `src/generated/models.py` at correct location
5. Generate all widget files in `src/generated/widgets/`
6. Clean up/remove nested `src/generated/src/` directory
7. Verify all imports work correctly

