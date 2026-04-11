# 🟢 GREEN: History Domain (IU-5724b98e)
# Description: Implements message history with 4 requirements
# Risk Tier: LOW
# Requirements:
#   1. Load historical messages
#   2. History pagination
#   3. History search
#   4. History caching

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from datetime import datetime

# === TYPES ===

@dataclass
class HistoryMessage:
    """Message in history."""
    msgid: str
    timestamp: datetime
    sender: str
    content: str
    is_highlight: bool = False
    is_loaded: bool = False


@dataclass
class HistoryPage:
    """Page of history messages."""
    messages: List[HistoryMessage] = field(default_factory=list)
    before_msgid: Optional[str] = None
    after_msgid: Optional[str] = None
    has_more_before: bool = False
    has_more_after: bool = False


@dataclass
class History:
    """History domain entity."""
    id: str
    buffer_id: Optional[str] = None
    pages: List[HistoryPage] = field(default_factory=list)
    messages: Dict[str, HistoryMessage] = field(default_factory=dict)
    loaded_count: int = 0
    total_available: int = 0
    is_loading: bool = False
    last_loaded_at: Optional[datetime] = None
    search_query: Optional[str] = None
    search_results: List[str] = field(default_factory=list)
    cache_hits: int = 0
    cache_misses: int = 0


# === HISTORY OPERATIONS ===

def process(item: History) -> History:
    """Process history and update counts."""
    loaded = sum(len(p.messages) for p in item.pages)
    
    return History(
        id=item.id,
        buffer_id=item.buffer_id,
        pages=item.pages.copy(),
        messages=dict(item.messages),
        loaded_count=loaded,
        total_available=item.total_available,
        is_loading=item.is_loading,
        last_loaded_at=item.last_loaded_at,
        search_query=item.search_query,
        search_results=item.search_results.copy(),
        cache_hits=item.cache_hits,
        cache_misses=item.cache_misses
    )


def load_page(history: History, page: HistoryPage) -> History:
    """Load a page of history."""
    new_pages = history.pages.copy()
    new_pages.append(page)
    
    # Merge into messages dict
    new_messages = dict(history.messages)
    for msg in page.messages:
        new_messages[msg.msgid] = msg
    
    return History(
        id=history.id,
        buffer_id=history.buffer_id,
        pages=new_pages,
        messages=new_messages,
        loaded_count=len(new_messages),
        total_available=history.total_available,
        is_loading=False,
        last_loaded_at=datetime.now(),
        search_query=history.search_query,
        search_results=history.search_results.copy(),
        cache_hits=history.cache_hits,
        cache_misses=history.cache_misses
    )


def get_message(history: History, msgid: str) -> Optional[HistoryMessage]:
    """Get a message from history cache."""
    return history.messages.get(msgid)


def has_message(history: History, msgid: str) -> bool:
    """Check if message is in cache."""
    return msgid in history.messages


def search(history: History, query: str) -> History:
    """Search history for messages matching query."""
    results = []
    query_lower = query.lower()
    
    for msg in history.messages.values():
        if query_lower in msg.content.lower() or query_lower in msg.sender.lower():
            results.append(msg.msgid)
    
    return History(
        id=history.id,
        buffer_id=history.buffer_id,
        pages=history.pages.copy(),
        messages=history.messages,
        loaded_count=history.loaded_count,
        total_available=history.total_available,
        is_loading=False,
        last_loaded_at=history.last_loaded_at,
        search_query=query,
        search_results=results,
        cache_hits=history.cache_hits,
        cache_misses=history.cache_misses
    )


def clear_history(history: History) -> History:
    """Clear loaded history."""
    return History(
        id=history.id,
        buffer_id=history.buffer_id,
        pages=[],
        messages={},
        loaded_count=0,
        total_available=history.total_available,
        is_loading=False,
        last_loaded_at=None,
        search_query=None,
        search_results=[],
        cache_hits=0,
        cache_misses=0
    )


def get_messages_before(history: History, msgid: str, count: int = 50) -> List[HistoryMessage]:
    """Get messages before given msgid."""
    # Find the page containing msgid
    for page in history.pages:
        msgids = [m.msgid for m in page.messages]
        if msgid in msgids:
            idx = msgids.index(msgid)
            start = max(0, idx - count)
            return page.messages[start:idx]
    
    return []


def get_messages_after(history: History, msgid: str, count: int = 50) -> List[HistoryMessage]:
    """Get messages after given msgid."""
    for page in history.pages:
        msgids = [m.msgid for m in page.messages]
        if msgid in msgids:
            idx = msgids.index(msgid)
            end = min(len(page.messages), idx + count + 1)
            return page.messages[idx + 1:end]
    
    return []


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "5724b98e9464bf6b84ebdf774812faafe1e5f7eda8fd087aac5653e855de0027",
    "name": "History Domain",
    "risk_tier": "low",
}
