from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
import hashlib
import os
import json
from io import BytesIO
from pathlib import Path
from queue import SimpleQueue
import re
import threading
import webbrowser
from urllib.request import urlopen

from rich.text import Text
from textual import events, on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.css.query import NoMatches
from textual.reactive import reactive
from textual.widgets import Button, Footer, Header, Input, ListItem, ListView, Static

from .client import BrokerAuthFlow, FreeqAuthBroker, FreeqClient
from .widgets import BufferList, MessagesPanel, MessagesPanelWithThread, ScrollableLog, ThreadMessage, ThreadPanel
from .widgets.layout_render import LayoutAwareRender

try:
    from PIL import Image, ImageOps, UnidentifiedImageError
except ImportError:  # pragma: no cover - dependency is optional outside the dev shell
    Image = None
    ImageOps = None
    UnidentifiedImageError = Exception

try:
    from rich_pixels import Pixels
except ImportError:  # pragma: no cover - dependency is optional outside the dev shell
    Pixels = None


# ── Debug logging ─────────────────────────────────────────────────────────
# Writes to /tmp/freeq-tui.log for troubleshooting thread panel issues.
# Can be disabled by commenting out the body or setting _DBG_PATH to /dev/null.

_DBG_PATH = "/tmp/freeq-tui.log"


def _dbg(msg: str) -> None:
    import datetime
    with open(_DBG_PATH, "a") as f:
        f.write(f"{datetime.datetime.now().isoformat()} {msg}\n")


# ═══════════════════════════════════════════════════════════════════════════
# EVENT LIFECYCLE LOGGING
# All event handlers below must log their lifecycle for debugging.
# Keep this comment and all _dbg() calls in place.
# ═══════════════════════════════════════════════════════════════════════════


# ── Nick colorization ──────────────────────────────────────────────────────

_NICK_PALETTE = [
    "cyan",
    "bright_magenta",
    "bright_green",
    "bright_yellow",
    "bright_blue",
    "bright_cyan",
    "magenta",
    "green",
    "yellow",
    "blue",
    "red",
    "bright_red",
]


def _nick_color(nick: str) -> str:
    """Deterministic color for a nick based on hash."""
    digest = hashlib.md5(nick.encode()).hexdigest()
    idx = int(digest, 16) % len(_NICK_PALETTE)
    return _NICK_PALETTE[idx]


_URL_RE = re.compile(r"(?P<url>(?:https?|wss?)://[^\s<>()]+)")


def _avatar_palette(nick: str) -> list[str]:
    digest = hashlib.md5(nick.encode()).digest()
    colors: list[str] = []
    for offset in range(0, 12, 3):
        red = 48 + digest[offset] % 160
        green = 48 + digest[offset + 1] % 160
        blue = 48 + digest[offset + 2] % 160
        colors.append(f"#{red:02x}{green:02x}{blue:02x}")
    return colors


# ── Data classes ───────────────────────────────────────────────────────────


@dataclass(slots=True)
class BufferState:
    name: str
    unread: int = 0


@dataclass(slots=True)
class BatchState:
    target: str
    batch_type: str
    lines: list[tuple[str, Text]]
    thread_roots: list[str | None]
    line_metas: list[tuple[str, str] | None]


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


