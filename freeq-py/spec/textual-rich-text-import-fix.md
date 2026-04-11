# /home/nandi/code/freeq/freeq Py/spec/textual Rich Text Import Fix


## Requirements

# Textual RichText Import Correction

## Overview
Fix incorrect import statement for Rich Text class in Python-Textual generated code. The `Text` class used for styled text rendering comes from the `rich` library, not `textual`.

## Requirement: REQ-001 - Correct Rich Text Import Path
- Generated code SHALL import `Text` from `rich.text` module
- SHALL NOT import `Text` from `textual.text` (non-existent module)
- Import alias SHALL remain `RichText` for consistency with existing codebase

## Requirement: REQ-002 - Import Statement Format
- Import statement SHALL be: `from rich.text import Text as RichText`
- SHALL be placed after textual imports and before local module imports
- SHALL follow existing code style and formatting conventions

## Requirement: REQ-003 - Code Generator Template Update
- Phoenix code generator templates for Python-Textual SHALL use correct import path
- Templates generating styled text components SHALL reference `rich.text.Text`
- Generator SHALL validate that `rich` package is listed in project dependencies

## Requirement: REQ-004 - Dependency Verification
- Target project SHALL have `rich` package installed (required by Textual)
- If `rich` is not in direct dependencies, it SHALL be added explicitly
- Dependency version SHALL be compatible with installed Textual version

## Affected Files
- `/home/nandi/code/freeq/freeq-py/src/generated/widgets/message_item.py` - Line 16
- Other generated widgets using styled text rendering

## Implementation Note
The `Text` class from `rich.text` is used to create styled text segments with color and formatting:

