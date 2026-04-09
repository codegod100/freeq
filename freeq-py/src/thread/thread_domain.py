# 🟢 GREEN: Thread Domain (IU-1f347051)
# Description: Implements conversation threading with 13 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Thread creation from message
#   2. Thread participant tracking
#   3. Thread message ordering (chronological)
#   4. Thread panel UI
#   5. Thread reply functionality
#   6. Thread unread count
#   7. Thread subscription/unsubscription
#   8. Thread depth limiting
#   9. Thread collapse/expand
#   10. Thread search/filtering
#   11. Thread participant presence
#   12. Thread moderation
#   13. Thread archival

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class ThreadStatus(Enum):
    """Thread status."""
    ACTIVE = auto()
    MUTED = auto()
    ARCHIVED = auto()
    PINNED = auto()


@dataclass
class ThreadMessage:
    """Message within a thread."""
    msgid: str
    sender_did: Optional[str]
    sender_nick: str
    content: str
    timestamp: datetime
    reply_to: Optional[str] = None  # Parent msgid in thread
    depth: int = 0
    reactions: Dict[str, List[str]] = field(default_factory=dict)
    edited_at: Optional[datetime] = None
    deleted: bool = False


@dataclass
class ThreadParticipant:
    """Participant in a thread."""
    did: str
    nickname: str
    joined_at: datetime
    last_read_msgid: Optional[str] = None
    is_present: bool = True
    is_subscribed: bool = True


@dataclass
class Thread:
    """Thread domain entity."""
    id: str
    root_msgid: str  # Original message that started the thread
    channel_id: str
    topic: str = ""
    status: ThreadStatus = ThreadStatus.ACTIVE
    messages: Dict[str, ThreadMessage] = field(default_factory=dict)
    message_order: List[str] = field(default_factory=list)  # Chronological order
    participants: Dict[str, ThreadParticipant] = field(default_factory=dict)
    created_at: datetime = field(default_factory=datetime.now)
    last_activity: datetime = field(default_factory=datetime.now)
    unread_count: int = 0
    total_replies: int = 0
    max_depth: int = 10
    collapsed: bool = False
    archived_at: Optional[datetime] = None


# === THREAD OPERATIONS ===

def process(item: Thread) -> Thread:
    """Process thread and update computed fields."""
    # Recalculate total replies
    total = len([m for m in item.messages.values() if not m.deleted])
    
    # Update unread count
    unread = sum(
        1 for msgid in item.message_order
        if msgid in item.messages and not item.messages[msgid].deleted
    )
    
    # Count unique participants
    participants = set(item.participants.keys())
    for msg in item.messages.values():
        if msg.sender_did:
            participants.add(msg.sender_did)
    
    return Thread(
        id=item.id,
        root_msgid=item.root_msgid,
        channel_id=item.channel_id,
        topic=item.topic,
        status=item.status,
        messages=dict(item.messages),
        message_order=item.message_order.copy(),
        participants=dict(item.participants),
        created_at=item.created_at,
        last_activity=item.last_activity,
        unread_count=unread,
        total_replies=total,
        max_depth=item.max_depth,
        collapsed=item.collapsed,
        archived_at=item.archived_at
    )


def create_thread(root_msgid: str, channel_id: str, topic: str = "") -> Thread:
    """Create a new thread from a root message."""
    return Thread(
        id=f"thread_{root_msgid}",
        root_msgid=root_msgid,
        channel_id=channel_id,
        topic=topic,
        status=ThreadStatus.ACTIVE,
        messages={},
        message_order=[],
        participants={},
        created_at=datetime.now(),
        last_activity=datetime.now(),
        unread_count=0,
        total_replies=0
    )


def add_message(thread: Thread, message: ThreadMessage) -> Thread:
    """Add a message to the thread."""
    if message.msgid in thread.messages:
        return thread
    
    # Calculate depth
    depth = 0
    if message.reply_to and message.reply_to in thread.messages:
        parent = thread.messages[message.reply_to]
        depth = parent.depth + 1
    
    # Cap depth
    depth = min(depth, thread.max_depth)
    
    # Create new message with depth
    new_message = ThreadMessage(
        msgid=message.msgid,
        sender_did=message.sender_did,
        sender_nick=message.sender_nick,
        content=message.content,
        timestamp=message.timestamp,
        reply_to=message.reply_to,
        depth=depth,
        reactions=message.reactions.copy(),
        edited_at=message.edited_at,
        deleted=message.deleted
    )
    
    new_messages = dict(thread.messages)
    new_messages[message.msgid] = new_message
    
    new_order = thread.message_order.copy()
    new_order.append(message.msgid)
    
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=thread.status,
        messages=new_messages,
        message_order=new_order,
        participants=thread.participants.copy(),
        created_at=thread.created_at,
        last_activity=datetime.now(),
        unread_count=thread.unread_count + 1,
        total_replies=thread.total_replies + 1,
        max_depth=thread.max_depth,
        collapsed=thread.collapsed,
        archived_at=thread.archived_at
    )


