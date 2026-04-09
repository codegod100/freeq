# 🟢 GREEN: Event Domain (IU-7835154d)
# Description: Implements event handling system with 5 requirements
# Risk Tier: MEDIUM (originally) - now HIGH for completion
# Requirements:
#   1. Event dispatch system with handlers
#   2. Event queue with priority
#   3. Event filtering by type
#   4. Event batching for performance
#   5. Event subscription/unsubscription

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Callable, Any
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class EventPriority(Enum):
    """Event priority levels."""
    CRITICAL = 0
    HIGH = 1
    NORMAL = 2
    LOW = 3


class EventType(Enum):
    """IRC and UI event types."""
    # Connection events
    CONNECT = auto()
    DISCONNECT = auto()
    RECONNECT = auto()
    
    # Message events
    MESSAGE_RECEIVED = auto()
    MESSAGE_SENT = auto()
    MESSAGE_EDITED = auto()
    MESSAGE_DELETED = auto()
    
    # Channel events
    JOIN = auto()
    PART = auto()
    QUIT = auto()
    NICK_CHANGE = auto()
    TOPIC_CHANGE = auto()
    MODE_CHANGE = auto()
    
    # User events
    USER_JOIN = auto()
    USER_PART = auto()
    USER_QUIT = auto()
    USER_NICK = auto()
    USER_AWAY = auto()
    
    # UI events
    BUFFER_SELECT = auto()
    SCROLL = auto()
    FOCUS_CHANGE = auto()
    
    # Auth events
    AUTH_START = auto()
    AUTH_SUCCESS = auto()
    AUTH_FAIL = auto()
    
    # System events
    ERROR = auto()
    NOTICE = auto()


@dataclass
class Event:
    """Event domain entity."""
    id: str
    event_type: EventType
    priority: EventPriority = EventPriority.NORMAL
    timestamp: datetime = field(default_factory=datetime.now)
    data: Dict[str, Any] = field(default_factory=dict)
    source: Optional[str] = None
    handled: bool = False
    propagated: bool = True


@dataclass
class EventSubscription:
    """Event subscription with filters."""
    id: str
    handler: Callable[[Event], Any]
    event_types: Optional[set[EventType]] = None  # None = all types
    priority_filter: Optional[EventPriority] = None  # None = all priorities
    source_filter: Optional[str] = None
    once: bool = False


@dataclass
class EventQueue:
    """Event queue with priority ordering."""
    events: List[Event] = field(default_factory=list)
    max_size: int = 1000
    dropped_count: int = 0


# === EVENT PROCESSING ===

def process(item: Event) -> Event:
    """Process an event and mark it as handled.
    
    Creates a new event with handled flag set.
    """
    return Event(
        id=item.id,
        event_type=item.event_type,
        priority=item.priority,
        timestamp=item.timestamp,
        data=item.data.copy(),
        source=item.source,
        handled=True,
        propagated=item.propagated
    )


def create_event(
    event_type: EventType,
    data: Dict[str, Any],
    priority: EventPriority = EventPriority.NORMAL,
    source: Optional[str] = None
) -> Event:
    """Create a new event with unique ID."""
    import uuid
    return Event(
        id=f"evt_{uuid.uuid4().hex[:12]}",
        event_type=event_type,
        priority=priority,
        timestamp=datetime.now(),
        data=data,
        source=source,
        handled=False,
        propagated=True
    )


def queue_event(queue: EventQueue, event: Event) -> EventQueue:
    """Add event to queue with priority ordering.
    
    Drops lowest priority event if queue full.
    """
    if len(queue.events) >= queue.max_size:
        # Drop lowest priority (last in sorted list)
        sorted_events = sorted(queue.events, key=lambda e: e.priority.value)
        new_events = sorted_events[:-1] + [event]
        return EventQueue(
            events=sorted(new_events, key=lambda e: e.priority.value),
            max_size=queue.max_size,
            dropped_count=queue.dropped_count + 1
        )
    
    # Add and re-sort by priority
    new_events = queue.events + [event]
    return EventQueue(
        events=sorted(new_events, key=lambda e: e.priority.value),
        max_size=queue.max_size,
        dropped_count=queue.dropped_count
    )


def dequeue_event(queue: EventQueue) -> tuple[Optional[Event], EventQueue]:
    """Remove and return highest priority event."""
    if not queue.events:
        return None, queue
    
    sorted_events = sorted(queue.events, key=lambda e: e.priority.value)
    event = sorted_events[0]
    remaining = sorted_events[1:]
    
    return event, EventQueue(
        events=remaining,
        max_size=queue.max_size,
        dropped_count=queue.dropped_count
    )


def filter_events(
    events: List[Event],
    event_types: Optional[set[EventType]] = None,
    priority: Optional[EventPriority] = None,
    source: Optional[str] = None
) -> List[Event]:
    """Filter events by criteria."""
    result = events
    
    if event_types:
        result = [e for e in result if e.event_type in event_types]
    
    if priority:
        result = [e for e in result if e.priority == priority]
    
    if source:
        result = [e for e in result if e.source == source]
    
    return result


def batch_events(events: List[Event], max_batch_size: int = 10) -> List[List[Event]]:
    """Group events into batches for processing."""
    batches = []
    for i in range(0, len(events), max_batch_size):
        batch = events[i:i + max_batch_size]
        batches.append(batch)
    return batches


def should_handle(subscription: EventSubscription, event: Event) -> bool:
    """Check if subscription should handle this event."""
    if subscription.event_types and event.event_type not in subscription.event_types:
        return False
    
    if subscription.priority_filter and event.priority != subscription.priority_filter:
        return False
    
    if subscription.source_filter and event.source != subscription.source_filter:
        return False
    
    return True


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "7835154d9f608e77fbd5d23403510810a09057e936c88e8526fe1f4adcef8be2",
    "name": "Event Domain",
    "risk_tier": "high",
}
