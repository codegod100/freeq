# 🟢 GREEN: Channel Domain (IU-ebc1e473)
# Description: Implements IRC channel management with 6 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Join/part channel operations
#   2. Channel state management
#   3. User list management per channel
#   4. Topic tracking
#   5. Mode tracking (+n, +t, +i, etc.)
#   6. Federated channel support

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class ChannelMode(Enum):
    """IRC channel modes."""
    NO_EXTERNAL = "n"  # +n - no external messages
    TOPIC_PROTECT = "t"  # +t - only ops set topic
    INVITE_ONLY = "i"  # +i - invite only
    MODERATED = "m"  # +m - moderated
    PRIVATE = "p"  # +p - private
    SECRET = "s"  # +s - secret
    KEY = "k"  # +k - requires key
    LIMIT = "l"  # +l - user limit


@dataclass
class Channel:
    """Channel domain entity."""
    id: str  # Internal ID
    name: str  # Channel name (e.g., #general)
    topic: str = ""
    topic_set_by: Optional[str] = None
    topic_set_at: Optional[datetime] = None
    modes: Set[str] = field(default_factory=set)
    users: Dict[str, 'ChannelUser'] = field(default_factory=dict)
    operators: Set[str] = field(default_factory=set)
    voiced: Set[str] = field(default_factory=set)
    banned: Set[str] = field(default_factory=set)
    invited: Set[str] = field(default_factory=set)
    key: Optional[str] = None
    user_limit: Optional[int] = None
    is_federated: bool = False
    network_id: Optional[str] = None
    joined: bool = False
    joined_at: Optional[datetime] = None
    unread_count: int = 0
    highlight_count: int = 0
    last_activity: Optional[datetime] = None


@dataclass
class ChannelUser:
    """User within a channel context."""
    nickname: str
    did: Optional[str] = None
    ident: Optional[str] = None
    hostname: Optional[str] = None
    is_operator: bool = False
    is_voiced: bool = False
    joined_at: Optional[datetime] = None
    is_away: bool = False


# === CHANNEL OPERATIONS ===

def process(item: Channel) -> Channel:
    """Process channel state and normalize data.
    
    Ensures all computed fields are up to date.
    """
    # Count users
    user_count = len(item.users)
    op_count = len(item.operators)
    
    # Return normalized channel
    return Channel(
        id=item.id,
        name=item.name,
        topic=item.topic,
        topic_set_by=item.topic_set_by,
        topic_set_at=item.topic_set_at,
        modes=item.modes.copy(),
        users=dict(item.users),
        operators=item.operators.copy(),
        voiced=item.voiced.copy(),
        banned=item.banned.copy(),
        invited=item.invited.copy(),
        key=item.key,
        user_limit=item.user_limit,
        is_federated=item.is_federated,
        network_id=item.network_id,
        joined=item.joined,
        joined_at=item.joined_at,
        unread_count=item.unread_count,
        highlight_count=item.highlight_count,
        last_activity=item.last_activity or datetime.now()
    )


def join_channel(channel: Channel, nickname: str, did: Optional[str] = None) -> Channel:
    """Mark a user as joining a channel."""
    if nickname in channel.users:
        return channel
    
    new_users = dict(channel.users)
    new_users[nickname] = ChannelUser(
        nickname=nickname,
        did=did,
        joined_at=datetime.now()
    )
    
    return Channel(
        id=channel.id,
        name=channel.name,
        topic=channel.topic,
        topic_set_by=channel.topic_set_by,
        topic_set_at=channel.topic_set_at,
        modes=channel.modes.copy(),
        users=new_users,
        operators=channel.operators.copy(),
        voiced=channel.voiced.copy(),
        banned=channel.banned.copy(),
        invited=channel.invited.copy(),
        key=channel.key,
        user_limit=channel.user_limit,
        is_federated=channel.is_federated,
        network_id=channel.network_id,
        joined=True,
        joined_at=channel.joined_at or datetime.now(),
        unread_count=channel.unread_count,
        highlight_count=channel.highlight_count,
        last_activity=datetime.now()
    )


def part_channel(channel: Channel, nickname: str) -> Channel:
    """Mark a user as leaving a channel."""
    if nickname not in channel.users:
        return channel
    
    new_users = dict(channel.users)
    del new_users[nickname]
    
    new_ops = channel.operators - {nickname}
    new_voiced = channel.voiced - {nickname}
    
    return Channel(
        id=channel.id,
        name=channel.name,
        topic=channel.topic,
        topic_set_by=channel.topic_set_by,
        topic_set_at=channel.topic_set_at,
        modes=channel.modes.copy(),
        users=new_users,
        operators=new_ops,
        voiced=new_voiced,
        banned=channel.banned.copy(),
        invited=channel.invited.copy(),
        key=channel.key,
        user_limit=channel.user_limit,
        is_federated=channel.is_federated,
        network_id=channel.network_id,
        joined=channel.joined and len(new_users) > 0,
        joined_at=channel.joined_at,
        unread_count=channel.unread_count,
        highlight_count=channel.highlight_count,
        last_activity=datetime.now()
    )