class FreeqTextualApp(App[None], LayoutAwareRender):
    DEFAULT_CSS = """
    #messages {
        width: 1fr;
    }

    # Thread panel CSS is now in ThreadPanel widget
    # ScrollableLog has its own CSS with padding

    #composer {
        border: solid $panel-lighten-2;
        height: 3;
        padding: 0 1;
    }
    """

    BINDINGS = [
        Binding("ctrl+c", "quit", "Quit"),
        Binding("escape", "close_thread", "Close thread", show=False),
    ]

    active_buffer = reactive("status")
    open_thread_root = reactive("")

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
        self.messages: dict[str, list[Text]] = defaultdict(list)
        self.pending_auth_session: str | None = None
        self.pending_rejoin: set[str] = set()
        self.batches: dict[str, BatchState] = {}
        self.channel_members: dict[str, set[str]] = defaultdict(set)
        self.channel_topics: dict[str, str] = {}
        self.message_index: dict[str, MessageState] = {}
        self.threads: dict[str, ThreadState] = {}
        self._thread_activity = 0
        self.restore_history_targets: set[str] = set()
        self._scroll_mode = "preserve"
        self._theme_ready = False
        self._avatars_enabled = False
        # Maps buffer_key -> list of (thread_root | None) per logical appended line
        self._line_threads: dict[str, list[str | None]] = defaultdict(list)
        # Maps buffer_key -> list of (sender, raw_text) for normal messages, else None
        self._line_message_meta: dict[str, list[tuple[str, str] | None]] = defaultdict(list)
        # Maps buffer_key -> list of (thread_root | None) per rendered RichLog row
        self._rendered_line_threads: dict[str, list[str | None]] = defaultdict(list)
        self._nick_handles: dict[str, str] = {}
        self._avatar_palettes: dict[str, list[str]] = {}
        self._avatar_images: dict[str, object] = {}
        self._avatar_rows: dict[str, list[list[str]]] = {}
        self._pending_whois: set[str] = set()
        self._pending_avatar_fetches: set[str] = set()
        self._avatar_updates: SimpleQueue[tuple[str, list[str] | None, object | None]] = SimpleQueue()

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            yield BufferList(id="sidebar")
            yield MessagesPanel()
        yield Input(
            placeholder="Type a message or /join #channel",
            id="composer",
            classes="-textual-compact",
        )
        yield Footer(compact=True)

    def on_mount(self) -> None:
        _dbg("App.on_mount()")
        self.theme = self.ui_config.get("theme", self.theme)
        self._theme_ready = True
        self._avatars_enabled = self._detect_avatar_support()
        composer = self.query_one("#composer", Input)
        self._refresh_layout_widths()
        if self._avatars_enabled and Pixels is None:
            self._append_status("avatars: rich-pixels unavailable, using tile fallback", "yellow")
        self._append_status(f"connecting to {self.client.server_addr}...", "dim")
        self._scroll_mode = "end"
        self._render_active_buffer()
        composer.focus()
        self.set_timer(0.01, self._start_client)
        self.set_interval(0.1, self._poll_events)
        self.set_interval(0.1, self._poll_avatar_updates)
        if self.auth_broker:
            self.set_interval(0.5, self._poll_auth)
        if self.cached_auth:
            self._restore_auth()
        elif self.auth_handle:
            self._begin_auth(self.auth_handle)
        self._seed_self_avatar_handle()
        _dbg("App.on_mount() done")

    # ── Rich text builders ─────────────────────────────────────────────────

    def _format_nick(self, nick: str) -> Text:
        """Colorized nick."""
        return Text(nick, style=_nick_color(nick))

    def _detect_avatar_support(self) -> bool:
        forced = os.environ.get("FREEQ_AVATARS")
        if forced is not None:
            return forced.lower() in {"1", "true", "yes", "on"}
        color_system = str(self.console.color_system or "").lower()
        if color_system in {"truecolor", "256"}:
            return True
        term_program = os.environ.get("TERM_PROGRAM", "").lower()
        colorterm = os.environ.get("COLORTERM", "").lower()
        term = os.environ.get("TERM", "").lower()
        return (
            term_program == "wezterm"
            or "truecolor" in colorterm
            or "24bit" in colorterm
            or "256color" in term
        )

    def _format_avatar(self, nick: str) -> Text:
        nick_key = self._nick_key(nick)
        rows = self._avatar_rows.get(nick_key)
        if rows:
            avatar = Text()
            for color in rows[0]:
                avatar.append("█", style=color)
            avatar.append(" ")
            return avatar

        colors = self._avatar_palettes.get(nick_key) or _avatar_palette(nick)
        avatar = Text()
        avatar.append("█", style=colors[0])
        avatar.append("█", style=colors[1])
        avatar.append("█", style=colors[2])
        avatar.append("█", style=colors[3])
        avatar.append(" ")
        return avatar

    def _fallback_avatar_rows(self, nick: str) -> list[list[str]]:
        colors = self._avatar_palettes.get(self._nick_key(nick)) or _avatar_palette(nick)
        return [
            [colors[0], colors[1], colors[2], colors[3]],
            [colors[3], colors[2], colors[1], colors[0]],
        ]

    def _avatar_rows_for_nick(self, nick: str) -> list[list[str]]:
        return self._avatar_rows.get(self._nick_key(nick)) or self._fallback_avatar_rows(nick)

    def _display_url(self, url: str) -> str:
        # Add soft break opportunities so long URLs wrap instead of being cropped.
        for token in ("/", "?", "&", "=", "#", "-", "_", "."):
            url = url.replace(token, f"{token}\u200b")
        return url

    def _format_message_body(self, text: str) -> Text:
        body = Text(no_wrap=False, overflow="fold")
        last_end = 0
        for match in _URL_RE.finditer(text):
            start, end = match.span("url")
            if start > last_end:
                body.append(text[last_end:start])
            url = match.group("url")
            # Wrap URL text itself in hyperlink (works across line wraps)
            display_url = self._display_url(url)
            body.append(display_url, style=f"underline cyan link {url}")
            last_end = end
        if last_end < len(text):
            body.append(text[last_end:])
        return body

    def _format_message(self, sender: str, text: str, width: int = 0) -> Text:
        """A chat message: `<nick>: <text>` with colored nick, optionally wrapped to width.
        
        Note: This is for channel messages with indent-based wrapping.
        For thread panel, use _format_thread_message instead.
        """
        parts: list[Text] = []
        if self._avatars_enabled:
            avatar = self._format_avatar(sender)
            if avatar.plain:
                parts.append(avatar)
        parts.append(self._format_nick(sender))
        parts.append(Text(": "))
        
        # Calculate indent after nick (with avatar space if present)
        indent = 0
        if self._avatars_enabled:
            indent = 5  # avatar + space
        nick_len = len(sender) + 2  # ": "
        indent += nick_len
        
        if width > 0:
            # Wrap text to width with indent
            lines = self._format_message_lines(text, indent, width)
            if lines:
                # First line goes on same line as nick
                parts.append(self._format_message_body(lines[0].plain.lstrip()))
                result = Text().assemble(*parts)
                # Continuation lines
                for cont_line in lines[1:]:
                    result.append(Text("\n"))
                    result.append(cont_line)
                return result
        
        parts.append(self._format_message_body(text))
        return Text().assemble(*parts)

    def _format_thread_message(self, sender: str, text: str, width: int = 0) -> Text:
        """Simple thread message: `<nick>: <text>` with colored nick, no indent alignment."""
        name = Text(sender, style=f"bold {_nick_color(sender)}")
        
        if width > 0 and len(text) + len(sender) + 2 > width:
            # Wrap needed - first line on same line as nick
            available = width - len(sender) - 2  # ": "
            words = text.split()
            lines: list[str] = []
            current = ""
            for word in words:
                test = f"{current} {word}".strip()
                if len(test) <= available:
                    current = test
                else:
                    if current:
                        lines.append(current)
                    current = word
            if current:
                lines.append(current)
            
            if lines:
                result = Text().assemble(name, ": ", self._format_message_body(lines[0]))
                for cont_line in lines[1:]:
                    result.append(Text("\n"))
                    result.append(self._format_message_body(cont_line))
                return result
        
        
        return Text().assemble(name, ": ", self._format_message_body(text))

    def _format_header_lines(self, sender: str) -> list[Text]:
        """Return header line(s): avatar + nick. Only called when avatars enabled."""
        rows = self._avatar_rows_for_nick(sender)
        name = Text(sender, style=f"bold {_nick_color(sender)}")
        lines: list[Text] = []
        # Row 1: avatar + nick
        line1 = Text()
        for color in rows[0]:
            line1.append("\u2588", style=color)
        line1.append(" ")
        line1.append_text(name)
        lines.append(line1)
        # Row 2: avatar only
        line2 = Text()
        for color in rows[1]:
            line2.append("\u2588", style=color)
        lines.append(line2)
        return lines

    def _format_message_lines(self, text: str, indent: int, width: int) -> list[Text]:
        """Wrap message text to width, each line prefixed with indent spaces."""
        available = max(20, width - indent)
        words = text.split()
        lines: list[Text] = []
        current = ""
        for word in words:
            test = f"{current} {word}".strip()
            if len(test) <= available:
                current = test
            else:
                if current:
                    lines.append(Text(" " * indent + current))
                current = word
        if current:
            lines.append(Text(" " * indent + current))
        return lines

    def _format_chat_block(self, sender: str, text: str, width: int = 80, reply_indicator: Text | None = None, reply_thread_root: str | None = None) -> tuple[list[Text], list[str | None]]:
        """Return tuple of (lines, thread_roots) for a chat message.
        
        With avatars:
        - Line 1: ████ nick
        - Line 2: ████ reply indicator (if any) OR first line of message
        - Line 3+:      continuation (same column as line 2 text)
        
        Without avatars:
        - reply indicator (if any)
        - nick: message on one line with fold overflow
        """
        name = Text(sender, style=f"bold {_nick_color(sender)}")
        roots: list[str | None] = []
        
        if not self._avatars_enabled:
            # No avatar: reply indicator, then nick: message on one line
            result: list[Text] = []
            if reply_indicator:
                result.append(reply_indicator)
                roots.append(reply_thread_root)
            block = Text(no_wrap=False, overflow="fold")
            block.append_text(name)
            block.append(": ")
            block.append_text(self._format_message_body(text))
            result.append(block)
            roots.append(None)
            return result, roots
        
        
        # With avatars: nick on line 1, reply indicator or message on line 2
        rows = self._avatar_rows_for_nick(sender)
        indent = "     "  # 5 spaces - aligns with where text starts after "████ "
        text_avail = max(20, width - 5)
        
        # Line 1: avatar row 1 + nick
        line1 = Text()
        for color in rows[0]:
            line1.append("\u2588", style=color)
        line1.append(" ")
        line1.append_text(name)
        lines = [line1]
        roots = [None]  # nick line has no thread_root
        
        # Line 2: avatar row 2 + reply indicator (if any)
        if reply_indicator:
            reply_line = Text()
            for color in rows[1]:
                reply_line.append("\u2588", style=color)
            reply_line.append(" ")
            reply_line.append_text(reply_indicator)
            lines.append(reply_line)
            roots.append(reply_thread_root)
        
        # Wrap message text
        words = text.split()
        current = ""
        line_num = 0
        
        for word in words:
            test = f"{current} {word}".strip()
            test_display = self._format_message_body(test).plain
            if len(test_display) <= text_avail:
                current = test
            else:
                if current:
                    # First message line uses avatar row 2 only if no reply indicator
                    if line_num == 0 and not reply_indicator:
                        lines.append(self._make_avatar_text_line(rows[1], self._format_message_body(current)))
                    else:
                        cont = Text(indent)
                        cont.append_text(self._format_message_body(current))
                        lines.append(cont)
                    roots.append(None)
                current = word
                line_num += 1
        
        
        # Flush remaining text
        if current:
            if line_num == 0 and not reply_indicator:
                lines.append(self._make_avatar_text_line(rows[1], self._format_message_body(current)))
            else:
                cont = Text(indent)
                cont.append_text(self._format_message_body(current))
                lines.append(cont)
            roots.append(None)
        
        
        # Ensure at least 2 lines for avatar display
        if len(lines) == 1:
            lines.append(self._make_avatar_text_line(rows[1], Text()))
            roots.append(None)
        
        
        return lines, roots

    def _make_avatar_text_line(self, colors: list[str], text: Text) -> Text:
        """Create line with avatar row 2 + formatted text."""
        line = Text()
        for color in colors:
            line.append("\u2588", style=color)
        if text.plain:
            line.append(" ")
            line.append_text(text)
        return line

    def _format_reply_indicator(self, parent_sender: str, snippet: str, thread_root: str) -> Text:
        """Dim reply indicator: `  ↳ replying to <nick>: <snippet>`."""
        indicator = Text(no_wrap=False, overflow="fold")
        indicator.append("  \u21b3 ", style="dim")
        indicator.append("replying to ", style="dim italic")
        indicator.append(parent_sender, style=f"dim {_nick_color(parent_sender)}")
        indicator.append(": ", style="dim")
        indicator.append(snippet, style="dim")
        return indicator

    def _format_system(self, text: str, style: str = "") -> Text:
        """System/status message with optional style."""
        return Text(text, style=style, no_wrap=False, overflow="fold")

    def _with_trailing_padding(self, line: Text, spaces: int = 2) -> Text:
        padded = line.copy()
        padded.append(" " * spaces)
        return padded

    def _is_reply_indicator(self, line: Text) -> bool:
        return line.plain.startswith("  \u21b3 ")

    def _write_render_lines(
        self,
        log: ScrollableLog,
        lines: list[object],
        *,
        thread_roots: list[str | None] | None = None,
    ) -> list[str | None]:
        rendered_threads: list[str | None] = []
        roots = thread_roots or [None] * len(lines)
        for line, thread_root in zip(lines, roots):
            before = len(log.lines)
            log.write(line, scroll_end=False)
            added = max(1, len(log.lines) - before)
            rendered_threads.extend([thread_root] * added)
        return rendered_threads

    # ── Helpers ─────────────────────────────────────────────────────────────

    def _start_client(self) -> None:
        try:
            self.client.connect()
            if self.initial_channel:
                self.client.join(self.initial_channel)
        except Exception as exc:  # noqa: BLE001
            self._append_status(f"connect failed: {exc}", "red")
            self._render_active_buffer()

    def _refresh_sidebar(self) -> None:
        ordered = sorted(self.buffers.values(), key=lambda b: (b.name != "status", b.name))
        sidebar = self.query_one(BufferList)
        sidebar.update_buffers(ordered, self.active_buffer)

    @staticmethod
    def _buffer_label(buffer: BufferState) -> str:
        label = buffer.name
        if buffer.unread:
            label = f"{label} ({buffer.unread})"
        return label

    @classmethod
    def _sidebar_width_cells(cls, buffers: list[BufferState]) -> int:
        widest = max((len(cls._buffer_label(buffer)) for buffer in buffers), default=8)
        return max(12, min(22, widest + 4))

    @staticmethod
    def _thread_panel_width_cells(total_width: int, sidebar_width: int) -> int:
        available = max(0, total_width - sidebar_width)
        return max(18, min(44, (available * 3) // 10))

    def _refresh_layout_widths(self) -> None:
        """Refresh sidebar buffer list. Widths are handled by CSS percentages."""
        ordered = sorted(self.buffers.values(), key=lambda b: (b.name != "status", b.name))
        sidebar = self.query_one(BufferList)
        sidebar.update_buffers(ordered, self.active_buffer)

    def _buffer_key(self, buffer_name: str) -> str:
        if buffer_name == "status":
            return "status"
        return buffer_name.casefold()

    def _display_name(self, buffer_name: str) -> str:
        key = self._buffer_key(buffer_name)
        return self.buffers.get(key, BufferState(buffer_name)).name

    def _message_buffer_name(self, target: str, sender: str) -> str:
        if target.startswith("#") or target.startswith("&"):
            return target
        if sender.casefold() == self.client.nick.casefold():
            return target
        return sender

    def _nick_key(self, nick: str) -> str:
        return nick.lstrip("@+").casefold()

    def _ensure_buffer(self, buffer_name: str) -> str:
        key = self._buffer_key(buffer_name)
        if key not in self.buffers:
            self.buffers[key] = BufferState(buffer_name)
        else:
            self.buffers[key].name = buffer_name
        return key

    def _append_status(self, text: str, style: str = "") -> None:
        """Append a styled line to the status buffer."""
        key = self._ensure_buffer("status")
        self.messages[key].append(self._format_system(text, style))
        self._line_threads[key].append(None)
        self._line_message_meta[key].append(None)

    def _append_line(
        self,
        buffer_name: str,
        rich: Text,
        *,
        mark_unread: bool = True,
        thread_root: str = "",
        line_meta: tuple[str, str] | None = None,
    ) -> None:
        key = self._ensure_buffer(buffer_name)
        if key != self.active_buffer and mark_unread:
            self.buffers[key].unread += 1
        self.messages[key].append(rich)
        self._line_threads[key].append(thread_root or None)
        self._line_message_meta[key].append(line_meta)

    def _prepend_lines(
        self,
        buffer_name: str,
        lines: list[Text],
        *,
        thread_roots: list[str | None] | None = None,
        line_metas: list[tuple[str, str] | None] | None = None,
    ) -> None:
        key = self._ensure_buffer(buffer_name)
        self.messages[key] = list(lines) + self.messages[key]
        roots = thread_roots or [None] * len(lines)
        self._line_threads[key] = list(roots) + self._line_threads[key]
        metas = line_metas or [None] * len(lines)
        self._line_message_meta[key] = list(metas) + self._line_message_meta[key]

    def _renderable_lines(self, buffer_key: str, width: int = 80) -> tuple[list[object], list[str | None]]:
        renderable: list[object] = []
        render_roots: list[str | None] = []
        lines = self.messages[buffer_key]
        metas = self._line_message_meta[buffer_key]
        roots = self._line_threads[buffer_key]
        previous_sender: str | None = None
        previous_was_chat = False
        pending_reply_indicators: list[tuple[Text, str | None]] = []

        for index, (line, line_meta, thread_root) in enumerate(zip(lines, metas, roots)):
            if line_meta is None:
                if self._is_reply_indicator(line):
                    pending_reply_indicators.append((line, thread_root))
                    continue
                for pending_line, pending_root in pending_reply_indicators:
                    renderable.append(pending_line)
                    render_roots.append(pending_root)
                pending_reply_indicators.clear()
                renderable.append(line)
                render_roots.append(thread_root)
                next_meta = metas[index + 1] if index + 1 < len(metas) else None
                if next_meta is None:
                    renderable.append(Text(" "))
                    render_roots.append(None)
                previous_sender = None
                previous_was_chat = False
                continue

            sender, text = line_meta
            sender_key = self._nick_key(sender)
            is_first = not previous_was_chat or previous_sender != sender_key
            if is_first:
                # Get reply indicator (first pending) to embed in chat block
                reply_ind = pending_reply_indicators[0][0] if pending_reply_indicators else None
                reply_root = pending_reply_indicators[0][1] if pending_reply_indicators else None
                pending_reply_indicators.clear()
                block_lines, block_roots = self._format_chat_block(sender, text, width, reply_indicator=reply_ind, reply_thread_root=reply_root)
                for block_line, block_root in zip(block_lines, block_roots):
                    renderable.append(block_line)
                    render_roots.append(block_root)
            else:
                # Continuation of same sender - just message body, indented
                # Reply indicators already handled by first message
                pending_reply_indicators.clear()
                indent = 5 if self._avatars_enabled else 0
                for msg_line in self._format_message_lines(text, indent, width):
                    renderable.append(msg_line)
                    render_roots.append(None)

            next_meta = metas[index + 1] if index + 1 < len(metas) else None
            next_sender = self._nick_key(next_meta[0]) if next_meta is not None else None
            if next_meta is None or next_sender != sender_key:
                renderable.append(Text(" "))
                render_roots.append(None)

            previous_sender = sender_key
            previous_was_chat = True

        for pending_line, pending_root in pending_reply_indicators:
            renderable.append(pending_line)
            render_roots.append(pending_root)

        return renderable, render_roots

    def _request_history(self, channel: str) -> None:
        self.client.history_latest(self._display_name(channel), 50)

    def _snippet(self, text: str, length: int = 40) -> str:
        normalized = " ".join(text.split())
        if len(normalized) <= length:
            return normalized
        return normalized[: length - 3].rstrip() + "..."

    def _thread_reply_to(self, tags: dict) -> str | None:
        return tags.get("+draft/reply") or tags.get("+reply")

    def _touch_thread(self, thread: ThreadState) -> None:
        self._thread_activity += 1
        thread.latest_activity = self._thread_activity

    def _seed_self_avatar_handle(self) -> None:
        handle = (self.cached_auth or {}).get("handle") or self.auth_handle
        nick = (self.cached_auth or {}).get("nick") or self.client.nick
        if not handle or not nick:
            return
        self._set_avatar_handle(nick, handle)

    def _set_avatar_handle(self, nick: str, handle: str) -> None:
        nick_key = self._nick_key(nick)
        normalized = handle.lstrip("@").strip()
        if not normalized:
            return
        if self._nick_handles.get(nick_key) == normalized:
            return
        self._nick_handles[nick_key] = normalized
        self._start_avatar_fetch(nick_key, normalized)

    def _parse_whois_handle(self, info: str | list[str]) -> str | None:
        if isinstance(info, list):
            for item in info:
                handle = self._parse_whois_handle(item)
                if handle:
                    return handle
            return None
        prefix = "AT Protocol handle:"
        if info.startswith(prefix):
            return info[len(prefix):].strip()
        return None

    def _ensure_avatar_lookup(self, nick: str) -> None:
        if not self._avatars_enabled:
            return
        nick_key = self._nick_key(nick)
        if nick_key in self._avatar_palettes or nick_key in self._nick_handles or nick_key in self._pending_whois:
            return
        if nick_key == self._nick_key(self.client.nick):
            self._seed_self_avatar_handle()
            if nick_key in self._nick_handles:
                return
        self._pending_whois.add(nick_key)
        self.client.raw(f"WHOIS {nick}")

    def _prepare_avatar_image(self, image: object) -> object | None:
        if Image is None or ImageOps is None or not isinstance(image, Image.Image):
            return None
        prepared = ImageOps.fit(image.convert("RGB"), (4, 2), method=Image.Resampling.LANCZOS)
        return prepared

    def _avatar_rows_from_image(self, image: object) -> list[list[str]] | None:
        if Image is None or not isinstance(image, Image.Image):
            return None
        width, height = image.size
        if width <= 0 or height <= 0:
            return None
        rows: list[list[str]] = []
        for y in range(height):
            row: list[str] = []
            for x in range(width):
                red, green, blue = image.getpixel((x, y))
                row.append(f"#{red:02x}{green:02x}{blue:02x}")
            rows.append(row)
        return rows

    def _fetch_bluesky_avatar_data(self, handle: str) -> tuple[list[str] | None, object | None]:
        if Image is None:
            return None, None

        profile_url = (
            "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile"
            f"?actor={handle}"
        )
        with urlopen(profile_url, timeout=5) as response:
            profile = json.loads(response.read().decode("utf-8"))
        avatar_url = profile.get("avatar")
        if not avatar_url:
            return None

        with urlopen(avatar_url, timeout=5) as response:
            avatar_bytes = response.read()

        image = Image.open(BytesIO(avatar_bytes))
        prepared_image = self._prepare_avatar_image(image)
        palette_image = image.convert("RGB").resize((2, 2))
        colors: list[str] = []
        for y in range(2):
            for x in range(2):
                red, green, blue = palette_image.getpixel((x, y))
                colors.append(f"#{red:02x}{green:02x}{blue:02x}")
        return colors, prepared_image

    def _start_avatar_fetch(self, nick_key: str, handle: str) -> None:
        if nick_key in self._pending_avatar_fetches:
            return
        self._pending_avatar_fetches.add(nick_key)

        def worker() -> None:
            palette: list[str] | None = None
            avatar_image: object | None = None
            try:
                palette, avatar_image = self._fetch_bluesky_avatar_data(handle)
            except (OSError, ValueError, json.JSONDecodeError, UnidentifiedImageError) as exc:
                _dbg(f"avatar fetch failed nick={nick_key} handle={handle} error={exc}")
            self._avatar_updates.put((nick_key, palette, avatar_image))

        threading.Thread(target=worker, name=f"freeq-avatar-{nick_key}", daemon=True).start()

    def _poll_avatar_updates(self) -> None:
        updated_any = False
        while not self._avatar_updates.empty():
            nick_key, palette, avatar_image = self._avatar_updates.get()
            self._pending_avatar_fetches.discard(nick_key)
            if palette:
                self._avatar_palettes[nick_key] = palette
                _dbg(f"avatar ready nick={nick_key}")
            else:
                self._avatar_palettes.pop(nick_key, None)
            if avatar_image is not None:
                self._avatar_images[nick_key] = avatar_image
                rows = self._avatar_rows_from_image(avatar_image)
                if rows:
                    self._avatar_rows[nick_key] = rows
            else:
                self._avatar_images.pop(nick_key, None)
                self._avatar_rows.pop(nick_key, None)
            updated_any = True
        if updated_any:
            try:
                self._render_active_buffer()
            except NoMatches:
                return

    # ── Message recording ──────────────────────────────────────────────────

    def _record_message(self, buffer_name: str, sender: str, text: str, tags: dict) -> None:
        buffer_key = self._ensure_buffer(buffer_name)
        msgid = tags.get("msgid", "")
        reply_to = self._thread_reply_to(tags) or ""
        thread_root = msgid or reply_to or ""
        is_reply = bool(reply_to)

        if reply_to:
            parent = self.message_index.get(reply_to)
            if parent is not None:
                thread_root = parent.thread_root
            else:
                thread_root = reply_to

            thread = self.threads.get(thread_root)
            if thread is None:
                root_sender = parent.sender if parent is not None else "unknown"
                root_text = parent.text if parent is not None else "(parent not loaded)"
                thread = ThreadState(
                    buffer_key=buffer_key,
                    root_msgid=thread_root,
                    root_sender=root_sender,
                    root_text=root_text,
                )
                self.threads[thread_root] = thread
            thread.buffer_key = buffer_key
            thread.reply_count += 1
            thread.latest_sender = sender
            thread.latest_text = text
            self._touch_thread(thread)

        if msgid:
            self.message_index[msgid] = MessageState(
                buffer_key=buffer_key,
                sender=sender,
                text=text,
                thread_root=thread_root or msgid,
                msgid=msgid,
                reply_to=reply_to,
                is_reply=is_reply,
            )
            thread = self.threads.get(msgid)
            if thread is not None:
                thread.buffer_key = buffer_key
                thread.root_sender = sender
                thread.root_text = text

        # If a thread is currently open and this message belongs to it, refresh
        if thread_root and thread_root == self.open_thread_root:
            self._refresh_thread_panel()

    def _collect_thread_messages(self, thread_root: str) -> list[MessageState]:
        """Collect root + all replies for a thread, in order."""
        root = self.message_index.get(thread_root)
        result: list[MessageState] = []
        if root:
            result.append(root)
        for msg in self.message_index.values():
            if msg.thread_root == thread_root and msg.is_reply:
                result.append(msg)
        _dbg(f"_collect_thread_messages({thread_root[:8]!r}) -> {len(result)} msgs, root={'found' if root else 'NOT FOUND'}")
        if result:
            _dbg(f"  message_index keys sample: {list(self.message_index.keys())[:5]}")
        return result

    # ── Thread panel ───────────────────────────────────────────────────────

    def _thread_panel_is_open(self) -> bool:
        """Check if MessagesPanelWithThread is mounted (vs MessagesPanel)."""
        try:
            self.query_one(MessagesPanelWithThread)
            return True
        except Exception:
            return False

    def _open_thread(self, thread_root: str) -> None:
        """Open the thread panel - swap to MessagesPanelWithThread."""
        if not thread_root:
            return
        _dbg(f"_open_thread({thread_root[:8]!r})")
        self.open_thread_root = thread_root
        
        # Collect messages
        messages = self._collect_thread_messages(thread_root)
        _dbg(f"  collected {len(messages)} messages")
        thread_msgs = [ThreadMessage(m.sender, m.text) for m in messages]
        
        # Swap containers: remove MessagesPanel, mount MessagesPanelWithThread
        body = self.query_one("#body", Horizontal)
        old = None
        try:
            old = self.query_one(MessagesPanel)
        except Exception:
            pass
        
        if old:
            old.remove()
        
        new_panel = MessagesPanelWithThread(
            thread_root, thread_msgs, self._format_thread_message
        )
        body.mount(new_panel)
        # Panel triggers render via on_mount

    def _close_thread(self) -> None:
        """Close the thread panel - swap back to MessagesPanel."""
        _dbg(f"_close_thread() open_thread_root was {self.open_thread_root[:8] if self.open_thread_root else 'empty'}")
        self.open_thread_root = ""
        
        # Swap containers: remove MessagesPanelWithThread, mount MessagesPanel
        body = self.query_one("#body", Horizontal)
        old = None
        try:
            old = self.query_one(MessagesPanelWithThread)
        except Exception:
            pass
        
        if old:
            old.remove()
        
        new_panel = MessagesPanel()
        body.mount(new_panel)
        # Panel triggers render via on_mount
        self.call_later(lambda: self.query_one("#composer", Input).focus())

    @on(ThreadPanel.Closed)
    def handle_thread_panel_closed(self, event: ThreadPanel.Closed) -> None:
        """Handle thread panel closed event - swap back to MessagesPanel."""
        del event
        _dbg(f"handle_thread_panel_closed() open_thread_root={self.open_thread_root[:8] if self.open_thread_root else 'empty'}")
        self.open_thread_root = ""
        
        # Swap back to MessagesPanel
        body = self.query_one("#body", Horizontal)
        old = None
        try:
            old = self.query_one(MessagesPanelWithThread)
        except Exception:
            pass
        
        if old:
            old.remove()
        
        new_panel = MessagesPanel()
        body.mount(new_panel)
        # Panel triggers render via on_mount
        self.query_one("#composer", Input).focus()

    @on(ThreadPanel.ReplySent)
    def handle_thread_panel_reply(self, event: ThreadPanel.ReplySent) -> None:
        """Handle reply sent from thread panel."""
        _dbg(f"handle_thread_panel_reply(root={event.thread_root[:8]!r}, text={event.text[:20]!r}...)")
        target = self._display_name(self.active_buffer)
        if self.active_buffer == "status":
            return
        self._send_reply(target, event.thread_root, event.text)

    def _refresh_thread_panel(self) -> None:
        """Refresh the thread panel with current messages."""
        if not self.open_thread_root:
            return
        try:
            panel = self.query_one(MessagesPanelWithThread)
            messages = self._collect_thread_messages(self.open_thread_root)
            thread_msgs = [ThreadMessage(m.sender, m.text) for m in messages]
            panel.refresh_thread_messages(thread_msgs)
        except Exception:
            pass

    # ── Click detection on message log ─────────────────────────────────────

    @on(events.Click, "#messages")
    def _on_message_log_click(self, event: events.Click) -> None:
        """Handle clicks on the message log to detect reply indicator clicks."""
        log = event.widget
        _dbg(f"click y={event.y} widget={event.widget} scroll_y={log.scroll_y if log else '?'}")
        if log is None:
            return

        # Convert click y to virtual line index
        virtual_y = int(event.y + log.scroll_y)
        line_threads = self._rendered_line_threads.get(self.active_buffer, [])
        _dbg(f"  virtual_y={virtual_y} rendered_rows={len(line_threads)} active={self.active_buffer}")
        if line_threads:
            lo = max(0, virtual_y - 2)
            hi = min(len(line_threads), virtual_y + 3)
            _dbg(f"  threads[{lo}:{hi}]={line_threads[lo:hi]}")

        if 0 <= virtual_y < len(line_threads):
            thread_root = line_threads[virtual_y]
            _dbg(f"  thread_root={thread_root!r}")
            if thread_root:
                self._open_thread(thread_root)

    # ── Render active buffer ───────────────────────────────────────────────

    def _render_active_buffer(self) -> None:
        active_name = self._display_name(self.active_buffer)
        topic = self.channel_topics.get(self.active_buffer, "").strip()
        self.title = f"freeq - {active_name}" if not topic else f"freeq - {active_name} | {topic}"
        log = self.query_one("#messages", ScrollableLog)
        width = log.size.width
        log.clear()
        render_lines, render_roots = self._renderable_lines(self.active_buffer, width)
        rendered_threads = self._write_render_lines(
            log,
            render_lines,
            thread_roots=render_roots,
        )
        self._rendered_line_threads[self.active_buffer] = rendered_threads
        _dbg(
            f"render buffer={self.active_buffer} logical={len(self.messages[self.active_buffer])} "
            f"render_lines={len(render_lines)} rendered={len(rendered_threads)} roots={render_roots[:5]}"
        )
        if self._scroll_mode == "end":
            log.scroll_end(animate=False)
        elif self._scroll_mode == "home":
            log.scroll_home(animate=False)
        self._scroll_mode = "preserve"
        if self.active_buffer in self.buffers:
            self.buffers[self.active_buffer].unread = 0
        self._refresh_sidebar()

    def on_resize(self, event: events.Resize) -> None:
        _dbg(f"App.on_resize(size={event.size})")
        del event
        self._refresh_layout_widths()
        self._render_active_buffer()
        if self.open_thread_root:
            self._refresh_thread_panel()

    # ── Event polling ──────────────────────────────────────────────────────

    def _poll_events(self) -> None:
        saw_event = False
        render_active = False
        while True:
            event = self.client.poll_event()
            if event is None:
                break
            saw_event = True
            prev_active = self.active_buffer
            prev_lines = len(self.messages[self.active_buffer])
            prev_topic = self.channel_topics.get(self.active_buffer, "")
            self._handle_event(event)
            if self.active_buffer != prev_active:
                render_active = True
            elif len(self.messages[self.active_buffer]) != prev_lines:
                render_active = True
            elif self.channel_topics.get(self.active_buffer, "") != prev_topic:
                render_active = True
        if saw_event:
            if render_active:
                self._render_active_buffer()
            else:
                self._refresh_sidebar()

    def _poll_auth(self) -> None:
        if self.auth_broker is None or self.pending_auth_session is None:
            return
        result = self.auth_broker.poll_auth_result(self.pending_auth_session)
        if result is None:
            return
        self.pending_auth_session = None
        if "error" in result:
            self._append_status(f"auth failed: {result['error']}", "red")
            self._render_active_buffer()
            return
        token = result.get("token")
        handle = result.get("handle", "?")
        if not token:
            self._append_status("auth failed: broker returned no token", "red")
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
        self._append_status(f"auth ok: reconnecting as {handle}", "green")
        self._render_active_buffer()

    def _begin_auth(self, handle: str) -> None:
        if self.auth_broker is None:
            self._append_status("auth unavailable: set BROKER_SHARED_SECRET", "red")
            self._render_active_buffer()
            return
        login = self.auth_broker.start_login(handle)
        self.pending_auth_session = login["session_id"]
        webbrowser.open(login["url"])
        self._append_status(f"auth: opened browser for {handle} via {self.auth_broker.base_url}", "yellow")
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
            self._append_status(f"auth: cached session for {handle} expired", "yellow")
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
        self._append_status(f"auth restored: {handle}", "green")
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

    # ── Event handling ─────────────────────────────────────────────────────

    def _handle_event(self, event: dict) -> None:
        event_type = event.get("type")
        if event_type == "connected":
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"Connected to {self.client.server_addr}", "bold")
            return
        if event_type == "registered":
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"Registered as {event['nick']}", "bold")
            self._seed_self_avatar_handle()
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
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"nick: {old_nick} -> {new_nick}", "yellow")
            return
        if event_type == "authenticated":
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"authenticated as {event['did']}", "green")
            self._seed_self_avatar_handle()
            return
        if event_type == "whois_reply":
            nick = event.get("nick", "")
            info = event.get("info", "")
            handle = self._parse_whois_handle(info)
            self._pending_whois.discard(self._nick_key(nick))
            if handle:
                _dbg(f"whois handle nick={nick} handle={handle}")
                self._set_avatar_handle(nick, handle)
            return
        if event_type == "auth_failed":
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"auth failed: {event['reason']}", "red")
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
                    self._scroll_mode = "end"
                self._persist_session_channels()
            elif not already_present:
                self._scroll_mode = "end" if self.active_buffer == key else "preserve"
                self._append_line(
                    channel,
                    Text().assemble(
                        Text("+ ", style="green"),
                        self._format_nick(event["nick"]),
                        Text(f" joined {channel}"),
                    ),
                )
            return
        if event_type == "batch_start":
            batch_id = event["id"]
            target = self._display_name(event.get("target") or "status")
            self.batches[batch_id] = BatchState(
                target=target,
                batch_type=event.get("batch_type", ""),
                lines=[],
                thread_roots=[],
                line_metas=[],
            )
            return
        if event_type == "batch_end":
            batch_id = event["id"]
            batch = self.batches.pop(batch_id, None)
            if batch is not None and batch.lines:
                indexed = sorted(enumerate(batch.lines), key=lambda item: item[1][0])
                ordered = [line for _i, (_ts, line) in indexed]
                roots = [batch.thread_roots[i] for i, (_ts, _line) in indexed]
                line_metas = [batch.line_metas[i] for i, (_ts, _line) in indexed]
                self._prepend_lines(batch.target, ordered, thread_roots=roots, line_metas=line_metas)
                if batch.batch_type == "chathistory":
                    self.restore_history_targets.discard(self._buffer_key(batch.target))
                    self.active_buffer = self._buffer_key(batch.target)
                    self._scroll_mode = "home"
            return
        if event_type == "names_end":
            channel = event["channel"]
            key = self._buffer_key(channel)
            if key in self.restore_history_targets:
                self.restore_history_targets.discard(key)
                self.set_timer(0.1, lambda ch=channel: self._request_history(ch))
            return
        if event_type == "parted":
            channel = event["channel"]
            key = self._buffer_key(channel)
            self.channel_members[key].discard(self._nick_key(event["nick"]))
            if event["nick"].casefold() == self.client.nick.casefold():
                if self.active_buffer == key:
                    self.active_buffer = "status"
                    self._scroll_mode = "end"
                self.restore_history_targets.discard(key)
                self._persist_session_channels()
            else:
                self._scroll_mode = "end" if self.active_buffer == key else "preserve"
                self._append_line(
                    channel,
                    Text().assemble(
                        Text("- ", style="yellow"),
                        self._format_nick(event["nick"]),
                        Text(f" left {channel}"),
                    ),
                )
            return
        if event_type == "message":
            target = event["target"]
            sender = event["from"]
            text = event["text"]
            tags = event.get("tags", {})
            self._ensure_avatar_lookup(sender)
            buffer_name = self._message_buffer_name(target, sender)
            buffer_key = self._buffer_key(buffer_name)
            self._record_message(buffer_name, sender, text, tags)
            reply_to = self._thread_reply_to(tags)
            thread_root = ""
            if reply_to:
                parent = self.message_index.get(reply_to)
                if parent:
                    thread_root = parent.thread_root
                else:
                    thread_root = reply_to
            batch_id = tags.get("batch")
            if batch_id and batch_id in self.batches:
                if reply_to and thread_root:
                    parent = self.message_index.get(reply_to)
                    parent_snip = self._snippet(parent.text, 50) if parent else "(original not loaded)"
                    parent_sender = parent.sender if parent else "?"
                    self.batches[batch_id].lines.append(
                        (tags.get("time", ""), self._format_reply_indicator(parent_sender, parent_snip, thread_root))
                    )
                    self.batches[batch_id].thread_roots.append(thread_root)
                    self.batches[batch_id].line_metas.append(None)
                self.batches[batch_id].lines.append(
                    (tags.get("time", ""), self._format_message(sender, text))
                )
                self.batches[batch_id].thread_roots.append(None)
                self.batches[batch_id].line_metas.append((sender, text))
            else:
                self._scroll_mode = "end" if self.active_buffer == buffer_key else "preserve"
                if reply_to and thread_root:
                    parent = self.message_index.get(reply_to)
                    parent_snip = self._snippet(parent.text, 50) if parent else "(original not loaded)"
                    parent_sender = parent.sender if parent else "?"
                    self._append_line(
                        buffer_name,
                        self._format_reply_indicator(parent_sender, parent_snip, thread_root),
                        mark_unread=False,
                        thread_root=thread_root,
                        line_meta=None,
                    )
                self._append_line(
                    buffer_name,
                    self._format_message(sender, text),
                    line_meta=(sender, text),
                )
            return
        if event_type == "topic_changed":
            channel = event["channel"]
            topic = event["topic"]
            set_by = event.get("set_by")
            key = self._ensure_buffer(channel)
            self.channel_topics[key] = topic
            self._scroll_mode = "end" if self.active_buffer == key else "preserve"
            suffix = f" ({set_by})" if set_by else ""
            topic_text = Text()
            topic_text.append("topic: ", style="magenta")
            topic_text.append(topic + suffix)
            self._append_line(channel, topic_text, mark_unread=False)
            return
        if event_type == "server_notice":
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            notice = Text()
            notice.append("notice: ", style="magenta")
            notice.append(event["text"])
            self._append_line("status", notice, mark_unread=False)
            return
        if event_type == "disconnected":
            self.channel_members.clear()
            self.restore_history_targets.clear()
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"disconnected: {event['reason']}", "red")
            return
        self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
        self._append_line("status", self._format_system(str(event), "dim"), mark_unread=False)

    # ── Actions ────────────────────────────────────────────────────────────

    def action_close_thread(self) -> None:
        """Close the open thread panel."""
        if self.open_thread_root:
            self._close_thread()

    def action_open_thread(self, thread_root: str = "") -> None:
        """Open thread panel. Called from /thread command."""
        if thread_root:
            self._open_thread(thread_root)
            return
        self._open_thread_via_command()

    def _open_thread_via_command(self) -> None:
        """Fallback: /thread with no args — find most recent reply indicator."""
        threads = self._line_threads.get(self.active_buffer, [])
        for root in reversed(threads):
            if root:
                self._open_thread(root)
                return

    def _send_reply(self, target: str, reply_to_msgid: str, text: str) -> None:
        """Send a reply using @+draft/reply IRCv3 tag via raw IRC."""
        self.client.raw(f"@+draft/reply={reply_to_msgid} PRIVMSG {target} :{text}")

    # ── Command input (main composer) ──────────────────────────────────────

    @on(Input.Submitted, "#composer")
    def handle_submit(self, event: Input.Submitted) -> None:
        _dbg(f"handle_submit(text={event.value[:30]!r}...)")
        text = event.value.strip()
        event.input.value = ""
        if not text:
            return
        if text.startswith("/"):
            command, _, raw_args = text[1:].partition(" ")
            args = raw_args.strip()
        else:
            command = ""
            args = ""
        if command == "join" and args:
            channel = args
            self.client.join(channel)
            self._ensure_buffer(channel)
            self.active_buffer = self._buffer_key(channel)
            self._scroll_mode = "end"
            self._persist_session_channels()
            self._render_active_buffer()
            return
        if command == "auth" and args:
            self._begin_auth(args)
            return
        if command == "nick" and args:
            self.client.set_nick(args)
            self._append_status(f"changing nick to {args}")
            self._render_active_buffer()
            return
        if command == "raw" and args:
            self.client.raw(args)
            return
        if command == "topic":
            target = self.active_buffer
            if target == "status":
                self._append_status("join a channel before setting topic")
                self._render_active_buffer()
                return
            display_target = self._display_name(target)
            if args:
                self.client.raw(f"TOPIC {display_target} :{args}")
            else:
                self.client.raw(f"TOPIC {display_target}")
            return
        if command == "thread" and args:
            if args in self.threads or args in self.message_index:
                msg = self.message_index.get(args)
                root = msg.thread_root if msg else args
                self._open_thread(root)
            else:
                self._append_status(f"no thread found for msgid {args}")
                self._render_active_buffer()
            return
        if command == "thread":
            self._open_thread_via_command()
            return
        if command == "reply" and args:
            parts = args.split(None, 1)
            if len(parts) < 2:
                self._append_status("usage: /reply <msgid> <text>")
                self._render_active_buffer()
                return
            reply_msgid, reply_text = parts[0], parts[1]
            target = self._display_name(self.active_buffer)
            if self.active_buffer == "status":
                self._append_status("join a channel before replying")
                self._render_active_buffer()
                return
            self._send_reply(target, reply_msgid, reply_text)
            return
        if command:
            self._append_status(f"invalid command: /{command}")
            self._render_active_buffer()
            return
        target = self.active_buffer
        if target == "status":
            self._append_status("join a channel before sending messages")
            self._render_active_buffer()
            return
        self.client.send_message(self._display_name(target), text)

    # ── Sidebar ────────────────────────────────────────────────────────────

    @on(ListView.Selected, "#sidebar")
    def handle_sidebar_select(self, event: ListView.Selected) -> None:
        _dbg(f"handle_sidebar_select(item={event.item.name!r})")
        if event.item.name is None:
            return
        self.active_buffer = self._buffer_key(event.item.name)
        self.open_thread_root = ""
        
        # Swap back to MessagesPanel if thread panel was open
        if self._thread_panel_is_open():
            self._close_thread()
        
        self._scroll_mode = "end"
        self._render_active_buffer()
        self.query_one("#composer", Input).focus()

    def _session_channels(self) -> list[str]:
        return sorted(
            b.name
            for key, b in self.buffers.items()
            if key != "status" and (b.name.startswith("#") or b.name.startswith("&"))
        )

    def on_unmount(self) -> None:
        _dbg("App.on_unmount()")
        self._persist_session_channels()
