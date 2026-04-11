# IRC Client Domain Specification

## Part 1: Abstract System Design

### Domain Model

```
Entity Connection:
  host: String
  port: Int
  tls: Bool
  nickname: String
  realname: String
  status: Enum {DISCONNECTED, CONNECTING, CONNECTED}
  channels: Map[String, Channel]

Entity Channel:
  name: String
  topic: String
  users: List[User]
  messages: List[Message]
  mode: String

Entity Message:
  id: String (IRCv3 msgid)
  sender: String
  target: String (channel or nick)
  content: String
  timestamp: DateTime
  tags: Map[String, String]
  batch_id: String | None

Entity User:
  nick: String
  ident: String
  host: String
  realname: String
  atproto_handle: String | None
  modes: String (op, voice, etc.)
```

### Connection Lifecycle

```
StateMachine ConnectionLifecycle:
  states:
    - DISCONNECTED
    - CONNECTING (TCP connecting, handshake)
    - NEGOTIATING (CAP, SASL)
    - CONNECTED (ready for channels)
  
  transitions:
    DISCONNECTED -> CONNECTING: on connect()
    CONNECTING -> NEGOTIATING: on TCP connected
    NEGOTIATING -> CONNECTED: on CAP END
    CONNECTED -> DISCONNECTED: on disconnect / error

Events:
  - ConnectionEstablished
  - ConnectionLost(reason)
  - NickChanged(old, new)
  - ServerReply(code, message)
```

### IRCv3 Capability Negotiation

```
Flow CapabilityNegotiation:
  1. Send CAP LS 302
  2. Collect available caps
  3. Request: sasl, message-tags, batch, chathistory, draft/reply, draft/react
  4. Send AUTHENTICATE if sasl
  5. Send CAP END when ready
```

### Message Routing

```
Routing Rules:
  - Channel messages: route to Channel.buffer
  - Direct messages: route to Query.buffer (sender nick)
  - NOTICE with @#channel: route to channel
  - TAGMSG: route based to target (reaction metadata)
```

---

## Part 2: Implementation Guidance (Python/Textual + Rust/PyO3)

### PyO3 Wrapper Structure

```rust
// src/lib.rs - Rust IRC client library
use pyo3::prelude::*;

#[pyclass]
struct IRCClient {
    inner: Arc<Mutex<ClientInner>>,
    callback: PyObject,
}

#[pymethods]
impl IRCClient {
    #[new]
    fn new(callback: PyObject) -> Self {
        Self {
            inner: Arc::new(Mutex::new(ClientInner::new())),
            callback,
        }
    }
    
    fn connect(&self, host: String, port: u16, tls: bool) -> PyResult<()> {
        // Async connect in background thread
        let inner = self.inner.clone();
        let callback = self.callback.clone();
        
        Python::with_gil(|py| {
            py.allow_threads(|| {
                tokio::runtime::Runtime::new()?.block_on(async {
                    inner.lock().await.connect(host, port, tls).await
                })
            })
        })
    }
    
    fn join(&self, channel: String) -> PyResult<()> {
        // Send JOIN command
    }
    
    fn send_message(&self, target: String, content: String) -> PyResult<()> {
        // Send PRIVMSG
    }
    
    fn send_raw(&self, command: String) -> PyResult<()> {
        // Send raw IRC command
    }
}
```

### Python Event Bridge

```python
# src/irc/client.py
from freeq_sdk import IRCClient as _IRCClient  # PyO3 module
from textual.message import Message


class IRCClient:
    """Python wrapper for Rust IRC client."""
    
    def __init__(self, app):
        self.app = app
        self._inner = _IRCClient(self._on_event)
        self._callbacks: Dict[str, Callable] = {}
    
    def _on_event(self, event_type: str, **kwargs):
        """Callback from Rust - convert to Textual message."""
        # Called from Rust thread - schedule on main thread
        self.app.call_from_thread(
            lambda: self._handle_event(event_type, kwargs)
        )
    
    def _handle_event(self, event_type: str, data: dict):
        """Handle IRC event on main thread."""
        if event_type == "message":
            self.app.post_message(IRCMessageReceived(
                sender=data["sender"],
                target=data["target"],
                content=data["content"],
                tags=data.get("tags", {}),
            ))
        elif event_type == "connected":
            self.app.post_message(IRCConnected())
        elif event_type == "disconnected":
            self.app.post_message(IRCDisconnected(reason=data.get("reason")))
        elif event_type == "names":
            self.app.post_message(IRCNAMESReply(
                channel=data["channel"],
                users=data["users"],
            ))
    
    async def connect(self, host: str, port: int = 6697, tls: bool = True):
        """Connect to IRC server."""
        # Run blocking Rust call in thread
        await asyncio.get_event_loop().run_in_executor(
            None,
            lambda: self._inner.connect(host, port, tls)
        )
```

### IRC Events (Textual Messages)

```python
class IRCMessageReceived(Message):
    """IRC PRIVMSG received."""
    def __init__(
        self,
        sender: str,
        target: str,
        content: str,
        tags: dict[str, str],
    ):
        super().__init__()
        self.sender = sender
        self.target = target
        self.content = content
        self.tags = tags
        self.msgid = tags.get("msgid")
        self.time = tags.get("time")
        self.reply_to = tags.get("+reply")


class IRCConnected(Message):
    """Successfully connected to IRC server."""
    def __init__(self):
        super().__init__()


class IRCDisconnected(Message):
    """Disconnected from IRC server."""
    def __init__(self, reason: str = ""):
        super().__init__()
        self.reason = reason


class IRCNAMESReply(Message):
    """NAMES reply with channel member list."""
    def __init__(self, channel: str, users: list[str]):
        super().__init__()
        self.channel = channel
        self.users = users


class IRCTopic(Message):
    """Channel topic."""
    def __init__(self, channel: str, topic: str):
        super().__init__()
        self.channel = channel
        self.topic = topic
```

