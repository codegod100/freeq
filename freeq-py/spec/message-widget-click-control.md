# /home/nandi/code/freeq/freeq Py/spec/message Widget Click Control


## Requirements

# MessageWidget Click Event Control Fix

## Overview
Fix the Textual Message posting in `MessageWidget.on_click()` to properly include the `control` parameter, which is required for Textual's message propagation system to work correctly.

## Requirement: REQ-001 - MessageWidgetClicked Control Parameter
- SHALL update `MessageWidgetClicked.__init__()` to accept a `control` parameter with default value `None`
- SHALL pass `control=control` to `super().__init__()` call in `MessageWidgetClicked`
- SHALL preserve existing `message` and `is_own` parameters and their behavior

## Requirement: REQ-002 - on_click Control Passing
- SHALL update `MessageWidget.on_click()` to pass `control=self` when posting `MessageWidgetClicked`
- SHALL change `self.post_message(MessageWidgetClicked(...))` to include `control=self` in constructor
- SHALL ensure the posted message can be properly handled by parent widgets in the Textual DOM

## Requirement: REQ-003 - Message Class Documentation
- SHALL add docstring to `MessageWidgetClicked` explaining the `control` parameter purpose
- SHALL document that `control` must be the widget instance posting the message
- SHALL include example usage in docstring showing proper initialization

## Requirement: REQ-004 - Backward Compatibility
- SHALL ensure the fix maintains backward compatibility with existing message handlers
- SHALL verify that `@on(MessageWidgetClicked)` decorators continue to work
- SHALL ensure event data attributes (`message`, `is_own`) remain accessible on the event object

