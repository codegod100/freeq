# /home/nandi/code/freeq/freeq Py/spec/message Display Fix


## Requirements

# Message Display Fix Specification

## Overview

Fixes the issue where sent messages do not appear in the client UI immediately after sending. The message only appears after the server echoes it back, creating a poor user experience.

## Root Cause Analysis

The `on_message_sent` method in `FreeQApp` adds the message to the buffer's message list but fails to trigger a UI refresh. The reactive `app_state.buffers` update and `MessageList.refresh_from_buffer()` call are missing.

Current broken flow:
1. User sends message → `on_message_sent` called
2. Message added to `buffer.messages.append(msg)` only
3. NO reactive update triggered
4. NO MessageList refresh called
5. Message invisible until server echo triggers `_add_message_to_buffer` (which does both steps)

## Requirement: REQ-MDF-001 - Immediate UI Refresh on Send
- SHALL When `on_message_sent` adds a message to the buffer, it MUST trigger the reactive update pattern
- SHALL The implementation MUST assign `self.app_state.buffers = dict(self.app_state.buffers)` after modifying buffer.messages
- SHALL The implementation MUST call `message_list.refresh_from_buffer()` to immediately render the sent message
- SHALL The MessageList SHALL scroll to bottom after adding the new message
- SHALL The input bar SHALL be cleared after successful send (already implemented)

## Requirement: REQ-MDF-002 - Message Deduplication for Server Echo
- SHALL The existing deduplication logic in `_add_message_to_buffer` SHALL continue to skip duplicate server echoes
- SHALL When server echo arrives, if the message matches the recently sent optimistic message (same content, same sender), it SHALL be skipped
- SHALL The optimistic message displayed immediately SHALL remain in the UI when server echo is suppressed

## Implementation Pattern

In `on_message_sent` method, after `buffer.messages.append(msg)`:


