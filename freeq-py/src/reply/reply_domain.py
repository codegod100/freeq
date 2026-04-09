# 🟢 GREEN: Reply Domain (IU-42e6a5d5)
# Description: Implements reply threading UI with 3 requirements
# Risk Tier: CRITICAL
# Requirements:
#   1. Render reply indicators showing parent message author
#   2. Support reply-to-message functionality
#   3. Display reply threading UI

from dataclasses import dataclass, field
from typing import Optional, List, Dict
from datetime import datetime

# === TYPES ===

@dataclass
class ReplyTarget:
    """Represents a message being replied to."""
    msgid: str
    sender_nick: str
    sender_did: Optional[str]
    content: str
    timestamp: datetime
    preview: str = ""  # Truncated preview of parent message


@dataclass
class Reply:
    """Reply domain entity representing a reply state."""
    id: str
    reply_to: Optional[ReplyTarget] = None
    thread_root: Optional[str] = None  # Root msgid of thread
    reply_count: int = 0
    reply_chain: List[str] = field(default_factory=list)  # List of msgids in thread
    indicator_visible: bool = False
    indicator_text: str = ""


# === REPLY PROCESSING ===

def create_reply_target(
    msgid: str,
    sender_nick: str,
    content: str,
    sender_did: Optional[str] = None,
    timestamp: Optional[datetime] = None
) -> ReplyTarget:
    """Create a reply target from message data.
    
    Creates a truncated preview of the parent message for display.
    """
    preview = content[:50] + "..." if len(content) > 50 else content
    
    return ReplyTarget(
        msgid=msgid,
        sender_nick=sender_nick,
        sender_did=sender_did,
        content=content,
        timestamp=timestamp or datetime.now(),
        preview=preview
    )


def format_reply_indicator(reply_to: ReplyTarget) -> str:
    """Format a reply indicator showing the parent message author.
    
    Returns formatted text like "↳ Reply to @alice: hello world..."
    """
    return f"↳ Reply to @{reply_to.sender_nick}: {reply_to.preview}"


# === GREEN IMPLEMENTATIONS ===

def process(item: Reply) -> Reply:
    """Process reply state and generate indicators.
    
    Transforms the Reply by calculating indicator text and visibility
    based on the reply_to target.
    """
    if item.reply_to is None:
        # No reply target - return cleared reply state
        return Reply(
            id=item.id,
            reply_to=None,
            thread_root=item.thread_root,
            reply_count=item.reply_count,
            reply_chain=item.reply_chain,
            indicator_visible=False,
            indicator_text=""
        )
    
    # Generate reply indicator
    indicator = format_reply_indicator(item.reply_to)
    
    # Return new Reply with processed indicators
    return Reply(
        id=item.id,
        reply_to=item.reply_to,
        thread_root=item.thread_root or item.reply_to.msgid,
        reply_count=item.reply_count,
        reply_chain=item.reply_chain,
        indicator_visible=True,
        indicator_text=indicator
    )


def start_reply(reply: Reply, target: ReplyTarget) -> Reply:
    """Start a reply to a message.
    
    Creates a new reply state configured to reply to the target message.
    """
    return Reply(
        id=reply.id,
        reply_to=target,
        thread_root=target.msgid,
        reply_count=0,
        reply_chain=[target.msgid],
        indicator_visible=True,
        indicator_text=format_reply_indicator(target)
    )


def cancel_reply(reply: Reply) -> Reply:
    """Cancel the current reply.
    
    Clears the reply target and indicator.
    """
    return Reply(
        id=reply.id,
        reply_to=None,
        thread_root=None,
        reply_count=0,
        reply_chain=[],
        indicator_visible=False,
        indicator_text=""
    )


def build_thread_chain(messages: List[Dict], root_msgid: str) -> List[str]:
    """Build a thread chain from a list of messages.
    
    Returns ordered list of msgids in the thread starting from root.
    """
    # Find all messages that reply to the root or any message in the chain
    chain = [root_msgid]
    msg_lookup = {m.get("msgid"): m for m in messages}
    
    # Build chain by following reply_to links
    for msg in messages:
        reply_to = msg.get("reply_to")
        if reply_to in chain:
            chain.append(msg.get("msgid"))
    
    return chain


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "42e6a5d5722e465099a84f9685291666511592b887532dbe23524eb8436345a3",
    "name": "Reply Domain",
    "risk_tier": "critical",
}