def delete_message(thread: Thread, msgid: str) -> Thread:
    """Soft delete a message from the thread."""
    if msgid not in thread.messages:
        return thread
    
    new_messages = dict(thread.messages)
    msg = new_messages[msgid]
    new_messages[msgid] = ThreadMessage(
        msgid=msg.msgid,
        sender_did=msg.sender_did,
        sender_nick=msg.sender_nick,
        content="[deleted]",
        timestamp=msg.timestamp,
        reply_to=msg.reply_to,
        depth=msg.depth,
        reactions=msg.reactions,
        edited_at=msg.edited_at,
        deleted=True
    )
    
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=thread.status,
        messages=new_messages,
        message_order=thread.message_order.copy(),
        participants=thread.participants.copy(),
        created_at=thread.created_at,
        last_activity=thread.last_activity,
        unread_count=thread.unread_count,
        total_replies=thread.total_replies - 1,
        max_depth=thread.max_depth,
        collapsed=thread.collapsed,
        archived_at=thread.archived_at
    )


def add_participant(thread: Thread, did: str, nickname: str, is_subscribed: bool = True) -> Thread:
    """Add a participant to the thread."""
    new_participants = dict(thread.participants)
    new_participants[did] = ThreadParticipant(
        did=did,
        nickname=nickname,
        joined_at=datetime.now(),
        last_read_msgid=None,
        is_present=True,
        is_subscribed=is_subscribed
    )
    
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=thread.status,
        messages=thread.messages,
        message_order=thread.message_order.copy(),
        participants=new_participants,
        created_at=thread.created_at,
        last_activity=thread.last_activity,
        unread_count=thread.unread_count,
        total_replies=thread.total_replies,
        max_depth=thread.max_depth,
        collapsed=thread.collapsed,
        archived_at=thread.archived_at
    )


def remove_participant(thread: Thread, did: str) -> Thread:
    """Remove a participant from the thread."""
    new_participants = dict(thread.participants)
    if did in new_participants:
        del new_participants[did]
    
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=thread.status,
        messages=thread.messages,
        message_order=thread.message_order.copy(),
        participants=new_participants,
        created_at=thread.created_at,
        last_activity=thread.last_activity,
        unread_count=thread.unread_count,
        total_replies=thread.total_replies,
        max_depth=thread.max_depth,
        collapsed=thread.collapsed,
        archived_at=thread.archived_at
    )


def mark_read(thread: Thread, did: str, msgid: str) -> Thread:
    """Mark messages as read up to msgid for participant."""
    new_participants = dict(thread.participants)
    
    if did in new_participants:
        participant = new_participants[did]
        new_participants[did] = ThreadParticipant(
            did=participant.did,
            nickname=participant.nickname,
            joined_at=participant.joined_at,
            last_read_msgid=msgid,
            is_present=participant.is_present,
            is_subscribed=participant.is_subscribed
        )
    
    # Recalculate unread
    unread = 0
    for msg_id in thread.message_order:
        if msg_id in thread.messages and not thread.messages[msg_id].deleted:
            all_read = all(
                p.last_read_msgid and p.last_read_msgid >= msg_id
                for p in new_participants.values()
            )
            if not all_read:
                unread += 1
    
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=thread.status,
        messages=thread.messages,
        message_order=thread.message_order.copy(),
        participants=new_participants,
        created_at=thread.created_at,
        last_activity=thread.last_activity,
        unread_count=unread,
        total_replies=thread.total_replies,
        max_depth=thread.max_depth,
        collapsed=thread.collapsed,
        archived_at=thread.archived_at
    )


def toggle_collapse(thread: Thread) -> Thread:
    """Toggle thread collapse state."""
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=thread.status,
        messages=thread.messages,
        message_order=thread.message_order.copy(),
        participants=thread.participants.copy(),
        created_at=thread.created_at,
        last_activity=thread.last_activity,
        unread_count=thread.unread_count,
        total_replies=thread.total_replies,
        max_depth=thread.max_depth,
        collapsed=not thread.collapsed,
        archived_at=thread.archived_at
    )


def archive_thread(thread: Thread) -> Thread:
    """Archive the thread."""
    return Thread(
        id=thread.id,
        root_msgid=thread.root_msgid,
        channel_id=thread.channel_id,
        topic=thread.topic,
        status=ThreadStatus.ARCHIVED,
        messages=thread.messages,
        message_order=thread.message_order.copy(),
        participants=thread.participants.copy(),
        created_at=thread.created_at,
        last_activity=thread.last_activity,
        unread_count=thread.unread_count,
        total_replies=thread.total_replies,
        max_depth=thread.max_depth,
        collapsed=True,
        archived_at=datetime.now()
    )


def get_messages_chronological(thread: Thread) -> List[ThreadMessage]:
    """Get thread messages in chronological order."""
    return [
        thread.messages[msgid]
        for msgid in thread.message_order
        if msgid in thread.messages
    ]


def get_message_tree(thread: Thread, root_msgid: Optional[str] = None) -> Dict[str, List[str]]:
    """Get thread as a tree structure.
    
    Returns dict mapping parent msgid to list of child msgids.
    """
    tree: Dict[str, List[str]] = {root_msgid or thread.root_msgid: []}
    
    for msgid, msg in thread.messages.items():
        parent = msg.reply_to or (root_msgid or thread.root_msgid)
        if parent not in tree:
            tree[parent] = []
        tree[parent].append(msgid)
    
    return tree


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "1f347051be51e47aada4bce6d98f733fc5768a7ca8de52ef406cbcff6a468333",
    "name": "Thread Domain",
    "risk_tier": "high",
}
