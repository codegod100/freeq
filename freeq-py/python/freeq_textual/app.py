from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
import json
from pathlib import Path
import webbrowser

from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.reactive import reactive
from textual.widgets import Footer, Header, Input, ListItem, ListView, RichLog, Static

from .client import BrokerAuthFlow, FreeqAuthBroker, FreeqClient


@dataclass(slots=True)
class BufferState:
    name: str
    unread: int = 0


@dataclass(slots=True)
class BatchState:
    target: str
    batch_type: str
    lines: list[tuple[str, str]]


class BufferList(ListView):
    def update_buffers(self, buffers: list[BufferState], active: str) -> None:
        self.clear()
        for buffer in buffers:
            label = buffer.name
            if buffer.unread:
                label = f"{label} ({buffer.unread})"
            item = ListItem(Static(label), name=buffer.name)
            if buffer.name == active:
                item.add_class("active")
            self.append(item)


class FreeqTextualApp(App[None]):
    BINDINGS = [
        Binding("ctrl+c", "quit", "Quit"),
    ]

    active_buffer = reactive("status")

    def __init__(
        self,
        client: FreeqClient,
        initial_channel: str | None = None,
        auth_broker: FreeqAuthBroker | BrokerAuthFlow | None = None,
        auth_handle: str | None = None,
        session_path: Path | None = None,
        cached_auth: dict | None = None,
        config_path: Path | None = None,
        ui_config: dict | None = None,
    ) -> None:
        super().__init__()
        self.client = client
        self.initial_channel = initial_channel
        self.auth_broker = auth_broker
        self.auth_handle = auth_handle
        self.session_path = session_path
        self.cached_auth = cached_auth
        self.config_path = config_path
        self.ui_config = ui_config or {}
        self.buffers: dict[str, BufferState] = {"status": BufferState("status")}
        self.messages: dict[str, list[str]] = defaultdict(list)
        self.pending_auth_session: str | None = None
        self.pending_rejoin: set[str] = set()
        self.batches: dict[str, BatchState] = {}
        self.channel_members: dict[str, set[str]] = defaultdict(set)
        self.restore_history_targets: set[str] = set()
        self._scroll_to_end = False
        self._theme_ready = False

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            yield BufferList(id="sidebar")
            yield RichLog(id="messages", wrap=True, markup=True, auto_scroll=False)
        yield Input(
            placeholder="Type a message or /join #channel",
            id="composer",
            classes="-textual-compact",
        )
        yield Footer()

    def on_mount(self) -> None:
        self.theme = self.ui_config.get("theme", self.theme)
        self._theme_ready = True
        composer = self.query_one("#composer", Input)
        self.client.connect()
        if self.initial_channel:
            self.client.join(self.initial_channel)
        self.set_interval(0.1, self._poll_events)
        if self.auth_broker:
            self.set_interval(0.5, self._poll_auth)
        self._refresh_sidebar()
        self._render_active_buffer()
        composer.focus()
        if self.cached_auth:
            self._restore_auth()
        elif self.auth_handle:
            self._begin_auth(self.auth_handle)

    def _refresh_sidebar(self) -> None:
        ordered = sorted(self.buffers.values(), key=lambda buffer: (buffer.name != "status", buffer.name))
        self.query_one(BufferList).update_buffers(ordered, self.active_buffer)

    def _buffer_key(self, buffer_name: str) -> str:
        if buffer_name == "status":
            return "status"
        return buffer_name.casefold()

    def _display_name(self, buffer_name: str) -> str:
        key = self._buffer_key(buffer_name)
        return self.buffers.get(key, BufferState(buffer_name)).name

    def _nick_key(self, nick: str) -> str:
        return nick.lstrip("@+").casefold()

    def _ensure_buffer(self, buffer_name: str) -> str:
        key = self._buffer_key(buffer_name)
        if key not in self.buffers:
            self.buffers[key] = BufferState(buffer_name)
        else:
            self.buffers[key].name = buffer_name
        return key

    def _append_line(self, buffer_name: str, line: str, *, mark_unread: bool = True) -> None:
        key = self._ensure_buffer(buffer_name)
        if key != self.active_buffer and mark_unread:
            self.buffers[key].unread += 1
        self.messages[key].append(line)

    def _prepend_lines(self, buffer_name: str, lines: list[str]) -> None:
        key = self._ensure_buffer(buffer_name)
        self.messages[key] = list(lines) + self.messages[key]

    def _request_history(self, channel: str) -> None:
        self.client.history_latest(self._display_name(channel), 50)

    def _session_channels(self) -> list[str]:
        return sorted(
            buffer.name
            for key, buffer in self.buffers.items()
            if key != "status" and (buffer.name.startswith("#") or buffer.name.startswith("&"))
        )

    def _render_active_buffer(self) -> None:
        self.title = f"freeq - {self._display_name(self.active_buffer)}"
        log = self.query_one(RichLog)
        log.clear()
        for line in self.messages[self.active_buffer]:
            log.write(line)
        if self._scroll_to_end:
            log.scroll_end(animate=False)
        else:
            log.scroll_home(animate=False)
        self._scroll_to_end = False
        if self.active_buffer in self.buffers:
            self.buffers[self.active_buffer].unread = 0
        self._refresh_sidebar()

    def _poll_events(self) -> None:
        saw_event = False
        while True:
            event = self.client.poll_event()
            if event is None:
                break
            saw_event = True
            self._handle_event(event)
        if saw_event:
            self._render_active_buffer()

    def _poll_auth(self) -> None:
        if self.auth_broker is None or self.pending_auth_session is None:
            return
        result = self.auth_broker.poll_auth_result(self.pending_auth_session)
        if result is None:
            return
        self.pending_auth_session = None
        if "error" in result:
            self._append_line("status", f"[red]auth failed[/]: {result['error']}", mark_unread=False)
            self._render_active_buffer()
            return
        token = result.get("token")
        handle = result.get("handle", "?")
        if not token:
            self._append_line("status", "[red]auth failed[/]: broker returned no token", mark_unread=False)
            self._render_active_buffer()
            return
        self._save_auth_session(result)
        self.pending_rejoin = {name for name in self.buffers if name != "status"}
        self.restore_history_targets = {
            self._buffer_key(name)
            for name in self.pending_rejoin
            if name.startswith("#") or name.startswith("&")
        }
        self.client.reconnect_with_web_token(token)
        self._append_line("status", f"[green]auth ok[/]: reconnecting as {handle}", mark_unread=False)
        self._render_active_buffer()

    def _begin_auth(self, handle: str) -> None:
        if self.auth_broker is None:
            self._append_line("status", "[red]auth unavailable[/]: set BROKER_SHARED_SECRET", mark_unread=False)
            self._render_active_buffer()
            return
        login = self.auth_broker.start_login(handle)
        self.pending_auth_session = login["session_id"]
        webbrowser.open(login["url"])
        self._append_line(
            "status",
            f"[yellow]auth[/]: opened browser for {handle} via {self.auth_broker.base_url}",
            mark_unread=False,
        )
        self._render_active_buffer()

    def _restore_auth(self) -> None:
        if self.auth_broker is None or not hasattr(self.auth_broker, "refresh_session") or not self.cached_auth:
            return
        broker_token = self.cached_auth.get("broker_token")
        handle = self.cached_auth.get("handle", "?")
        cached_channels = list(self.cached_auth.get("channels", []))
        if not broker_token:
            return
        result = self.auth_broker.refresh_session(broker_token)
        if result is None or "token" not in result:
            self._append_line("status", f"[yellow]auth[/]: cached session for {handle} expired", mark_unread=False)
            self._clear_saved_session()
            self._render_active_buffer()
            return
        self.pending_rejoin = set(cached_channels)
        self.restore_history_targets = {
            self._buffer_key(channel)
            for channel in self.pending_rejoin
            if channel.startswith("#") or channel.startswith("&")
        }
        for channel in sorted(self.pending_rejoin):
            self._ensure_buffer(channel)
        self._save_auth_session({**self.cached_auth, **result, "channels": cached_channels})
        self.client.reconnect_with_web_token(result["token"])
        self._append_line("status", f"[green]auth restored[/]: {handle}", mark_unread=False)
        self._render_active_buffer()

    def _save_auth_session(self, result: dict) -> None:
        broker_token = result.get("broker_token") or (self.cached_auth or {}).get("broker_token")
        if not broker_token:
            return
        payload = {
            "broker_token": broker_token,
            "handle": result.get("handle") or (self.cached_auth or {}).get("handle"),
            "did": result.get("did") or (self.cached_auth or {}).get("did"),
            "nick": result.get("nick") or (self.cached_auth or {}).get("nick"),
            "channels": self._session_channels(),
        }
        self._write_session(payload)

    def _write_session(self, payload: dict) -> None:
        if self.session_path is None:
            return
        self.session_path.parent.mkdir(parents=True, exist_ok=True)
        self.session_path.write_text(json.dumps(payload))
        self.cached_auth = payload

    def _persist_session_channels(self) -> None:
        if not self.cached_auth:
            return
        self._write_session({
            **self.cached_auth,
            "channels": self._session_channels(),
        })

    def _clear_saved_session(self) -> None:
        self.cached_auth = None
        if self.session_path and self.session_path.exists():
            self.session_path.unlink()

    def _save_ui_config(self) -> None:
        if self.config_path is None:
            return
        payload = {"theme": self.theme}
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(json.dumps(payload))
        self.ui_config = payload

    def action_toggle_dark(self) -> None:
        super().action_toggle_dark()
        self._save_ui_config()

    def watch_theme(self, theme: str) -> None:
        if self._theme_ready:
            self._save_ui_config()

    def _handle_event(self, event: dict) -> None:
        event_type = event.get("type")
        if event_type == "connected":
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[b]Connected[/] to {self.client.server_addr}", mark_unread=False)
            return
        if event_type == "registered":
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[b]Registered[/] as {event['nick']}", mark_unread=False)
            for channel in sorted(self.pending_rejoin):
                self.client.join(channel)
            self.pending_rejoin.clear()
            return
        if event_type == "nick_changed":
            old_nick = event["old_nick"]
            new_nick = event["new_nick"]
            for members in self.channel_members.values():
                if self._nick_key(old_nick) in members:
                    members.discard(self._nick_key(old_nick))
                    members.add(self._nick_key(new_nick))
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[yellow]nick[/]: {old_nick} -> {new_nick}", mark_unread=False)
            return
        if event_type == "authenticated":
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[green]authenticated[/] as {event['did']}", mark_unread=False)
            return
        if event_type == "auth_failed":
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[red]auth failed[/]: {event['reason']}", mark_unread=False)
            return
        if event_type == "names":
            channel = event["channel"]
            key = self._buffer_key(channel)
            self._ensure_buffer(channel)
            members = self.channel_members[key]
            members.clear()
            members.update(self._nick_key(nick) for nick in event.get("nicks", []))
            return
        if event_type == "joined":
            channel = event["channel"]
            key = self._buffer_key(channel)
            nick_key = self._nick_key(event["nick"])
            members = self.channel_members[key]
            is_self = event["nick"].casefold() == self.client.nick.casefold()
            already_present = nick_key in members
            members.add(nick_key)
            if is_self:
                self._ensure_buffer(channel)
                if self.active_buffer == "status":
                    self.active_buffer = key
                self._persist_session_channels()
            elif not already_present:
                self._scroll_to_end = self.active_buffer == key
                self._append_line(channel, f"[green]+[/] {event['nick']} joined {channel}")
            return
        if event_type == "batch_start":
            batch_id = event["id"]
            target = self._display_name(event.get("target") or "status")
            self.batches[batch_id] = BatchState(
                target=target,
                batch_type=event.get("batch_type", ""),
                lines=[],
            )
            return
        if event_type == "batch_end":
            batch_id = event["id"]
            batch = self.batches.pop(batch_id, None)
            if batch is not None and batch.lines:
                ordered = [line for _timestamp, line in sorted(batch.lines, key=lambda item: item[0])]
                self._prepend_lines(batch.target, ordered)
                if batch.batch_type == "chathistory":
                    self.restore_history_targets.discard(self._buffer_key(batch.target))
                    self.active_buffer = self._buffer_key(batch.target)
            return
        if event_type == "names_end":
            channel = event["channel"]
            key = self._buffer_key(channel)
            if key in self.restore_history_targets:
                self.restore_history_targets.discard(key)
                self.set_timer(0.1, lambda channel=channel: self._request_history(channel))
            return
        if event_type == "parted":
            channel = event["channel"]
            key = self._buffer_key(channel)
            self.channel_members[key].discard(self._nick_key(event["nick"]))
            if event["nick"].casefold() == self.client.nick.casefold():
                if self.active_buffer == key:
                    self.active_buffer = "status"
                self.restore_history_targets.discard(key)
                self._persist_session_channels()
            else:
                self._scroll_to_end = self.active_buffer == key
                self._append_line(channel, f"[yellow]-[/] {event['nick']} left {channel}")
            return
        if event_type == "message":
            target = event["target"]
            sender = event["from"]
            text = event["text"]
            line = f"[cyan]{sender}[/]: {text}"
            batch_id = event.get("tags", {}).get("batch")
            if batch_id and batch_id in self.batches:
                batch_target = self.batches[batch_id].target or self._display_name(target)
                timestamp = event.get("tags", {}).get("time", "")
                self.batches[batch_id].lines.append((timestamp, line))
            else:
                self._scroll_to_end = self.active_buffer == self._buffer_key(target)
                self._append_line(target, line)
            return
        if event_type == "server_notice":
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[magenta]notice[/]: {event['text']}", mark_unread=False)
            return
        if event_type == "disconnected":
            self.channel_members.clear()
            self.restore_history_targets.clear()
            self._scroll_to_end = self.active_buffer == "status"
            self._append_line("status", f"[red]disconnected[/]: {event['reason']}", mark_unread=False)
            return
        self._scroll_to_end = self.active_buffer == "status"
        self._append_line("status", f"[dim]{event}[/dim]", mark_unread=False)

    @on(Input.Submitted, "#composer")
    def handle_submit(self, event: Input.Submitted) -> None:
        text = event.value.strip()
        event.input.value = ""
        if not text:
            return
        if text.startswith("/join "):
            channel = text.split(maxsplit=1)[1].strip()
            self.client.join(channel)
            self._ensure_buffer(channel)
            self.active_buffer = self._buffer_key(channel)
            self._persist_session_channels()
            self._render_active_buffer()
            return
        if text.startswith("/auth "):
            handle = text.split(maxsplit=1)[1].strip()
            self._begin_auth(handle)
            return
        if text.startswith("/nick "):
            nick = text.split(maxsplit=1)[1].strip()
            self.client.set_nick(nick)
            self._append_line("status", f"changing nick to {nick}", mark_unread=False)
            self._render_active_buffer()
            return
        if text.startswith("/raw "):
            self.client.raw(text.split(maxsplit=1)[1])
            return
        target = self.active_buffer
        if target == "status":
            self._append_line("status", "join a channel before sending messages", mark_unread=False)
            self._render_active_buffer()
            return
        self.client.send_message(self._display_name(target), text)

    @on(ListView.Selected, "#sidebar")
    def handle_sidebar_select(self, event: ListView.Selected) -> None:
        if event.item.name is None:
            return
        self.active_buffer = self._buffer_key(event.item.name)
        self._render_active_buffer()

    def on_unmount(self) -> None:
        self._persist_session_channels()
