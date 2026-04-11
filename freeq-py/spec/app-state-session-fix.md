# /home/nandi/code/freeq/freeq Py/spec/app State Session Fix


## Requirements

# AppState Session Field Fix

## Overview
Fix critical `AttributeError` where `AppState` dataclass is missing the `session` field that code in `app.py` attempts to access during auto-login, causing the application to crash on startup when saved credentials exist.

## Error Analysis

The traceback shows:

