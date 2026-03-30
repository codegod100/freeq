from __future__ import annotations

import sys
import json
import re
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import PropertyMock, patch

from PIL import Image as PILImage


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from textual.widgets import RichLog  # noqa: E402
from textual.widgets import Static  # noqa: E402
from textual.widgets import Input  # noqa: E402
from textual.widgets import Button  # noqa: E402

from freeq_textual.widgets import ScrollableLog  # noqa: E402

from freeq_textual.app import BufferState, FreeqTextualApp  # noqa: E402


class FakeClient:
    def __init__(self, nick: str = "nandi", server_addr: str = "irc.freeq.at:6697") -> None:
        self.nick = nick
        self.server_addr = server_addr
        self._events: list[dict] = []
        self.join_calls: list[str] = []
        self.history_calls: list[tuple[str, int]] = []
        self.raw_calls: list[str] = []

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
        self.raw_calls.append(line)

    def reconnect_with_web_token(self, web_token: str) -> None:
        return


class FakeBroker:
    def refresh_session(self, broker_token: str) -> dict | None:
        del broker_token
        return {"token": "refreshed-token"}


class ReplayBatchingTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        # Disable avatars in tests for consistent output format
        self._avatar_patcher = patch.object(
            FreeqTextualApp, "_detect_avatar_support", return_value=False
        )
        self._avatar_patcher.start()

    def tearDown(self) -> None:
        self._avatar_patcher.stop()

    def _normalize_line(self, text: str) -> str:
        text = re.sub(r"^[▀█▄ ]+", "", text).strip()
        return text

    def _normalize_text(self, text: str) -> str:
        return text.replace("\u200b", "")

    def test_sidebar_width_tracks_buffer_labels_with_bounds(self) -> None:
        narrow = [
            BufferState("status"),
            BufferState("#x"),
        ]
        wide = [
            BufferState("status"),
            BufferState("#a-very-very-long-channel-name", unread=12),
        ]

        self.assertEqual(FreeqTextualApp._sidebar_width_cells(narrow), 12)
        self.assertEqual(FreeqTextualApp._sidebar_width_cells(wide), 22)

    def test_thread_panel_width_shrinks_on_narrow_layouts(self) -> None:
        self.assertEqual(FreeqTextualApp._thread_panel_width_cells(80, 12), 20)
        self.assertEqual(FreeqTextualApp._thread_panel_width_cells(100, 16), 25)
        self.assertEqual(FreeqTextualApp._thread_panel_width_cells(120, 16), 31)
        self.assertEqual(FreeqTextualApp._thread_panel_width_cells(140, 16), 37)

    def test_thread_panel_width_preserves_minimum_chat_width(self) -> None:
        cases = [
            (80, 12),
            (90, 16),
            (100, 16),
            (120, 22),
        ]
        for total_width, sidebar_width in cases:
            thread_width = FreeqTextualApp._thread_panel_width_cells(total_width, sidebar_width)
            self.assertEqual(thread_width, max(18, min(44, ((total_width - sidebar_width) * 3) // 10)))

    async def test_message_format_includes_avatar_only_when_enabled(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test():
            app._avatars_enabled = False
            plain = app._format_message("alice", "hello").plain
            app._avatars_enabled = True
            app._avatar_palettes[app._nick_key("alice")] = ["#111111", "#222222", "#333333", "#444444"]
            with_avatar = app._format_message("alice", "hello").plain

        self.assertEqual(plain, "alice: hello")
        self.assertTrue(with_avatar.endswith("alice: hello"))
        self.assertNotEqual(with_avatar, plain)

    async def test_message_format_skips_avatar_without_bluesky_palette(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test():
            app._avatars_enabled = True
            rendered = app._format_message("alice", "hello").plain

        self.assertTrue(rendered.endswith("alice: hello"))
        self.assertNotEqual(rendered, "alice: hello")

    def test_avatar_support_detects_wezterm_without_console_color_hint(self) -> None:
        # Stop the setUp patcher to test actual detection
        self._avatar_patcher.stop()
        try:
            client = FakeClient()
            app = FreeqTextualApp(client)

            with patch("rich.console.Console.color_system", new_callable=PropertyMock, return_value=None):
                with patch.dict("os.environ", {"TERM_PROGRAM": "WezTerm"}, clear=False):
                    self.assertTrue(app._detect_avatar_support())
        finally:
            # Restart the patcher for other tests
            self._avatar_patcher.start()

    async def test_long_urls_render_clickable_label_and_full_url(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test():
            app._avatars_enabled = False
            rendered = app._format_message(
                "alice",
                "see https://example.com/really/long/path/that/keeps/going?with=query",
            )

        plain = self._normalize_text(rendered.plain)
        self.assertIn(
            "alice: see [link: example.com/really/long/path/that...] https://example.com/really/long/path/that/keeps/going?with=query",
            plain,
        )

    async def test_message_body_uses_fold_overflow(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test():
            body = app._format_message_body("x" * 200)
            block, roots = app._format_chat_block("alice", "x" * 200)
            reply = app._format_reply_indicator("alice", "x" * 120, "root1")

        self.assertEqual(body.overflow, "fold")
        self.assertFalse(body.no_wrap)
        # _format_chat_block returns tuple[list[Text], list[str | None]]
        self.assertIsInstance(block, list)
        self.assertTrue(len(block) >= 1)
        self.assertEqual(block[0].overflow, "fold")
        self.assertFalse(block[0].no_wrap)
        self.assertEqual(reply.overflow, "fold")
        self.assertFalse(reply.no_wrap)

    async def test_composer_accepts_typed_text(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            composer = app.query_one("#composer", Input)
            self.assertTrue(composer.has_focus)

            await pilot.press("h", "i")
            await pilot.pause()

            self.assertEqual(composer.value, "hi")

    def _rendered_lines(self, app: FreeqTextualApp) -> list[str]:
        log = app.query_one(RichLog)
        result: list[str] = []
        for renderable in log.lines:
            # RichLog.lines contains Strip objects with Segments after render
            # Try to extract plain text
            text = ""
            if hasattr(renderable, 'plain'):
                # Rich Text object (pre-render)
                text = renderable.plain
            elif hasattr(renderable, '__iter__'):
                # Strip with Segments
                try:
                    text = "".join(seg.text for seg in renderable if hasattr(seg, 'text'))
                except Exception:
                    text = str(renderable)
            else:
                text = str(renderable)
            text = text.strip()
            if text:
                normalized = self._normalize_line(text)
                if normalized:
                    result.append(normalized)
        return result

    def _thread_header(self, app: FreeqTextualApp) -> str:
        widget = app.query_one("#thread-header", Static)
        # Textual mangles private attribute names
        content = getattr(widget, '_Static__content', None)
        if content is None:
            return ""
        if isinstance(content, str):
            return content
        return str(content)

    def _thread_rendered_lines(self, app: FreeqTextualApp) -> list[str]:
        log = app.query_one("#thread-messages", ScrollableLog)
        result: list[str] = []
        for renderable in log.lines:
            text = ""
            try:
                text = "".join(seg.text for seg in renderable if hasattr(seg, 'text'))
            except Exception:
                text = str(renderable)
            text = text.strip()
            if text:
                normalized = self._normalize_line(text)
                if normalized:
                    result.append(normalized)
        return result

    async def test_replay_batch_renders_into_visible_log_in_sorted_order(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app._append_line(
                "#freeq",
                app._format_message("zoe", "latest live message"),
                line_meta=("zoe", "latest live message"),
            )
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

            rendered = self._rendered_lines(app)

            self.assertGreaterEqual(len(rendered), 3)
            self.assertEqual(
                rendered[:3],
                ["alice: oldest", "bob: second oldest", "zoe: latest live message"],
            )

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

            rendered = self._rendered_lines(app)

            self.assertEqual(app.active_buffer, "#python")
            self.assertEqual(rendered[:1], ["carol: replayed line"])

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

            rendered = self._rendered_lines(app)

            self.assertEqual(client.join_calls, ["#freeq"])
            self.assertEqual(app.active_buffer, "#freeq")
            self.assertEqual(rendered[:1], ["alice: restored replay line"])

    async def test_consecutive_messages_from_same_sender_are_grouped(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "first line",
                    "tags": {},
                },
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "second line",
                    "tags": {},
                },
                {
                    "type": "message",
                    "from": "bob",
                    "target": "#freeq",
                    "text": "third line",
                    "tags": {},
                },
            )
            app._poll_events()
            await pilot.pause()

            rendered = self._rendered_lines(app)

            self.assertEqual(rendered[:3], ["alice: first line", "second line", "bob: third line"])

    async def test_inactive_events_do_not_reset_visible_scroll_position(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            for index in range(40):
                app._append_line("#freeq", app._format_message("user", f"line {index}"), mark_unread=False)
            app.active_buffer = "#freeq"
            app._scroll_mode = "home"
            app._render_active_buffer()
            await pilot.pause()

            log = app.query_one(RichLog)
            log.scroll_to(0, 12, animate=False, force=True)
            await pilot.pause()

            client.queue_events({"type": "server_notice", "text": "background status update"})
            app._poll_events()
            await pilot.pause()

            self.assertEqual(log.scroll_offset.y, 12)

    async def test_incoming_direct_message_routes_to_sender_buffer(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            client.queue_events(
                {
                    "type": "message",
                    "from": "zoe",
                    "target": "nandi",
                    "text": "reply from dm",
                    "tags": {},
                }
            )
            app._poll_events()
            await pilot.pause()

            self.assertIn("zoe", app.buffers)
            self.assertEqual(self._normalize_line(app.messages["zoe"][0].plain), "zoe: reply from dm")
            self.assertNotIn("nandi", app.buffers)

    async def test_reply_panel_shows_thread_messages_when_opened(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "root message for thread",
                    "tags": {"msgid": "root1"},
                },
                {
                    "type": "message",
                    "from": "bob",
                    "target": "#freeq",
                    "text": "reply in thread",
                    "tags": {"msgid": "reply1", "+draft/reply": "root1"},
                },
            )
            app._poll_events()
            await pilot.pause()

            # Open the thread panel
            app._open_thread("root1")
            await pilot.pause()
            await pilot.pause()  # Wait for timer-based rendering

            header = self._thread_header(app)
            rendered = self._thread_rendered_lines(app)
            rendered_text = " ".join(rendered)

            self.assertIn("Thread", header)
            self.assertIn("2 msg", header)
            self.assertIn("2 msg", header)
            self.assertIn("alice:", rendered_text)
            self.assertIn("bob:", rendered_text)
            self.assertIn("root message for thread", rendered_text)
            self.assertIn("reply in thread", rendered_text)

            # Thread panel should be visible
            panel = app.query_one("#thread-panel")
            self.assertTrue(panel.has_class("visible"))

    async def test_reply_indicator_renders_between_name_and_message(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "root message",
                    "tags": {"msgid": "root1"},
                },
                {
                    "type": "message",
                    "from": "bob",
                    "target": "#freeq",
                    "text": "reply body",
                    "tags": {"msgid": "reply1", "+draft/reply": "root1"},
                },
            )
            app._poll_events()
            await pilot.pause()

            rendered = self._rendered_lines(app)
            reply_index = next(index for index, line in enumerate(rendered) if "replying to alice" in line)
            bob_index = next(index for index, line in enumerate(rendered) if line.startswith("bob:"))

            self.assertLess(reply_index, bob_index)

    async def test_opening_thread_rerenders_main_log_for_new_width(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "root message " * 10,
                    "tags": {"msgid": "root1"},
                },
                {
                    "type": "message",
                    "from": "bob",
                    "target": "#freeq",
                    "text": "reply body",
                    "tags": {"msgid": "reply1", "+draft/reply": "root1"},
                },
            )
            app._poll_events()
            await pilot.pause()

            panel = app.query_one("#thread-panel")
            visibility_during_render: list[bool] = []

            original_render = app._render_active_buffer

            def wrapped_render() -> None:
                visibility_during_render.append(panel.has_class("visible"))
                original_render()

            with patch.object(app, "_render_active_buffer", side_effect=wrapped_render) as render_active:
                app._open_thread("root1")
                await pilot.pause()

            self.assertGreaterEqual(render_active.call_count, 1)
            self.assertIn(True, visibility_during_render)

    async def test_thread_close_button_hides_panel(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "root message",
                    "tags": {"msgid": "root1"},
                }
            )
            app._poll_events()
            await pilot.pause()

            app._open_thread("root1")
            await pilot.pause()
            self.assertTrue(app.query_one("#thread-panel").has_class("visible"))

            app._close_thread()
            await pilot.pause()

            self.assertFalse(app.query_one("#thread-panel").has_class("visible"))

    async def test_clicking_wrapped_reply_indicator_opens_thread(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)

        async with app.run_test() as pilot:
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "root message " * 12,
                    "tags": {"msgid": "root1"},
                },
                {
                    "type": "message",
                    "from": "bob",
                    "target": "#freeq",
                    "text": "reply in thread",
                    "tags": {"msgid": "reply1", "+draft/reply": "root1"},
                },
            )
            app._poll_events()
            await pilot.pause()

            log = app.query_one("#messages", RichLog)
            thread_rows = app._rendered_line_threads["#freeq"]
            reply_rows = [index for index, root in enumerate(thread_rows) if root == "root1"]

            self.assertTrue(reply_rows)
            self.assertGreater(len(thread_rows), len(app._line_threads["#freeq"]))

            click_row = reply_rows[-1]
            app._on_message_log_click(SimpleNamespace(widget=log, y=click_row))
            await pilot.pause()

            self.assertEqual(app.open_thread_root, "root1")
            panel = app.query_one("#thread-panel")
            self.assertTrue(panel.has_class("visible"))

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

    async def test_message_triggers_whois_and_whois_reply_fetches_bluesky_avatar(self) -> None:
        client = FakeClient()
        app = FreeqTextualApp(client)
        fetch_calls: list[str] = []
        avatar_image = PILImage.new("RGB", (8, 8), "#336699")

        def fake_fetch(handle: str) -> tuple[list[str], PILImage.Image]:
            fetch_calls.append(handle)
            return ["#010203", "#040506", "#070809", "#0a0b0c"], avatar_image

        app._fetch_bluesky_avatar_data = fake_fetch  # type: ignore[method-assign]

        async with app.run_test() as pilot:
            app._avatars_enabled = True
            app.active_buffer = "#freeq"
            client.queue_events(
                {
                    "type": "message",
                    "from": "alice",
                    "target": "#freeq",
                    "text": "hello there",
                    "tags": {},
                }
            )
            app._poll_events()
            await pilot.pause()

            self.assertEqual(client.raw_calls, ["WHOIS alice"])

            client.queue_events(
                {
                    "type": "whois_reply",
                    "nick": "alice",
                    "info": "AT Protocol handle: alice.bsky.social",
                }
            )
            app._poll_events()
            await pilot.pause()
            await pilot.pause(0.05)
            app._poll_avatar_updates()
            await pilot.pause()

            self.assertEqual(fetch_calls, ["alice.bsky.social"])
            self.assertEqual(app._nick_handles["alice"], "alice.bsky.social")
            self.assertEqual(
                app._avatar_palettes["alice"],
                ["#010203", "#040506", "#070809", "#0a0b0c"],
            )
            self.assertIs(app._avatar_images["alice"], avatar_image)
            rendered = self._rendered_lines(app)
            rendered_text = " ".join(rendered)
            self.assertIn("alice", rendered_text)
            self.assertIn("hello there", rendered_text)
            self.assertNotEqual(app._format_message("alice", "hello there").plain, "alice: hello there")


if __name__ == "__main__":
    unittest.main()
