# 🟢 GREEN: Streaming Domain (IU-4ee9d7cf)
# Description: Implements streaming with 2 requirements
# Risk Tier: LOW
# Requirements:
#   1. Stream data processing
#   2. Stream buffer management

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Callable
from datetime import datetime
from enum import Enum, auto

# === TYPES ===

class StreamStatus(Enum):
    """Stream connection status."""
    DISCONNECTED = auto()
    CONNECTING = auto()
    CONNECTED = auto()
    RECONNECTING = auto()
    ERROR = auto()


@dataclass
class StreamChunk:
    """A chunk of stream data."""
    data: Any
    timestamp: datetime
    sequence: int
    processed: bool = False


@dataclass
class Streaming:
    """Streaming domain entity."""
    id: str
    status: StreamStatus = StreamStatus.DISCONNECTED
    buffer: List[StreamChunk] = field(default_factory=list)
    buffer_size: int = 0
    max_buffer_size: int = 1000
    dropped_chunks: int = 0
    handlers: Dict[str, List[Callable]] = field(default_factory=dict)
    stream_id: Optional[str] = None
    last_chunk_at: Optional[datetime] = None
    total_received: int = 0
    total_processed: int = 0


# === STREAMING OPERATIONS ===

def process(item: Streaming) -> Streaming:
    """Process stream buffer."""
    return Streaming(
        id=item.id,
        status=item.status,
        buffer=item.buffer.copy(),
        buffer_size=len(item.buffer),
        max_buffer_size=item.max_buffer_size,
        dropped_chunks=item.dropped_chunks,
        handlers=dict(item.handlers),
        stream_id=item.stream_id,
        last_chunk_at=item.last_chunk_at,
        total_received=item.total_received,
        total_processed=sum(1 for c in item.buffer if c.processed)
    )


def connect(stream: Streaming, stream_id: str) -> Streaming:
    """Mark stream as connected."""
    return Streaming(
        id=stream.id,
        status=StreamStatus.CONNECTED,
        buffer=stream.buffer,
        buffer_size=stream.buffer_size,
        max_buffer_size=stream.max_buffer_size,
        dropped_chunks=stream.dropped_chunks,
        handlers=stream.handlers,
        stream_id=stream_id,
        last_chunk_at=datetime.now(),
        total_received=stream.total_received,
        total_processed=stream.total_processed
    )


def disconnect(stream: Streaming) -> Streaming:
    """Mark stream as disconnected."""
    return Streaming(
        id=stream.id,
        status=StreamStatus.DISCONNECTED,
        buffer=[],  # Clear buffer
        buffer_size=0,
        max_buffer_size=stream.max_buffer_size,
        dropped_chunks=0,
        handlers=stream.handlers,
        stream_id=None,
        last_chunk_at=None,
        total_received=0,
        total_processed=0
    )


def add_chunk(stream: Streaming, data: Any) -> Streaming:
    """Add a chunk to the stream buffer."""
    new_buffer = stream.buffer.copy()
    
    # Check buffer limit
    if len(new_buffer) >= stream.max_buffer_size:
        # Drop oldest
        new_buffer = new_buffer[1:]
        dropped = stream.dropped_chunks + 1
    else:
        dropped = stream.dropped_chunks
    
    new_buffer.append(StreamChunk(
        data=data,
        timestamp=datetime.now(),
        sequence=stream.total_received,
        processed=False
    ))
    
    return Streaming(
        id=stream.id,
        status=stream.status,
        buffer=new_buffer,
        buffer_size=len(new_buffer),
        max_buffer_size=stream.max_buffer_size,
        dropped_chunks=dropped,
        handlers=stream.handlers,
        stream_id=stream.stream_id,
        last_chunk_at=datetime.now(),
        total_received=stream.total_received + 1,
        total_processed=stream.total_processed
    )


def mark_processed(stream: Streaming, sequence: int) -> Streaming:
    """Mark a chunk as processed."""
    new_buffer = []
    for chunk in stream.buffer:
        if chunk.sequence == sequence:
            new_buffer.append(StreamChunk(
                data=chunk.data,
                timestamp=chunk.timestamp,
                sequence=chunk.sequence,
                processed=True
            ))
        else:
            new_buffer.append(chunk)
    
    return Streaming(
        id=stream.id,
        status=stream.status,
        buffer=new_buffer,
        buffer_size=len(new_buffer),
        max_buffer_size=stream.max_buffer_size,
        dropped_chunks=stream.dropped_chunks,
        handlers=stream.handlers,
        stream_id=stream.stream_id,
        last_chunk_at=stream.last_chunk_at,
        total_received=stream.total_received,
        total_processed=stream.total_processed + 1
    )


def get_unprocessed(stream: Streaming) -> List[StreamChunk]:
    """Get all unprocessed chunks."""
    return [c for c in stream.buffer if not c.processed]


def register_handler(stream: Streaming, event: str, handler: Callable) -> Streaming:
    """Register a handler for a stream event."""
    new_handlers = dict(stream.handlers)
    
    if event not in new_handlers:
        new_handlers[event] = []
    
    new_handlers[event] = new_handlers[event] + [handler]
    
    return Streaming(
        id=stream.id,
        status=stream.status,
        buffer=stream.buffer,
        buffer_size=stream.buffer_size,
        max_buffer_size=stream.max_buffer_size,
        dropped_chunks=stream.dropped_chunks,
        handlers=new_handlers,
        stream_id=stream.stream_id,
        last_chunk_at=stream.last_chunk_at,
        total_received=stream.total_received,
        total_processed=stream.total_processed
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "4ee9d7cf8c5f9a0e3b1d2c4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4",
    "name": "Streaming Domain",
    "risk_tier": "low",
}
