# 🟢 GREEN: Tests for Event Domain (IU-7835154d)
# Risk Tier: HIGH

import pytest
from datetime import datetime
from event_domain import (
    _phoenix, Event, EventType, EventPriority, EventQueue, EventSubscription,
    process, create_event, queue_event, dequeue_event, filter_events,
    batch_events, should_handle
)

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "7835154d9f608e77fbd5d23403510810a09057e936c88e8526fe1f4adcef8be2"


# 🟢 GREEN: Event creation tests
def test_create_event():
    """Test creating an event."""
    event = create_event(
        EventType.MESSAGE_RECEIVED,
        {"channel": "#test", "content": "Hello"},
        priority=EventPriority.HIGH
    )
    assert event.event_type == EventType.MESSAGE_RECEIVED
    assert event.priority == EventPriority.HIGH
    assert event.data == {"channel": "#test", "content": "Hello"}
    assert event.handled is False
    assert event.id.startswith("evt_")


def test_create_event_default_priority():
    """Test event creation with default priority."""
    event = create_event(EventType.CONNECT, {})
    assert event.priority == EventPriority.NORMAL


# 🟢 GREEN: Process function tests
def test_process_marks_handled():
    """Test that process marks event as handled."""
    event = create_event(EventType.MESSAGE_RECEIVED, {}, priority=EventPriority.HIGH)
    result = process(event)
    assert result.handled is True
    assert result is not event  # New object


def test_process_preserves_data():
    """Test that process preserves event data."""
    event = create_event(
        EventType.MESSAGE_RECEIVED,
        {"key": "value"},
        priority=EventPriority.CRITICAL,
        source="irc"
    )
    result = process(event)
    assert result.data == {"key": "value"}
    assert result.priority == EventPriority.CRITICAL
    assert result.source == "irc"


# 🟢 GREEN: Queue operations tests
def test_queue_event():
    """Test adding event to queue."""
    queue = EventQueue()
    event = create_event(EventType.CONNECT, {})
    result = queue_event(queue, event)
    assert len(result.events) == 1
    assert result.events[0] == event


def test_queue_event_priority_order():
    """Test that events are ordered by priority."""
    queue = EventQueue()
    low = create_event(EventType.SCROLL, {}, priority=EventPriority.LOW)
    high = create_event(EventType.CONNECT, {}, priority=EventPriority.HIGH)
    critical = create_event(EventType.ERROR, {}, priority=EventPriority.CRITICAL)
    
    queue = queue_event(queue, low)
    queue = queue_event(queue, high)
    queue = queue_event(queue, critical)
    
    # Should be ordered: critical, high, low
    assert queue.events[0].priority == EventPriority.CRITICAL
    assert queue.events[1].priority == EventPriority.HIGH
    assert queue.events[2].priority == EventPriority.LOW


def test_queue_event_drops_when_full():
    """Test that lowest priority event is dropped when queue full."""
    queue = EventQueue(max_size=2)
    low = create_event(EventType.SCROLL, {}, priority=EventPriority.LOW)
    normal = create_event(EventType.MESSAGE_RECEIVED, {}, priority=EventPriority.NORMAL)
    high = create_event(EventType.CONNECT, {}, priority=EventPriority.HIGH)
    
    queue = queue_event(queue, low)
    queue = queue_event(queue, normal)
    queue = queue_event(queue, high)
    
    # Low priority should be dropped
    assert len(queue.events) == 2
    assert queue.dropped_count == 1
    assert all(e.priority != EventPriority.LOW for e in queue.events)


def test_dequeue_event():
    """Test removing highest priority event."""
    queue = EventQueue()
    event1 = create_event(EventType.CONNECT, {}, priority=EventPriority.HIGH)
    event2 = create_event(EventType.SCROLL, {}, priority=EventPriority.LOW)
    queue = queue_event(queue, event1)
    queue = queue_event(queue, event2)
    
    event, new_queue = dequeue_event(queue)
    
    assert event == event1  # High priority first
    assert len(new_queue.events) == 1
    assert new_queue.events[0] == event2


def test_dequeue_empty_queue():
    """Test dequeue from empty queue."""
    queue = EventQueue()
    event, new_queue = dequeue_event(queue)
    assert event is None
    assert new_queue == queue


# 🟢 GREEN: Event filtering tests
def test_filter_events_by_type():
    """Test filtering events by type."""
    events = [
        create_event(EventType.CONNECT, {}),
        create_event(EventType.MESSAGE_RECEIVED, {}),
        create_event(EventType.CONNECT, {}),
    ]
    
    filtered = filter_events(events, event_types={EventType.CONNECT})
    assert len(filtered) == 2
    assert all(e.event_type == EventType.CONNECT for e in filtered)


def test_filter_events_by_priority():
    """Test filtering events by priority."""
    events = [
        create_event(EventType.CONNECT, {}, priority=EventPriority.HIGH),
        create_event(EventType.MESSAGE_RECEIVED, {}, priority=EventPriority.NORMAL),
        create_event(EventType.ERROR, {}, priority=EventPriority.HIGH),
    ]
    
    filtered = filter_events(events, priority=EventPriority.HIGH)
    assert len(filtered) == 2
    assert all(e.priority == EventPriority.HIGH for e in filtered)


def test_filter_events_by_source():
    """Test filtering events by source."""
    events = [
        create_event(EventType.CONNECT, {}, source="irc"),
        create_event(EventType.MESSAGE_RECEIVED, {}, source="ui"),
        create_event(EventType.ERROR, {}, source="irc"),
    ]
    
    filtered = filter_events(events, source="irc")
    assert len(filtered) == 2
    assert all(e.source == "irc" for e in filtered)


# 🟢 GREEN: Batch processing tests
def test_batch_events():
    """Test batching events."""
    events = [create_event(EventType.MESSAGE_RECEIVED, {}) for _ in range(15)]
    batches = batch_events(events, max_batch_size=5)
    
    assert len(batches) == 3
    assert len(batches[0]) == 5
    assert len(batches[1]) == 5
    assert len(batches[2]) == 5


def test_batch_events_partial():
    """Test batching with partial last batch."""
    events = [create_event(EventType.MESSAGE_RECEIVED, {}) for _ in range(7)]
    batches = batch_events(events, max_batch_size=5)
    
    assert len(batches) == 2
    assert len(batches[0]) == 5
    assert len(batches[1]) == 2


# 🟢 GREEN: Subscription handling tests
def test_should_handle_type_match():
    """Test subscription handles matching event type."""
    sub = EventSubscription(
        id="s1",
        handler=lambda e: None,
        event_types={EventType.CONNECT, EventType.DISCONNECT}
    )
    event = create_event(EventType.CONNECT, {})
    assert should_handle(sub, event) is True


def test_should_handle_type_mismatch():
    """Test subscription ignores non-matching event type."""
    sub = EventSubscription(
        id="s1",
        handler=lambda e: None,
        event_types={EventType.CONNECT}
    )
    event = create_event(EventType.MESSAGE_RECEIVED, {})
    assert should_handle(sub, event) is False


def test_should_handle_no_filter():
    """Test subscription with no type filter handles all events."""
    sub = EventSubscription(id="s1", handler=lambda e: None, event_types=None)
    event = create_event(EventType.MESSAGE_RECEIVED, {})
    assert should_handle(sub, event) is True


def test_process_transforms_input():
    """Ensure process creates new object (backwards compatibility)."""
    input_item = create_event(EventType.CONNECT, {})
    result = process(input_item)
    assert result is not input_item
    assert result.handled is True
