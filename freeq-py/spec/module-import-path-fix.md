# /home/nandi/code/freeq/freeq Py/spec/module Import Path Fix


## Requirements

# Module Import Path Fix

## Problem Description

The Phoenix code generation pipeline is outputting generated files to an incorrect nested path structure:
- **Current (Broken)**: `src/generated/src/generated/models.py`
- **Expected (Correct)**: `src/generated/models.py`

This causes `python -m src.generated.app` to fail with `ModuleNotFoundError: No module named src.generated.app` because:
1. The `__init__.py` is missing from `src/generated/`
2. `app.py` is not at the correct location
3. The nested `src/generated/src/` structure breaks Python's module resolution

## Root Cause Analysis

The code generation output path is being constructed with duplicate path segments, resulting in:

