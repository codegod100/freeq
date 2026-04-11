# /home/nandi/code/freeq/freeq Py/spec/models App State Update


## Requirements

# Models AppState Update

## Overview
Update the `AppState` dataclass in `models.py` to include all fields required by the application, particularly the `session` field that is accessed during auto-login.

## Requirement: REQ-MODELS-001
- The `AppState` dataclass SHALL include a `session: SessionState` field with default factory `SessionState`.

## Requirement: REQ-MODELS-002
- The `AppState` dataclass SHALL include a `ui: UIState` field with default factory `UIState`.

## Requirement: REQ-MODELS-003
- The `AppState` dataclass SHALL include a `buffers: Dict[str, BufferState]` field with default factory `dict`.

## Requirement: REQ-MODELS-004
- The `AppState` dataclass SHALL include a `channels: Dict[str, List[UserState]]` field with default factory `dict`.

## Requirement: REQ-MODELS-005
- The `AppState` dataclass SHALL include an `auth_overlay_visible: bool` field defaulting to `True`.

## Requirement: REQ-MODELS-006
- The `AppState` dataclass SHALL maintain backward compatibility with existing `running: bool` and `poll_timer: Any` fields.

## Current Code

File: `src/generated/models.py`

Current `AppState`:

