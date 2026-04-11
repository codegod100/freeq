# /home/nandi/code/freeq/freeq Py/spec/auto Login Data Fix


## Requirements

# Auto-Login Data Population Type Fix

## Overview
Fix type mismatch in `_populate_default_data()` method where `Message.sender` is incorrectly set to a string instead of a `User` object, causing `AttributeError` when UI code accesses User properties.

## Error Analysis

The traceback shows the error occurs at line 1110 in `app.py` when creating `BufferState`. The root cause is at line 1103 where `Message` is created with `sender="System"` (a string) instead of a `User` object:


