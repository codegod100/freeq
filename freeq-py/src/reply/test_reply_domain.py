# 🟢 GREEN: Tests for Reply Domain (IU-42e6a5d5)
# Risk Tier: CRITICAL

import pytest
from datetime import datetime
from reply_domain import (
    _phoenix, Reply, ReplyTarget, process, start_reply, cancel_reply,
    create_reply_target, format_reply_indicator, build_thread_chain
)

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "42e6a5d5722e465099a84f9685291666511592b887532dbe23524eb8436345a3"


# 🟢 GREEN: Reply target creation tests
def test_create_reply_target():
    """Test creating a reply target from message data."""
    target = create_reply_target(
        msgid="msg123",
        sender_nick="alice",
        content="Hello world!",
        sender_did="did:plc:alice",
        timestamp=datetime(2024, 1, 1, 12, 0, 0)
    )
    assert target.msgid == "msg123"
    assert target.sender_nick == "alice"
    assert target.sender_did == "did:plc:alice"
    assert target.preview == "Hello world!"
    assert target.timestamp == datetime(2024, 1, 1, 12, 0, 0)


def test_create_reply_target_long_content():
    """Test that long content is truncated in preview."""
    target = create_reply_target(
        msgid="msg456",
        sender_nick="bob",
        content="A" * 100
    )
    assert len(target.preview) <= 53  # 50 chars + "..."
    assert target.preview.endswith("...")


# 🟢 GREEN: Reply indicator formatting tests
def test_format_reply_indicator():
    """Test formatting reply indicator text."""
    target = ReplyTarget(
        msgid="msg123",
        sender_nick="alice",
        sender_did=None,
        content="Original message",
        timestamp=datetime.now(),
        preview="Original message"
    )
    indicator = format_reply_indicator(target)
    assert "Reply to @alice" in indicator
    assert "Original message" in indicator


def test_format_reply_indicator_truncated():
    """Test reply indicator with truncated preview."""
    target = ReplyTarget(
        msgid="msg123",
        sender_nick="bob",
        sender_did=None,
        content="Short",
        timestamp=datetime.now(),
        preview="Short"
    )
    indicator = format_reply_indicator(target)
    assert "Reply to @bob" in indicator
    assert "Short" in indicator


# 🟢 GREEN: Process function tests
def test_process_with_reply_target():
    """Test processing reply with a target creates indicator."""
    target = ReplyTarget(
        msgid="parent123",
        sender_nick="alice",
        sender_did=None,
        content="Parent message",
        timestamp=datetime.now(),
        preview="Parent message"
    )
    reply = Reply(id="reply123", reply_to=target)
    
    result = process(reply)
    
    assert result is not reply  # New object
    assert result.indicator_visible is True
    assert "@alice" in result.indicator_text
    assert result.thread_root == "parent123"


def test_process_without_reply_target():
    """Test processing reply without target clears indicators."""
    reply = Reply(id="reply123", reply_to=None, indicator_visible=True)
    
    result = process(reply)
    
    assert result is not reply
    assert result.indicator_visible is False
    assert result.indicator_text == ""


def test_process_preserves_thread_info():
    """Test that process preserves existing thread information."""
    target = ReplyTarget(
        msgid="parent123",
        sender_nick="alice",
        sender_did=None,
        content="Parent",
        timestamp=datetime.now(),
        preview="Parent"
    )
    reply = Reply(
        id="reply123",
        reply_to=target,
        reply_count=5,
        reply_chain=["root", "parent123"]
    )
    
    result = process(reply)
    
    assert result.reply_count == 5
    assert result.reply_chain == ["root", "parent123"]


# 🟢 GREEN: Start reply tests
def test_start_reply():
    """Test starting a reply to a message."""
    original = Reply(id="r1")
    target = create_reply_target("msg123", "alice", "Hello")
    
    result = start_reply(original, target)
    
    assert result.reply_to == target
    assert result.thread_root == "msg123"
    assert "msg123" in result.reply_chain
    assert result.indicator_visible is True


# 🟢 GREEN: Cancel reply tests
def test_cancel_reply():
    """Test canceling a reply clears all state."""
    target = create_reply_target("msg123", "alice", "Hello")
    reply = start_reply(Reply(id="r1"), target)
    
    result = cancel_reply(reply)
    
    assert result.reply_to is None
    assert result.thread_root is None
    assert result.reply_chain == []
    assert result.indicator_visible is False
    assert result.indicator_text == ""


# 🟢 GREEN: Thread chain building tests
def test_build_thread_chain():
    """Test building a thread chain from messages."""
    messages = [
        {"msgid": "root", "reply_to": None},
        {"msgid": "reply1", "reply_to": "root"},
        {"msgid": "reply2", "reply_to": "reply1"},
    ]
    
    chain = build_thread_chain(messages, "root")
    
    assert chain[0] == "root"
    assert "reply1" in chain or "reply2" in chain


def test_build_thread_chain_single_message():
    """Test thread chain with just root message."""
    messages = [{"msgid": "root", "reply_to": None}]
    chain = build_thread_chain(messages, "root")
    assert chain == ["root"]


def test_process_transforms_input():
    """Ensure process creates a new object (backwards compatibility)."""
    target = create_reply_target("msg123", "alice", "Hello")
    input_item = Reply(id="123", reply_to=target)
    result = process(input_item)
    assert result is not input_item  # Should be new object