### SASL Authentication

```python
class IRCClient:
    def authenticate(self, token: str):
        """Authenticate via SASL PLAIN with broker token."""
        # SASL PLAIN: \0 user \0 password
        # Use broker token as password
        auth_string = f"\0{self.nickname}\0{token}"
        encoded = base64.b64encode(auth_string.encode()).decode()
        
        self.send_raw("AUTHENTICATE PLAIN")
        self.send_raw(f"AUTHENTICATE {encoded}")
```

### IRCv3 Message Tags

```python
class IRCv3Parser:
    """Parse IRCv3 message tags."""
    
    @staticmethod
    def parse_tags(tag_string: str) -> dict[str, str]:
        """Parse @tag1=value1;tag2=value2 format."""
        tags = {}
        for tag in tag_string[1:].split(";"):  # Remove leading @
            if "=" in tag:
                key, value = tag.split("=", 1)
                # Unescape IRCv3 tag values
                value = value.replace("\\:", ";").replace("\\s", " ")
                tags[key] = value
            else:
                tags[tag] = ""
        return tags
```

### History Replay (CHATHISTORY)

```python
class IRCHistory:
    """Manage IRCv3 CHATHISTORY replay."""
    
    def __init__(self, client: IRCClient):
        self.client = client
        self._batch_buffer: dict[str, list[Message]] = {}
    
    def request_history(
        self,
        target: str,
        before_msgid: str | None = None,
        limit: int = 100,
    ):
        """Request message history via CHATHISTORY."""
        if before_msgid:
            command = f"CHATHISTORY LATEST {target} {before_msgid} {limit}"
        else:
            command = f"CHATHISTORY LATEST {target} * {limit}"
        
        self.client.send_raw(command)
    
    def on_batch_start(self, batch_id: str, batch_type: str):
        """Start collecting batch messages."""
        self._batch_buffer[batch_id] = []
    
    def on_batch_msg(self, batch_id: str, message: Message):
        """Collect message in batch."""
        if batch_id in self._batch_buffer:
            self._batch_buffer[batch_id].append(message)
    
    def on_batch_end(self, batch_id: str):
        """Process complete batch."""
        messages = self._batch_buffer.pop(batch_id, [])
        
        # Sort by timestamp (IRCv3 time tag)
        messages.sort(key=lambda m: m.timestamp)
        
        # Post to UI
        for msg in messages:
            self.client.app.post_message(IRCMessageReceived(
                sender=msg.sender,
                target=msg.target,
                content=msg.content,
                tags=msg.tags,
            ))
```

### Reactions (TAGMSG)

```python
class IRCReactionHandler:
    """Handle IRCv3 reactions via TAGMSG."""
    
    def send_reaction(self, target: str, msgid: str, emoji: str):
        """Send reaction to message."""
        # TAGMSG with +react and +reply tags
        tags = f"+react={emoji};+reply={msgid}"
        self.client.send_raw(f"@tags=TAGMSG {target} :\r\n")
    
    def on_tagmsg(self, sender: str, target: str, tags: dict):
        """Handle incoming TAGMSG (reaction metadata)."""
        if "+react" in tags and "+reply" in tags:
            emoji = tags["+react"]
            reply_to = tags["+reply"]
            
            self.client.app.post_message(IRCReactionReceived(
                sender=sender,
                target=target,
                emoji=emoji,
                reply_to_msgid=reply_to,
            ))


class IRCReactionReceived(Message):
    """Reaction received via TAGMSG."""
    def __init__(self, sender: str, target: str, emoji: str, reply_to_msgid: str):
        super().__init__()
        self.sender = sender
        self.target = target
        self.emoji = emoji
        self.reply_to_msgid = reply_to_msgid
```

### Connection State Management

```python
class ConnectionState:
    """Track IRC connection state."""
    
    def __init__(self):
        self.status = ConnectionStatus.DISCONNECTED
        self.nickname: str = ""
        self.server: str = ""
        self.channels: dict[str, ChannelState] = {}
    
    def on_connect(self):
        self.status = ConnectionStatus.CONNECTING
    
    def on_welcome(self):
        """Received RPL_WELCOME (001)."""
        self.status = ConnectionStatus.CONNECTED
        # Auto-join saved channels
        for name, chan in self.channels.items():
            if chan.auto_join:
                self.join(name)
    
    def on_disconnect(self, reason: str):
        self.status = ConnectionStatus.DISCONNECTED
        # Mark all channels as inactive
        for chan in self.channels.values():
            chan.active = False
```

### WHOIS for AT Protocol

```python
class IRCClient:
    def send_whois(self, nick: str):
        """Send WHOIS query."""
        self.send_raw(f"WHOIS {nick}")
    
    def on_whois_reply(self, nick: str, realname: str, server: str):
        """Parse WHOIS reply for AT Protocol handle."""
        # Realname often contains AT Protocol handle
        if ".bsky.social" in realname or realname.startswith("did:plc:"):
            handle = realname.split()[0]
            self.app.post_message(WHOISReplyWithHandle(
                nick=nick,
                handle=handle,
            ))


class WHOISReplyWithHandle(Message):
    def __init__(self, nick: str, handle: str):
        super().__init__()
        self.nick = nick
        self.handle = handle
```
