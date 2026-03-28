from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from textual import on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal
from textual.reactive import reactive
from textual.widgets import Footer, Header, Input, ListItem, ListView, RichLog, Static

from .client import FreeqClient


@dataclass(slots=True)
class BufferState:
    name: str
    unread: int = 0


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
    CSS = """
    Screen {
        layout: vertical;
    }

    #body {
        height: 1fr;
    }

    #sidebar {
        width: 28;
        border-right: solid $panel;
    }

    #messages {
        width: 1fr;
        border-left: solid $background 20%;
    }

    #composer {
        dock: bottom;
    }
    """

    BINDINGS = [
        Binding("ctrl+c", "quit", "Quit"),
        Binding("ctrl+j", "focus_compose", "Compose"),
    ]

    active_buffer = reactive("status")

    def __init__(
        self,
        client: FreeqClient,
        initial_channel: str | None = None,
    ) -> None:
        super().__init__()
        self.client = client
        self.initial_channel = initial_channel
        self.buffers: dict[str, BufferState] = {"status": BufferState("status")}
        self.messages: dict[str, list[str]] = defaultdict(list)

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            yield BufferList(id="sidebar")
            yield RichLog(id="messages", wrap=True, markup=True, auto_scroll=True)
        yield Input(placeholder="Type a message or /join #channel", id="composer")
        yield Footer()

    def on_mount(self) -> None:
        self.client.connect()
        if self.initial_channel:
            self.client.join(self.initial_channel)
        self.set_interval(0.1, self._poll_events)
        self._refresh_sidebar()
        self._render_active_buffer()

    def action_focus_compose(self) -> None:
        self.query_one("#composer", Input).focus()

    def _refresh_sidebar(self) -> None:
        ordered = sorted(self.buffers.values(), key=lambda buffer: (buffer.name != "status", buffer.name))
        self.query_one(BufferList).update_buffers(ordered, self.active_buffer)

    def _append_line(self, buffer_name: str, line: str, *, mark_unread: bool = True) -> None:
        if buffer_name not in self.buffers:
            self.buffers[buffer_name] = BufferState(buffer_name)
        if buffer_name != self.active_buffer and mark_unread:
            self.buffers[buffer_name].unread += 1
        self.messages[buffer_name].append(line)

    def _render_active_buffer(self) -> None:
        log = self.query_one(RichLog)
        log.clear()
        for line in self.messages[self.active_buffer]:
            log.write(line)
        if self.active_buffer in self.buffers:
            self.buffers[self.active_buffer].unread = 0
        self._refresh_sidebar()

    def _poll_events(self) -> None:
        while True:
            event = self.client.poll_event()
            if event is None:
                break
            self._handle_event(event)
        self._render_active_buffer()

    def _handle_event(self, event: dict) -> None:
        event_type = event.get("type")
        if event_type == "connected":
            self._append_line("status", f"[b]Connected[/] to {self.client.server_addr}", mark_unread=False)
            return
        if event_type == "registered":
            self._append_line("status", f"[b]Registered[/] as {event['nick']}", mark_unread=False)
            return
        if event_type == "joined":
            channel = event["channel"]
            self._append_line(channel, f"[green]+[/] {event['nick']} joined {channel}")
            return
        if event_type == "parted":
            channel = event["channel"]
            self._append_line(channel, f"[yellow]-[/] {event['nick']} left {channel}")
            return
        if event_type == "message":
            target = event["target"]
            sender = event["from"]
            text = event["text"]
            self._append_line(target, f"[cyan]{sender}[/]: {text}")
            return
        if event_type == "server_notice":
            self._append_line("status", f"[magenta]notice[/]: {event['text']}", mark_unread=False)
            return
        if event_type == "disconnected":
            self._append_line("status", f"[red]disconnected[/]: {event['reason']}", mark_unread=False)
            return
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
            self.active_buffer = channel
            self._append_line("status", f"joining {channel}", mark_unread=False)
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
        self.client.send_message(target, text)
        self._append_line(target, f"[bold]{self.client.nick}[/]: {text}", mark_unread=False)
        self._render_active_buffer()

    @on(ListView.Selected, "#sidebar")
    def handle_sidebar_select(self, event: ListView.Selected) -> None:
        if event.item.name is None:
            return
        self.active_buffer = event.item.name
        self._render_active_buffer()
