# Optimistic UI Implementation Fix

## Problem Statement

When a user sends a message to a channel, the message does not appear in the UI until the server echoes it back. This creates a noticeable delay and poor user experience.

## Root Cause

The `handle_submit` method in `app.py` only calls `self.client.send_message()` but does not:
1. Immediately add the message to the local buffer
2. Render the message before server confirmation
3. Implement deduplication for the server echo

## Requirement: REQ-OPT-IMPL-001 - Immediate Local Message Display
- SHALL When `handle_submit` sends a message via `client.send_message()`, it MUST immediately append the message to the target buffer
- SHALL The message MUST use the current client's nickname as the sender
- SHALL The message MUST include a generated temporary msgid for deduplication purposes
- SHALL The timestamp SHALL be the current local time in ISO 8601 format
- SHALL The implementation MUST call `self._append_line()` with the formatted message
- SHALL The implementation MUST call `self._render_active_buffer()` to refresh the UI
- SHALL The optimistic message SHALL be stored in `self.message_index` with a special flag `is_optimistic=True`

## Requirement: REQ-OPT-IMPL-002 - Optimistic Message Tracking
- SHALL The implementation SHALL store optimistic messages in `self._pending_optimistic: dict[str, str]` mapping temporary msgid -> content hash
- SHALL The content hash SHALL be computed as `hashlib.md5(text.encode()).hexdigest()[:16]`
- SHALL The temporary msgid SHALL follow the format: `optimistic-{counter}-{timestamp}` where counter increments per session
- SHALL Optimistic messages SHALL have a 30-second timeout after which they are considered failed

## Requirement: REQ-OPT-IMPL-003 - Server Echo Deduplication
- SHALL When a `message` event is received, the handler MUST check if the sender matches the current client's nickname
- SHALL If sender matches, the handler MUST compute the content hash of the received message
- SHALL The handler SHALL look up the content hash in `self._pending_optimistic`
- SHALL If a matching optimistic message is found, the handler MUST:
  - Replace the optimistic message entry in `message_index` with the server-confirmed msgid
  - Remove the entry from `self._pending_optimistic`
  - Skip appending a duplicate line to the buffer
  - Trigger a re-render to update the msgid associations
- SHALL If no matching optimistic message is found (e.g., server took too long), the message SHALL be displayed normally

## Requirement: REQ-OPT-IMPL-004 - Failed Message Handling
- SHALL If an optimistic message times out (30 seconds without server echo), it SHALL remain visible in the UI
- SHALL The message SHALL be marked with a visual indicator (dim styling or warning symbol)
- SHALL The user SHALL be able to retry sending failed messages via a context menu or command
- SHALL Failed messages SHALL be cleaned up from `self._pending_optimistic` after 60 seconds

## Implementation Guidance

### Step 1: Add Optimistic Tracking State

In `FreeqTextualApp.__init__`:
```python
self._pending_optimistic: dict[str, tuple[str, str, float]] = {}  # temp_msgid -> (content_hash, buffer_key, timestamp)
self._optimistic_counter: int = 0
```

### Step 2: Modify handle_submit

In `handle_submit` method, after `self.client.send_message()`:
```python
# Generate temporary msgid for optimistic UI
self._optimistic_counter += 1
temp_msgid = f"optimistic-{self._optimistic_counter}-{time.time()}"
content_hash = hashlib.md5(text.encode()).hexdigest()[:16]

# Store in pending optimistic
self._pending_optimistic[temp_msgid] = (content_hash, target, time.time())

# Create timestamp for the message
from datetime import datetime, timezone
timestamp = datetime.now(timezone.utc).isoformat()

# Store in message_index as optimistic
self.message_index[temp_msgid] = MessageState(
    buffer_key=self._buffer_key(target),
    sender=self.client.nick,
    text=text,
    thread_root=temp_msgid,
    msgid=temp_msgid,
    reply_to="",
    is_reply=False,
    timestamp=timestamp,
    is_streaming=False,
    mime_type="",
)

# Immediately append to buffer
self._append_line(
    target,
    self._format_message(self.client.nick, text),
    msgid=temp_msgid,
    line_meta=(self.client.nick, text, timestamp),
)
self._scroll_mode = "end"
self._render_active_buffer()
```

### Step 3: Modify Message Event Handler

In the `event_type == "message"` handler, before `self._record_message()`:
```python
# Check if this is our own message echoed back
sender_nick_key = self._nick_key(sender)
my_nick_key = self._nick_key(self.client.nick)
if sender_nick_key == my_nick_key:
    # Compute content hash
    content_hash = hashlib.md5(text.encode()).hexdigest()[:16]
    buffer_key = self._buffer_key(buffer_name)
    
    # Look for matching optimistic message
    matching_temp_id = None
    for temp_id, (hash_stored, buf_key, ts) in self._pending_optimistic.items():
        if hash_stored == content_hash and buf_key == buffer_key:
            matching_temp_id = temp_id
            break
    
    if matching_temp_id:
        # This is a server echo of our optimistic message
        _dbg(f"Server echo detected for optimistic message {matching_temp_id[:8]}")
        
        # Get the server msgid from tags
        server_msgid = tags.get("msgid", "")
        if server_msgid:
            # Update message_index: copy the optimistic entry to the real msgid
            old_state = self.message_index.pop(matching_temp_id)
            old_state.msgid = server_msgid
            old_state.thread_root = server_msgid  # Update thread_root too
            self.message_index[server_msgid] = old_state
            
            # Update any line_msgids that referenced the temp id
            for key in self._line_msgids:
                for i, mid in enumerate(self._line_msgids[key]):
                    if mid == matching_temp_id:
                        self._line_msgids[key][i] = server_msgid
        
        # Remove from pending
        del self._pending_optimistic[matching_temp_id]
        
        # Skip normal processing - message already displayed optimistically
        self._record_message(buffer_name, sender, text, tags)  # Still record for thread tracking
        return  # Don't append another line
```

### Step 4: Add Cleanup Timer

Add in `on_mount`:
```python
self.set_interval(10, self._cleanup_expired_optimistic)
```

Add method:
```python
def _cleanup_expired_optimistic(self) -> None:
    """Remove expired optimistic messages from tracking."""
    now = time.time()
    expired = [
        temp_id for temp_id, (_, _, ts) in self._pending_optimistic.items()
        if now - ts > 60  # 60 second timeout
    ]
    for temp_id in expired:
        del self._pending_optimistic[temp_id]
        # Mark the message as failed in message_index
        if temp_id in self.message_index:
            msg = self.message_index[temp_id]
            msg.is_streaming = False  # Could add a 'failed' flag to MessageState
        _dbg(f"Optimistic message {temp_id[:8]} expired")
```

## Testing Checklist

- [ ] Send a message in a channel - message appears immediately
- [ ] Server echo arrives - no duplicate message shown
- [ ] Send multiple messages rapidly - all appear immediately
- [ ] Switch channels while message pending - message appears in correct channel
- [ ] Disconnect while message pending - message marked as failed

## Related Specs

- See `optimistic-ui.md` for the original optimistic UI requirements
- See `messaging.md` for message handling and formatting requirements
