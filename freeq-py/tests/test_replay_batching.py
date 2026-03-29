from __future__ import annotations

import sys
import json
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from textual.widgets import RichLog  # noqa: E402

from freeq_textual.app import FreeqTextualApp  # noqa: E402


class FakeClient:
    def __init__(self, nick: str = "nandi", server_addr: str = "irc.freeq.at:6697") -> None:
        self.nick = nick
        self.server_addr = server_addr
        self._events: list[dict] = []
        self.join_calls: list[str] = []
        self.history_calls: list[tuple[str, int]] = []

    def queue_events(self, *events: dict) -> None:
        self._events.extend(events)

    def poll_event(self, timeout_ms: int = 0) -> dict | None:
        del timeout_ms
        if not self._events:
            return None
        return self._events.pop(0)

    def connect(self) -> None:
        return

    def join(self, channel: str) -> None:
        self.join_calls.append(channel)

    def send_message(self, target: str, text: str) -> None:
        return

    def history_latest(self, target: str, count: int = 50) -> None:
        self.history_calls.append((target, count))

    def set_nick(self, nick: str) -> None:
        self.nick = nick

    def raw(self, line: str) -> None:
        return

    def reconnect_with_web_token(self, web_token: str) -> None:
        return


class FakeBroker:
    def refresh_session(self, broker_token: str) -> dict | None:
        del broker_token
        return {"token": "refreshed-token"}


class ReplayBatchingTests(unittest.IsolatedAsyncioTestCase):
    async def test_replay_batch_renders_into_visible_log_in_sorted_order(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app._append_line("#freeq", "[cyan]zoe[/]: latest live message")
            app.active_buffer = "#freeq"
            app._render_active_buffer()

            client.queue_events(
                {"type": "batch_start", "id": "hist1", "batch_type": "chathistory", "target": "#freeq"},
                {
                    "type": "message",
                    "from": "bob",
                    "target": "#freeq",
                    "text": "second oldest",
                    "tags": {"batch": "hist1", "time": "2026-03-28T12:00:02.000Z"},
                },
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "oldest",
                    "tags": {"batch": "hist1", "time": "2026-03-28T12:00:01.000Z"},
                },
                {"type": "batch_end", "id": "hist1"},
            )

            app._poll_events()
            await pilot.pause()

            log = app.query_one(RichLog)
            rendered = [strip.text.rstrip() for strip in log.lines if strip.text.strip()]

            self.assertGreaterEqual(len(rendered), 3)
            self.assertEqual(rendered[:3], ["alice: oldest", "bob: second oldest", "zoe: latest live message"])

    async def test_replay_batch_switches_visible_room(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            client.queue_events(
                {"type": "batch_start", "id": "hist2", "batch_type": "chathistory", "target": "#python"},
                {
                    "type": "message",
                    "from": "carol",
                    "target": "#python",
                    "text": "replayed line",
                    "tags": {"batch": "hist2", "time": "2026-03-28T12:00:03.000Z"},
                },
                {"type": "batch_end", "id": "hist2"},
            )

            app._poll_events()
            await pilot.pause()

            log = app.query_one(RichLog)
            rendered = [strip.text.rstrip() for strip in log.lines if strip.text.strip()]

            self.assertEqual(app.active_buffer, "#python")
            self.assertIn("carol: replayed line", rendered)

    async def test_restore_rejoin_sequence_requests_join_and_renders_replay_batch(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app._ensure_buffer("#freeq")
            app.pending_rejoin = {"#freeq"}

            client.queue_events(
                {"type": "registered", "nick": "nandi"},
                {"type": "joined", "channel": "#freeq", "nick": "nandi"},
                {"type": "batch_start", "id": "hist3", "batch_type": "chathistory", "target": "#freeq"},
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "restored replay line",
                    "tags": {"batch": "hist3", "time": "2026-03-28T12:00:01.000Z"},
                },
                {"type": "batch_end", "id": "hist3"},
            )

            app._poll_events()
            await pilot.pause()

            log = app.query_one(RichLog)
            rendered = [strip.text.rstrip() for strip in log.lines if strip.text.strip()]

            self.assertEqual(client.join_calls, ["#freeq"])
            self.assertEqual(app.active_buffer, "#freeq")
            self.assertIn("alice: restored replay line", rendered)

    async def test_cached_session_channels_are_rejoined_on_auth_restore(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(
            client,
            auth_broker=FakeBroker(),
            session_path=None,
            cached_auth={
                "broker_token": "broker-token",
                "handle": "nandi.example",
                "channels": ["#freeq", "#python"],
            },
        )

        async with app.run_test() as pilot:
            app._restore_auth()
            self.assertEqual(app.pending_rejoin, {"#freeq", "#python"})

            client.queue_events({"type": "registered", "nick": "nandi"})
            app._poll_events()
            await pilot.pause()

            self.assertEqual(client.join_calls, ["#freeq", "#python"])

    async def test_restore_auth_preserves_cached_channels_when_refreshing_session(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(
            client,
            auth_broker=FakeBroker(),
            session_path=None,
            cached_auth={
                "broker_token": "broker-token",
                "handle": "nandi.example",
                "channels": ["#freeq", "#python"],
            },
        )

        async with app.run_test():
            app._restore_auth()

        self.assertEqual(app.cached_auth["channels"], ["#freeq", "#python"])

    async def test_join_persists_channels_into_cached_session_file(self) -> None:
        client = FakeClient()
        with tempfile.TemporaryDirectory() as tmpdir:
            session_path = Path(tmpdir) / "session.json"
            app = FreeqTextualApp(
                client,
                session_path=session_path,
                cached_auth={
                    "broker_token": "broker-token",
                    "handle": "nandi.example",
                    "channels": [],
                },
            )

            async with app.run_test() as pilot:
                client.queue_events({"type": "joined", "channel": "#freeq", "nick": "nandi"})
                app._poll_events()
                await pilot.pause()

            payload = json.loads(session_path.read_text())
            self.assertEqual(payload["channels"], ["#freeq"])

    async def test_auth_restore_names_end_requests_history_for_restored_channel(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(
            client,
            auth_broker=FakeBroker(),
            session_path=None,
            cached_auth={
                "broker_token": "broker-token",
                "handle": "nandi.example",
                "channels": ["#freeq"],
            },
        )

        async with app.run_test() as pilot:
            app._restore_auth()
            client.queue_events(
                {"type": "registered", "nick": "nandi"},
                {"type": "joined", "channel": "#freeq", "nick": "nandi"},
                {"type": "names_end", "channel": "#freeq"},
            )
            app._poll_events()
            await pilot.pause(0.2)

            self.assertEqual(client.join_calls, ["#freeq"])
            self.assertEqual(client.history_calls, [("#freeq", 50)])


if __name__ == "__main__":
    unittest.main()