def set_topic(channel: Channel, topic: str, set_by: str) -> Channel:
    """Set channel topic."""
    return Channel(
        id=channel.id,
        name=channel.name,
        topic=topic,
        topic_set_by=set_by,
        topic_set_at=datetime.now(),
        modes=channel.modes.copy(),
        users=channel.users,
        operators=channel.operators.copy(),
        voiced=channel.voiced.copy(),
        banned=channel.banned.copy(),
        invited=channel.invited.copy(),
        key=channel.key,
        user_limit=channel.user_limit,
        is_federated=channel.is_federated,
        network_id=channel.network_id,
        joined=channel.joined,
        joined_at=channel.joined_at,
        unread_count=channel.unread_count,
        highlight_count=channel.highlight_count,
        last_activity=datetime.now()
    )


def set_mode(channel: Channel, mode: str, value: bool = True) -> Channel:
    """Set or unset a channel mode."""
    new_modes = channel.modes.copy()
    if value:
        new_modes.add(mode)
    else:
        new_modes.discard(mode)
    
    return Channel(
        id=channel.id,
        name=channel.name,
        topic=channel.topic,
        topic_set_by=channel.topic_set_by,
        topic_set_at=channel.topic_set_at,
        modes=new_modes,
        users=channel.users,
        operators=channel.operators.copy(),
        voiced=channel.voiced.copy(),
        banned=channel.banned.copy(),
        invited=channel.invited.copy(),
        key=channel.key,
        user_limit=channel.user_limit,
        is_federated=channel.is_federated,
        network_id=channel.network_id,
        joined=channel.joined,
        joined_at=channel.joined_at,
        unread_count=channel.unread_count,
        highlight_count=channel.highlight_count,
        last_activity=channel.last_activity
    )


def add_operator(channel: Channel, nickname: str) -> Channel:
    """Grant operator status to a user."""
    new_ops = channel.operators | {nickname}
    new_users = dict(channel.users)
    
    if nickname in new_users:
        new_users[nickname] = ChannelUser(
            nickname=nickname,
            did=new_users[nickname].did,
            ident=new_users[nickname].ident,
            hostname=new_users[nickname].hostname,
            is_operator=True,
            is_voiced=new_users[nickname].is_voiced,
            joined_at=new_users[nickname].joined_at,
            is_away=new_users[nickname].is_away
        )
    
    return Channel(
        id=channel.id,
        name=channel.name,
        topic=channel.topic,
        topic_set_by=channel.topic_set_by,
        topic_set_at=channel.topic_set_at,
        modes=channel.modes.copy(),
        users=new_users,
        operators=new_ops,
        voiced=channel.voiced.copy(),
        banned=channel.banned.copy(),
        invited=channel.invited.copy(),
        key=channel.key,
        user_limit=channel.user_limit,
        is_federated=channel.is_federated,
        network_id=channel.network_id,
        joined=channel.joined,
        joined_at=channel.joined_at,
        unread_count=channel.unread_count,
        highlight_count=channel.highlight_count,
        last_activity=channel.last_activity
    )


def remove_operator(channel: Channel, nickname: str) -> Channel:
    """Revoke operator status from a user."""
    new_ops = channel.operators - {nickname}
    new_users = dict(channel.users)
    
    if nickname in new_users:
        new_users[nickname] = ChannelUser(
            nickname=nickname,
            did=new_users[nickname].did,
            ident=new_users[nickname].ident,
            hostname=new_users[nickname].hostname,
            is_operator=False,
            is_voiced=new_users[nickname].is_voiced,
            joined_at=new_users[nickname].joined_at,
            is_away=new_users[nickname].is_away
        )
    
    return Channel(
        id=channel.id,
        name=channel.name,
        topic=channel.topic,
        topic_set_by=channel.topic_set_by,
        topic_set_at=channel.topic_set_at,
        modes=channel.modes.copy(),
        users=new_users,
        operators=new_ops,
        voiced=channel.voiced.copy(),
        banned=channel.banned.copy(),
        invited=channel.invited.copy(),
        key=channel.key,
        user_limit=channel.user_limit,
        is_federated=channel.is_federated,
        network_id=channel.network_id,
        joined=channel.joined,
        joined_at=channel.joined_at,
        unread_count=channel.unread_count,
        highlight_count=channel.highlight_count,
        last_activity=channel.last_activity
    )


def can_join(channel: Channel, nickname: str, is_invited: bool = False) -> tuple[bool, Optional[str]]:
    """Check if a user can join the channel.
    
    Returns (can_join, error_message)
    """
    # Check if banned
    if nickname in channel.banned:
        return False, "Cannot join channel (+b)"
    
    # Check invite-only
    if "i" in channel.modes and not is_invited and nickname not in channel.invited:
        return False, "Cannot join channel (+i)"
    
    # Check user limit
    if "l" in channel.modes and channel.user_limit:
        if len(channel.users) >= channel.user_limit:
            return False, "Channel is full (+l)"
    
    return True, None


def is_valid_channel_name(name: str) -> bool:
    """Check if a string is a valid channel name."""
    if not name:
        return False
    
    # Must start with #, &, +, or !
    if name[0] not in "#&+!":
        return False
    
    # Cannot contain spaces, commas, or control characters
    invalid_chars = " ,\x07"
    if any(c in name for c in invalid_chars):
        return False
    
    return True


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "ebc1e473e5017fa4ae86e3e0f14c85b16a73cbaeef0a8739fdfb2e66a397a83c",
    "name": "Channel Domain",
    "risk_tier": "high",
}
