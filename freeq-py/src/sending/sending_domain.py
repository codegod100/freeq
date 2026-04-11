# 🟢 GREEN: Sending Domain (IU-d8905904)
# Description: Implements message sending with 3 requirements
# Risk Tier: LOW
# Requirements:
#   1. Queue outgoing messages
#   2. Rate limiting
#   3. Send status tracking

from dataclasses import dataclass, field
from typing import Optional, List, Dict
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class SendStatus(Enum):
    """Message send status."""
    PENDING = auto()
    SENDING = auto()
    SENT = auto()
    FAILED = auto()
    RATE_LIMITED = auto()


@dataclass
class OutgoingMessage:
    """A message waiting to be sent."""
    id: str
    target: str  # channel or nick
    content: str
    status: SendStatus = SendStatus.PENDING
    created_at: datetime = field(default_factory=datetime.now)
    sent_at: Optional[datetime] = None
    error: Optional[str] = None
    is_command: bool = False
    priority: int = 0


@dataclass
class Sending:
    """Sending domain entity."""
    id: str
    queue: List[OutgoingMessage] = field(default_factory=list)
    rate_limit_remaining: int = 60
    rate_limit_reset: Optional[datetime] = None
    last_send_time: Optional[datetime] = None
    min_delay_ms: int = 500
    max_queue_size: int = 100
    dropped_count: int = 0


# === SENDING OPERATIONS ===

def process(item: Sending) -> Sending:
    """Process sending queue."""
    return Sending(
        id=item.id,
        queue=item.queue.copy(),
        rate_limit_remaining=item.rate_limit_remaining,
        rate_limit_reset=item.rate_limit_reset,
        last_send_time=item.last_send_time,
        min_delay_ms=item.min_delay_ms,
        max_queue_size=item.max_queue_size,
        dropped_count=item.dropped_count
    )


def queue_message(sending: Sending, target: str, content: str, is_command: bool = False, priority: int = 0) -> Sending:
    """Queue a message for sending."""
    new_queue = sending.queue.copy()
    
    # Check queue limit
    if len(new_queue) >= sending.max_queue_size:
        # Remove lowest priority
        new_queue = sorted(new_queue, key=lambda m: m.priority, reverse=True)
        new_queue = new_queue[:-1]
        dropped = sending.dropped_count + 1
    else:
        dropped = sending.dropped_count
    
    msg = OutgoingMessage(
        id=f"msg_{datetime.now().timestamp()}",
        target=target,
        content=content,
        status=SendStatus.PENDING,
        is_command=is_command,
        priority=priority
    )
    
    new_queue.append(msg)
    new_queue.sort(key=lambda m: m.priority, reverse=True)
    
    return Sending(
        id=sending.id,
        queue=new_queue,
        rate_limit_remaining=sending.rate_limit_remaining,
        rate_limit_reset=sending.rate_limit_reset,
        last_send_time=sending.last_send_time,
        min_delay_ms=sending.min_delay_ms,
        max_queue_size=sending.max_queue_size,
        dropped_count=dropped
    )


def mark_sending(sending: Sending, msg_id: str) -> Sending:
    """Mark message as currently sending."""
    new_queue = []
    for msg in sending.queue:
        if msg.id == msg_id:
            new_queue.append(OutgoingMessage(
                id=msg.id,
                target=msg.target,
                content=msg.content,
                status=SendStatus.SENDING,
                created_at=msg.created_at,
                is_command=msg.is_command,
                priority=msg.priority
            ))
        else:
            new_queue.append(msg)
    
    return Sending(
        id=sending.id,
        queue=new_queue,
        rate_limit_remaining=sending.rate_limit_remaining,
        rate_limit_reset=sending.rate_limit_reset,
        last_send_time=sending.last_send_time,
        min_delay_ms=sending.min_delay_ms,
        max_queue_size=sending.max_queue_size,
        dropped_count=sending.dropped_count
    )


def mark_sent(sending: Sending, msg_id: str) -> Sending:
    """Mark message as sent."""
    new_queue = [m for m in sending.queue if m.id != msg_id]
    
    return Sending(
        id=sending.id,
        queue=new_queue,
        rate_limit_remaining=sending.rate_limit_remaining - 1,
        rate_limit_reset=sending.rate_limit_reset,
        last_send_time=datetime.now(),
        min_delay_ms=sending.min_delay_ms,
        max_queue_size=sending.max_queue_size,
        dropped_count=sending.dropped_count
    )


def mark_failed(sending: Sending, msg_id: str, error: str) -> Sending:
    """Mark message as failed."""
    new_queue = []
    for msg in sending.queue:
        if msg.id == msg_id:
            new_queue.append(OutgoingMessage(
                id=msg.id,
                target=msg.target,
                content=msg.content,
                status=SendStatus.FAILED,
                created_at=msg.created_at,
                error=error,
                is_command=msg.is_command,
                priority=msg.priority
            ))
        else:
            new_queue.append(msg)
    
    return Sending(
        id=sending.id,
        queue=new_queue,
        rate_limit_remaining=sending.rate_limit_remaining,
        rate_limit_reset=sending.rate_limit_reset,
        last_send_time=sending.last_send_time,
        min_delay_ms=sending.min_delay_ms,
        max_queue_size=sending.max_queue_size,
        dropped_count=sending.dropped_count
    )


def can_send(sending: Sending) -> bool:
    """Check if we can send a message now."""
    if sending.rate_limit_remaining <= 0:
        return False
    
    if sending.last_send_time:
        elapsed = (datetime.now() - sending.last_send_time).total_seconds() * 1000
        if elapsed < sending.min_delay_ms:
            return False
    
    return True


def get_pending(sending: Sending) -> List[OutgoingMessage]:
    """Get all pending messages."""
    return [m for m in sending.queue if m.status == SendStatus.PENDING]


def clear_queue(sending: Sending) -> Sending:
    """Clear the send queue."""
    return Sending(
        id=sending.id,
        queue=[],
        rate_limit_remaining=sending.rate_limit_remaining,
        rate_limit_reset=sending.rate_limit_reset,
        last_send_time=sending.last_send_time,
        min_delay_ms=sending.min_delay_ms,
        max_queue_size=sending.max_queue_size,
        dropped_count=sending.dropped_count
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "d8905904e7c5b5f3a9d8e7f6c5b4a3d2e1f0a9b8c7d6e5f4c3b2a1d0e9f8",
    "name": "Sending Domain",
    "risk_tier": "low",
}
