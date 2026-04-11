# /home/nandi/code/freeq/freeq Py/spec/client Message Visibility


## Requirements

# Client Message Visibility Specification

## Overview

Ensures that messages sent by the client are immediately visible in the UI before server confirmation, providing responsive user feedback.

## Requirement: REQ-CMV-001 - Immediate Message Visibility
- SHALL The client MUST display sent messages immediately after the user submits them
- SHALL The delay between user sending a message and seeing it on screen MUST be less than 100ms
- SHALL The message MUST appear with the client's current nickname as sender
- SHALL The timestamp MUST reflect the local send time

## Requirement: REQ-CMV-002 - Reactive State Update Pattern
- SHALL After appending a message to `buffer.messages`, the code MUST trigger reactive updates
- SHALL The pattern SHALL be: `self.app_state.buffers = dict(self.app_state.buffers)`
- SHALL This trigger notifies all reactive watchers including MessageList
- SHALL The assignment MUST create a new dict object (not modify existing)

## Requirement: REQ-CMV-003 - Direct MessageList Refresh
- SHALL The `on_message_sent` handler MUST query the MessageList widget
- SHALL It MUST call `message_list.refresh_from_buffer()` after adding the message
- SHALL This call SHALL execute even if reactive updates are delayed
- SHALL The refresh_from_buffer() method SHALL reload messages from the active buffer

## Requirement: REQ-CMV-004 - Scroll to New Message
- SHALL After adding a new message, the MessageList SHALL scroll to show it
- SHALL The scroll SHOULD use `scroll_end(animate=False)` for immediate visibility
- SHALL The scroll position SHALL be at the bottom showing the newest message

## Requirement: REQ-CMV-005 - Preserve Existing Deduplication
- SHALL Server echoes of the client's own messages MUST be detected and skipped
- SHALL Deduplication SHALL compare sender nickname and message content
- SHALL The server echo handler SHALL NOT create duplicate entries in the message list
- SHALL The optimistic message displayed immediately SHALL be preserved

## Implementation Example


