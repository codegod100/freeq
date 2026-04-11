# /home/nandi/code/freeq/freeq Py/spec/auto Login Session Null Fix


## Requirements

# Auto-Login Session Null Fix

## Overview
Fix critical bug where auto-login fails because `self.app_state.session` is `None` when trying to populate saved credentials on application mount.

## Error Analysis

The traceback shows:

