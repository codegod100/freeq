# 🟢 GREEN: Reactions Domain (IU-f9f9717b)
# Description: Implements message reactions with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Add/remove reactions
#   2. Reaction counting
#   3. Reaction picker
#   4. Reaction display

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set

# === TYPES ===

@dataclass
class Reaction:
    """A single reaction."""
    emoji: str
    shortcode: Optional[str] = None
    count: int = 0
    users: Set[str] = field(default_factory=set)
    has_user_reacted: bool = False


@dataclass
class MessageReactions:
    """Reactions for a message."""
    msgid: str
    reactions: Dict[str, Reaction] = field(default_factory=dict)
    total_count: int = 0
    user_reactions: Set[str] = field(default_factory=set)


@dataclass
class Reactions:
    """Reactions domain entity."""
    id: str
    message_reactions: Dict[str, MessageReactions] = field(default_factory=dict)
    picker_open: bool = False
    picker_target_msgid: Optional[str] = None
    recent_emojis: List[str] = field(default_factory=list)


# === COMMON REACTION EMOJIS ===

COMMON_REACTIONS = ["👍", "👎", "❤️", "😂", "😮", "🎉", "🤔", "👀", "🔥", "✅", "❌"]


# === REACTIONS OPERATIONS ===

def process(item: Reactions) -> Reactions:
    """Process reactions and update counts."""
    return Reactions(
        id=item.id,
        message_reactions=dict(item.message_reactions),
        picker_open=item.picker_open,
        picker_target_msgid=item.picker_target_msgid,
        recent_emojis=item.recent_emojis.copy()
    )


def get_reactions_for_message(reactions: Reactions, msgid: str) -> MessageReactions:
    """Get reactions for a message."""
    return reactions.message_reactions.get(msgid, MessageReactions(msgid=msgid))


def add_reaction(reactions: Reactions, msgid: str, emoji: str, user: str) -> Reactions:
    """Add a reaction to a message."""
    new_msg_reactions = dict(reactions.message_reactions)
    
    if msgid not in new_msg_reactions:
        new_msg_reactions[msgid] = MessageReactions(msgid=msgid)
    
    msg_reactions = new_msg_reactions[msgid]
    new_reactions_dict = dict(msg_reactions.reactions)
    
    if emoji not in new_reactions_dict:
        new_reactions_dict[emoji] = Reaction(emoji=emoji, count=0, users=set())
    
    reaction = new_reactions_dict[emoji]
    new_users = reaction.users | {user}
    new_reactions_dict[emoji] = Reaction(
        emoji=emoji,
        shortcode=reaction.shortcode,
        count=len(new_users),
        users=new_users,
        has_user_reacted=user in new_users
    )
    
    new_user_reactions = msg_reactions.user_reactions | {emoji}
    
    new_msg_reactions[msgid] = MessageReactions(
        msgid=msgid,
        reactions=new_reactions_dict,
        total_count=sum(r.count for r in new_reactions_dict.values()),
        user_reactions=new_user_reactions
    )
    
    # Update recent emojis
    new_recent = [emoji] + [e for e in reactions.recent_emojis if e != emoji]
    new_recent = new_recent[:10]
    
    return Reactions(
        id=reactions.id,
        message_reactions=new_msg_reactions,
        picker_open=reactions.picker_open,
        picker_target_msgid=reactions.picker_target_msgid,
        recent_emojis=new_recent
    )


def remove_reaction(reactions: Reactions, msgid: str, emoji: str, user: str) -> Reactions:
    """Remove a reaction from a message."""
    if msgid not in reactions.message_reactions:
        return reactions
    
    new_msg_reactions = dict(reactions.message_reactions)
    msg_reactions = new_msg_reactions[msgid]
    
    if emoji not in msg_reactions.reactions:
        return reactions
    
    new_reactions_dict = dict(msg_reactions.reactions)
    reaction = new_reactions_dict[emoji]
    
    new_users = reaction.users - {user}
    
    if new_users:
        new_reactions_dict[emoji] = Reaction(
            emoji=emoji,
            shortcode=reaction.shortcode,
            count=len(new_users),
            users=new_users,
            has_user_reacted=False
        )
    else:
        del new_reactions_dict[emoji]
    
    new_user_reactions = msg_reactions.user_reactions - {emoji}
    
    new_msg_reactions[msgid] = MessageReactions(
        msgid=msgid,
        reactions=new_reactions_dict,
        total_count=sum(r.count for r in new_reactions_dict.values()),
        user_reactions=new_user_reactions
    )
    
    return Reactions(
        id=reactions.id,
        message_reactions=new_msg_reactions,
        picker_open=reactions.picker_open,
        picker_target_msgid=reactions.picker_target_msgid,
        recent_emojis=reactions.recent_emojis
    )


def toggle_reaction(reactions: Reactions, msgid: str, emoji: str, user: str) -> Reactions:
    """Toggle a reaction on/off."""
    msg_reactions = get_reactions_for_message(reactions, msgid)
    
    if emoji in msg_reactions.reactions and user in msg_reactions.reactions[emoji].users:
        return remove_reaction(reactions, msgid, emoji, user)
    else:
        return add_reaction(reactions, msgid, emoji, user)


def open_picker(reactions: Reactions, msgid: str) -> Reactions:
    """Open reaction picker for a message."""
    return Reactions(
        id=reactions.id,
        message_reactions=reactions.message_reactions,
        picker_open=True,
        picker_target_msgid=msgid,
        recent_emojis=reactions.recent_emojis
    )


def close_picker(reactions: Reactions) -> Reactions:
    """Close reaction picker."""
    return Reactions(
        id=reactions.id,
        message_reactions=reactions.message_reactions,
        picker_open=False,
        picker_target_msgid=None,
        recent_emojis=reactions.recent_emojis
    )


def format_reactions_for_display(reactions: MessageReactions) -> str:
    """Format reactions as display string."""
    parts = []
    for emoji, reaction in sorted(reactions.reactions.items(), key=lambda x: -x[1].count):
        if reaction.count > 1:
            parts.append(f"{emoji}{reaction.count}")
        else:
            parts.append(emoji)
    return " ".join(parts)


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "f9f9717b1642bcca7f6066156bd89c8c40c3666639356d5522387bbeff9213cc",
    "name": "Reactions Domain",
    "risk_tier": "low",
}
