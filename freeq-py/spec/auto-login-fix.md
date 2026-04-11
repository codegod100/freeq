# Auto-Login Data Population Fix

## Overview
Fix type mismatch in `_populate_default_data()` where `Message.sender` is set to a string instead of a `User` object, causing potential runtime errors when UI code accesses User properties on the sender.

## Requirement: REQ-AUTOLOGIN-001
- SHALL Create a proper `User` object for the system message sender instead of using a string
- SHALL Set `User.nick` to "System" for the welcome message sender
- SHALL Set `User.atproto_handle` to an empty string for system messages

## Requirement: REQ-AUTOLOGIN-002
- SHALL Create a proper `User` object for the self-user in `_populate_default_data()` with:
  - `nick` derived from the authenticated user's nick parameter (without domain suffix if present)
  - `atproto_handle` set to the authenticated user's handle parameter

## Requirement: REQ-AUTOLOGIN-003
- SHALL Update the welcome message creation to use the system User object as sender:
  ```python
  system_user = User(nick="System", atproto_handle="")
  welcome_msg = Message(
      id="welcome-1",
      sender=system_user,  # User object, not string
      target="console",
      content=f"Welcome to FreeQ, {nick}! You are now authenticated as {handle}",
      timestamp=datetime.now(),
  )
  ```

## Requirement: REQ-AUTOLOGIN-004
- SHALL Update the self-user creation to use proper User object:
  ```python
  self_user = User(
      nick=nick.split(".")[0] if "." in nick else nick,
      atproto_handle=handle,
  )
  ```

## Requirement: REQ-AUTOLOGIN-005
- SHALL Ensure all `Message` instances created in `_populate_default_data()` use `User` objects for the `sender` field to match the `Message` dataclass schema

## Requirement: REQ-AUTOLOGIN-006
- SHALL Verify that `ChannelState.users` dictionary uses string nicks as keys and `User` objects as values

## Background

The `Message` dataclass in `models.py` defines:
```python
@dataclass(slots=True)
class Message:
    sender: User = field(default_factory=User)  # NOT a string
    ...
```

However, in `app.py` line 1103, the code was incorrectly passing a string:
```python
welcome_msg = Message(
    id="welcome-1",
    sender="System",  # BUG: Should be a User object
    target="console",
    ...
)
```

This type mismatch causes issues when code expects `message.sender` to have User properties like `.nick`, `.atproto_handle`, etc.

## Verification
- After fix, `Message.sender` must always be a `User` instance
- After fix, `welcome_msg.sender.nick` should return "System"
- After fix, `welcome_msg.sender.atproto_handle` should return ""
