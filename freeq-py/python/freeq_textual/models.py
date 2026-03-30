"""Data classes for freeq-textual."""

from dataclasses import dataclass


@dataclass(slots=True)
class BufferState:
    name: str
    unread: int = 0


@dataclass(slots=True)
class BatchState:
    target: str
    batch_type: str
    lines: list[tuple[str, object]]  # (timestamp, Text)
    thread_roots: list[str | None]
    line_metas: list[tuple[str, str] | None] | None = None


@dataclass(slots=True)
class MessageState:
    buffer_key: str
    sender: str
    text: str
    thread_root: str
    msgid: str = ""
    reply_to: str = ""
    is_reply: bool = False


@dataclass(slots=True)
class ThreadState:
    buffer_key: str
    root_msgid: str
    root_sender: str
    root_text: str
    reply_count: int = 0
    latest_sender: str = ""
    latest_text: str = ""
    latest_activity: int = 0