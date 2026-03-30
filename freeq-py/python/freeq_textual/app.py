from __future__ import annotations

import logging
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

# Setup logger
logger = logging.getLogger("freeq")
logger.setLevel(logging.DEBUG)
if not logger.handlers:
    handler = logging.FileHandler("/tmp/freeq.log", mode='w')
    handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter('%(asctime)s %(levelname).1s %(name)s: %(message)s', datefmt='%H:%M:%S')
    handler.setFormatter(formatter)
    logger.addHandler(handler)

from rich.text import Text
from textual import events, on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.css.query import NoMatches
from textual.reactive import reactive
from textual.widgets import Button, Footer, Header, Input, ListItem, ListView, Static

from .client import BrokerAuthFlow, FreeqAuthBroker, FreeqClient
from .widgets import BufferList, InlineSpinner, LoadingOverlay, MessagesPanel, MessagesPanelWithThread, ScrollableLog, ThreadMessage, ThreadPanel
from .components import get_component
from .components.all import *  # noqa: F401 - registers all widgets as friends!

# Get swappable components from registry - WE'RE ALL FRIENDS HERE!
# DO NOT import directly - use registry so everyone can be swapped
ReplyPanel = get_component('reply_panel')
ContextMenu = get_component('context_menu')
EmojiPicker = get_component('emoji_picker')
ThreadPanel = get_component('thread_panel')
BufferList = get_component('buffer_list')
ScrollableLog = get_component('scrollable_log')
MessagesPanel = get_component('messages_panel')
MessagesPanelWithThread = get_component('messages_panel_with_thread')
LoadingOverlay = get_component('loading_overlay')
InlineSpinner = get_component('inline_spinner')
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
    msgids: list[str | None]
    line_metas: list[tuple[str, str, str] | None]  # (sender, text, timestamp) or None


@dataclass(slots=True)
class MessageState:
    buffer_key: str
    sender: str
    text: str
    thread_root: str
    msgid: str = ""
    reply_to: str = ""
    is_reply: bool = False
    timestamp: str = ""


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

    def __init__(self, client: FreeqClient, **kwargs) -> None:
        # Extract known kwargs before super().__init__
        self.initial_channel = kwargs.pop("initial_channel", None)
        self.auth_broker = kwargs.pop("auth_broker", None)
        self.auth_handle = kwargs.pop("auth_handle", None)
        self.session_path = kwargs.pop("session_path", None)
        self.cached_auth = kwargs.pop("cached_auth", None)
        self.config_path = kwargs.pop("config_path", None)
        self.ui_config = kwargs.pop("ui_config", {}) or {}
        
        super().__init__(**kwargs)
        self.client = client
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
        self._history_loading: set[str] = set()  # Channels currently loading history (prevent duplicates)
        self._history_exhausted: set[str] = set()  # Channels where we've hit the end of history
        self._scroll_mode = "preserve"
        self._scroll_target_msgid = ""
        self._theme_ready = False
        self._avatars_enabled = False
        # Maps buffer_key -> list of (thread_root | None) per logical appended line
        self._line_threads: dict[str, list[str | None]] = defaultdict(list)
        # Maps buffer_key -> list of (sender, raw_text, timestamp) for normal messages, else None
        self._line_message_meta: dict[str, list[tuple[str, str, str] | None]] = defaultdict(list)
        # Maps buffer_key -> list of msgid per logical line (for scroll-to-message)
        self._line_msgids: dict[str, list[str | None]] = defaultdict(list)
        # Maps buffer_key -> list of (thread_root | None) per rendered RichLog row
        self._rendered_line_threads: dict[str, list[str | None]] = defaultdict(list)
        # Maps buffer_key -> list of msgid per rendered RichLog row (for scroll-to-message)
        self._rendered_line_msgids: dict[str, list[str | None]] = defaultdict(list)
        self._nick_handles: dict[str, str] = {}
        self._avatar_palettes: dict[str, list[str]] = {}
        self._avatar_images: dict[str, object] = {}
        self._avatar_rows: dict[str, list[list[str]]] = {}
        self._pending_whois: set[str] = set()
        self._pending_avatar_fetches: set[str] = set()
        self._avatar_updates: SimpleQueue[tuple[str, list[str] | None, object | None]] = SimpleQueue()
        self._is_loading = True  # Loading state - shows spinner until data loaded
        self._load_message = "Connecting..."
        self._connected = False  # Track if we've received connected event
        self._history_loading_key: str | None = None  # Buffer key currently loading history
        self._reply_to_msgid: str | None = None  # Target msgid for next message (set by ReplyPanel)

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            yield BufferList(id="sidebar")
            yield MessagesPanel()
        yield Input(
            placeholder="Type a message or /join /channel",
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
        
        # Mount loading overlay only in non-headless mode (component lifecycle, not CSS toggle)
        if not self.is_headless:
            overlay = LoadingOverlay(self._load_message, id="loading-overlay")
            self.mount(overlay)
        
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

    def _check_loading_complete(self) -> None:
        """Check if initial loading is complete and remove loading overlay."""
        if not self._is_loading:
            return
        
        # Done when connected and no pending history loads
        if self._connected and not self.restore_history_targets:
            self._is_loading = False
            _dbg("Loading complete - removing overlay")
            overlay = self.query_one("#loading-overlay", LoadingOverlay)
            overlay.remove()

    def _update_loading_message(self, message: str) -> None:
        """Update the loading overlay message."""
        if not self._is_loading:
            return
        if self.is_headless:
            return  # No overlay in headless mode
        self._load_message = message
        overlay = self.query_one("#loading-overlay", LoadingOverlay)
        overlay.message = message  # Reactive property updates display

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
                # First line goes on same line as nick (no indent, it's after nick)
                parts.append(self._format_message_body(lines[0].plain.lstrip()))
                result = Text().assemble(*parts)
                # Continuation lines need indent + URL processing
                for cont_line in lines[1:]:
                    result.append(Text("\n"))
                    # cont_line has indent baked in, preserve it
                    indented = Text(" " * indent) + self._format_message_body(cont_line.plain.lstrip())
                    result.append(indented)
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
                    # Each line needs no_wrap=False + overflow="fold" so single long words wrap
                    lines.append(Text(" " * indent + current, no_wrap=False, overflow="fold"))
                current = word
        if current:
            lines.append(Text(" " * indent + current, no_wrap=False, overflow="fold"))
        return lines

    def _format_chat_block(self, sender: str, text: str, width: int = 80, reply_indicator: Text | None = None, reply_thread_root: str | None = None, timestamp: str = "") -> tuple[list[Text], list[str | None]]:
        """Return tuple of (lines, thread_roots) for a chat message.
        
        With avatars:
        - Line 1: ████ nick HH:MMpm MM/DD
        - Line 2: ████ reply indicator (if any) OR first line of message
        - Line 3+:      continuation (same column as line 2 text)
        
        Without avatars:
        - reply indicator (if any)
        - nick HH:MMpm MM/DD: message on one line with fold overflow
        """
        name = Text(sender, style=f"bold {_nick_color(sender)}")
        roots: list[str | None] = []
        
        # Format timestamp as 12hr with date (e.g., "2:30pm 1/15")
        time_str = self._format_timestamp(timestamp)
        time_text = Text(f" {time_str}", style="dim") if time_str else Text()
        
        if not self._avatars_enabled:
            # No avatar: reply indicator, then nick timestamp: message on one line
            result: list[Text] = []
            if reply_indicator:
                result.append(reply_indicator)
                roots.append(reply_thread_root)
            block = Text(no_wrap=False, overflow="fold")
            block.append_text(name)
            block.append_text(time_text)
            block.append(": ")
            block.append_text(self._format_message_body(text))
            result.append(block)
            # Message line also gets thread_root if it's a reply (larger click target)
            roots.append(reply_thread_root)
            return result, roots
        
        
        # With avatars: nick on line 1, reply indicator or message on line 2
        rows = self._avatar_rows_for_nick(sender)
        indent = "     "  # 5 spaces - aligns with where text starts after "████ "
        text_avail = max(20, width - 5)
        
        # Line 1: avatar row 1 + nick + timestamp
        line1 = Text()
        for color in rows[0]:
            line1.append("\u2588", style=color)
        line1.append(" ")
        line1.append_text(name)
        line1.append_text(time_text)
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
                        cont = Text(indent, no_wrap=False, overflow="fold")
                        cont.append_text(self._format_message_body(current))
                        lines.append(cont)
                    # Message line gets thread_root for replies (larger click target)
                    roots.append(reply_thread_root)
                current = word
                line_num += 1
        
        
        # Flush remaining text
        if current:
            if line_num == 0 and not reply_indicator:
                lines.append(self._make_avatar_text_line(rows[1], self._format_message_body(current)))
            else:
                cont = Text(indent, no_wrap=False, overflow="fold")
                cont.append_text(self._format_message_body(current))
                lines.append(cont)
            # Message line gets thread_root for replies (larger click target)
            roots.append(reply_thread_root)
        
        
        # Ensure at least 2 lines for avatar display
        if len(lines) == 1:
            lines.append(self._make_avatar_text_line(rows[1], Text()))
            roots.append(None)
        
        
        return lines, roots

    def _make_avatar_text_line(self, colors: list[str], text: Text) -> Text:
        """Create line with avatar row 2 + formatted text."""
        line = Text(no_wrap=False, overflow="fold")
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
        msgids: list[str | None] | None = None,
    ) -> tuple[list[str | None], list[str | None]]:
        """Write lines to log, tracking thread_roots and msgids per rendered line.
        
        DESIGN: thread_root is passed to log.write() so the COMPONENT tracks it.
        This ensures thread_roots are correct even when width changes (thread panel opens).
        
        Returns tuple of (rendered_thread_roots, rendered_msgids) for backwards compatibility.
        NOTE: These returned lists may be INACCURATE after deferred renders - use
        log.thread_root_at() instead for click detection.
        """
        rendered_threads: list[str | None] = []
        rendered_msgids_result: list[str | None] = []
        roots = thread_roots or [None] * len(lines)
        mids = msgids or [None] * len(lines)
        width = log.size.width
        for line, thread_root, msgid in zip(lines, roots, mids):
            before = len(log.lines)
            # Pass location and thread_root to the component - IT tracks them
            location = msgid if msgid else None
            log.write(line, width=width, scroll_end=False, location=location or "", thread_root=thread_root)
            added = max(1, len(log.lines) - before)
            rendered_threads.extend([thread_root] * added)
            rendered_msgids_result.extend([msgid] * added)
        
        _dbg(f"_write_render_lines: wrote {len(lines)} lines, {len(rendered_msgids_result)} rendered")
        return rendered_threads, rendered_msgids_result

    # ── Helpers ─────────────────────────────────────────────────────────────

    def _start_client(self) -> None:
        self.client.connect()
        if self.initial_channel:
            self.client.join(self.initial_channel)

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
        msgid: str = "",
        line_meta: tuple[str, str, str] | None = None,
    ) -> None:
        key = self._ensure_buffer(buffer_name)
        if key != self.active_buffer and mark_unread:
            self.buffers[key].unread += 1
        self.messages[key].append(rich)
        self._line_threads[key].append(thread_root or None)
        self._line_msgids[key].append(msgid or None)
        self._line_message_meta[key].append(line_meta)

    def _prepend_lines(
        self,
        buffer_name: str,
        lines: list[Text],
        *,
        thread_roots: list[str | None] | None = None,
        msgids: list[str | None] | None = None,
        line_metas: list[tuple[str, str, str] | None] | None = None,
    ) -> None:
        key = self._ensure_buffer(buffer_name)
        self.messages[key] = list(lines) + self.messages[key]
        roots = thread_roots or [None] * len(lines)
        self._line_threads[key] = list(roots) + self._line_threads[key]
        mids = msgids or [None] * len(lines)
        self._line_msgids[key] = list(mids) + self._line_msgids[key]
        metas = line_metas or [None] * len(lines)
        self._line_message_meta[key] = list(metas) + self._line_message_meta[key]

    def _renderable_lines(self, buffer_key: str, width: int = 80) -> tuple[list[object], list[str | None], list[str | None]]:
        """Return tuple of (lines, thread_roots, msgids) for rendering."""
        renderable: list[object] = []
        render_roots: list[str | None] = []
        render_msgids: list[str | None] = []
        lines = self.messages[buffer_key]
        metas = self._line_message_meta[buffer_key]
        roots = self._line_threads[buffer_key]
        msgids = self._line_msgids[buffer_key]
        previous_sender: str | None = None
        previous_was_chat = False
        pending_reply_indicators: list[tuple[Text, str | None, str | None]] = []  # (line, thread_root, msgid)

        for index, (line, line_meta, thread_root, msgid) in enumerate(zip(lines, metas, roots, msgids)):
            if line_meta is None:
                if self._is_reply_indicator(line):
                    pending_reply_indicators.append((line, thread_root, msgid))
                    continue
                for pending_line, pending_root, pending_msgid in pending_reply_indicators:
                    renderable.append(pending_line)
                    render_roots.append(pending_root)
                    render_msgids.append(pending_msgid)
                pending_reply_indicators.clear()
                renderable.append(line)
                render_roots.append(thread_root)
                render_msgids.append(msgid)
                next_meta = metas[index + 1] if index + 1 < len(metas) else None
                if next_meta is None:
                    renderable.append(Text(" "))
                    render_roots.append(None)
                    render_msgids.append(None)
                previous_sender = None
                previous_was_chat = False
                continue

            sender, text, timestamp = line_meta
            sender_key = self._nick_key(sender)
            is_first = not previous_was_chat or previous_sender != sender_key
            if is_first:
                # Get reply indicator (first pending) to embed in chat block
                reply_ind = pending_reply_indicators[0][0] if pending_reply_indicators else None
                reply_root = pending_reply_indicators[0][1] if pending_reply_indicators else None
                pending_reply_indicators.clear()
                block_lines, block_roots = self._format_chat_block(sender, text, width, reply_indicator=reply_ind, reply_thread_root=reply_root, timestamp=timestamp)
                for block_line, block_root in zip(block_lines, block_roots):
                    renderable.append(block_line)
                    render_roots.append(block_root)
                    render_msgids.append(msgid)  # All lines of same message share msgid
            else:
                # Continuation of same sender - just message body, indented
                # Reply indicators already handled by first message
                pending_reply_indicators.clear()
                indent = 5 if self._avatars_enabled else 0
                for msg_line in self._format_message_lines(text, indent, width):
                    renderable.append(msg_line)
                    render_roots.append(None)
                    render_msgids.append(msgid)

            next_meta = metas[index + 1] if index + 1 < len(metas) else None
            next_sender = self._nick_key(next_meta[0]) if next_meta is not None else None
            if next_meta is None or next_sender != sender_key:
                renderable.append(Text(" "))
                render_roots.append(None)
                render_msgids.append(None)

            previous_sender = sender_key
            previous_was_chat = True

        for pending_line, pending_root, pending_msgid in pending_reply_indicators:
            renderable.append(pending_line)
            render_roots.append(pending_root)
            render_msgids.append(pending_msgid)

        return renderable, render_roots, render_msgids

    def _request_history(self, channel: str) -> None:
        """Request older history for a channel.
        
        Called when:
        - Initial join (via names_end -> restore_history_targets)
        - User scrolls to top (via _request_history_from_scroll)
        
        We use CHATHISTORY BEFORE with the timestamp of our oldest message.
        Server responds with a batch of messages older than that timestamp.
        
        If we have no messages yet, use CHATHISTORY LATEST to get recent messages.
        """
        key = self._buffer_key(channel)
        msgids = self._line_msgids.get(key, [])
        
        # Find the first (oldest) non-None msgid and its timestamp
        # _line_msgids is ordered oldest -> newest (prepend adds to front)
        oldest_msgid = None
        oldest_timestamp = None
        for mid in msgids:
            if mid:
                oldest_msgid = mid
                msg_state = self.message_index.get(mid)
                if msg_state:
                    oldest_timestamp = msg_state.timestamp
                break
        
        display_name = self._display_name(channel)
        
        if oldest_timestamp:
            # Server expects: CHATHISTORY BEFORE #channel timestamp=2024-01-15T14:30:00.000Z 50
            # Returns messages older than the timestamp
            logger.info(f"HISTORY BEFORE {display_name} {oldest_timestamp}")
            self.client.raw(f"CHATHISTORY BEFORE {display_name} timestamp={oldest_timestamp} 50")
        else:
            # No messages yet - get the most recent ones
            logger.info(f"HISTORY LATEST {display_name}")
            self.client.history_latest(display_name, 50)

    def _format_timestamp(self, timestamp: str) -> str:
        """Format IRCv3 server-time as 12hr with date in local timezone.
        
        IRCv3 time format: '2024-01-15T14:30:00.000Z' (ISO 8601, UTC)
        """
        if not timestamp:
            return ""
        import datetime
        # Parse ISO 8601 timestamp (UTC)
        if '.' in timestamp:
            dt = datetime.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
        else:
            dt = datetime.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
        # Convert to local timezone
        local_dt = dt.astimezone()
        # Format as 12hr with date: "2:30pm 1/15"
        hour = local_dt.hour % 12 or 12
        minute = local_dt.minute
        ampm = 'am' if local_dt.hour < 12 else 'pm'
        month = local_dt.month
        day = local_dt.day
        return f"{hour}:{minute:02d}{ampm} {month}/{day}"

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
            palette, avatar_image = self._fetch_bluesky_avatar_data(handle)
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
            self._render_active_buffer()

    # ── Message recording ──────────────────────────────────────────────────

    def _record_message(self, buffer_name: str, sender: str, text: str, tags: dict) -> None:
        buffer_key = self._ensure_buffer(buffer_name)
        msgid = tags.get("msgid", "")
        reply_to = self._thread_reply_to(tags) or ""
        thread_root = msgid or reply_to or ""
        is_reply = bool(reply_to)
        timestamp = tags.get("time", "")

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
                timestamp=timestamp,
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
        return bool(self.query(MessagesPanelWithThread))

    def _open_thread(self, thread_root: str) -> None:
        """Open the thread panel - swap to MessagesPanelWithThread.
        
        Fails hard if:
        - thread_root is empty
        - no existing panel to remove (shouldn't happen)
        - panel swap fails
        """
        if not thread_root:
            raise ValueError("_open_thread: empty thread_root")
        
        _dbg(f"_open_thread({thread_root[:8]!r}) current open_thread_root={self.open_thread_root[:8] if self.open_thread_root else 'empty'}")
        
        # If same thread is already open, just scroll to it
        if self.open_thread_root == thread_root:
            _dbg(f"  same thread already open, scrolling")
            self._scroll_mode = "message"
            self._scroll_target_msgid = thread_root
            return
        
        
        self.open_thread_root = thread_root
        
        # Collect messages
        messages = self._collect_thread_messages(thread_root)
        _dbg(f"  collected {len(messages)} messages")
        thread_msgs = [ThreadMessage(m.sender, m.text) for m in messages]
        
        # Find and remove existing panel - exactly one must exist
        body = self.query_one("#body", Horizontal)
        
        # Find the existing panel - should be exactly one
        panels = list(self.query(MessagesPanel)) + list(self.query(MessagesPanelWithThread))
        if len(panels) != 1:
            raise RuntimeError(f"Expected 1 panel, found {len(panels)} - corrupt state")
        
        old_panel = panels[0]
        _dbg(f"  removing {type(old_panel).__name__}")
        old_panel.remove()
        _dbg(f"  removed old panel")
        
        # Mount new panel after removal completes (remove is async)
        def mount_new():
            new_panel = MessagesPanelWithThread(
                thread_root, thread_msgs, self._format_thread_message
            )
            body.mount(new_panel)
            _dbg(f"  mounted MessagesPanelWithThread")
            # Set scroll mode for when the scheduled render happens
            self._scroll_mode = "message"
            self._scroll_target_msgid = thread_root
        
        self.call_later(mount_new)

    def _close_thread(self) -> None:
        """Close the thread panel - swap back to MessagesPanel.
        
        Fails hard if:
        - No MessagesPanelWithThread to remove (shouldn't happen)
        """
        _dbg(f"_close_thread() open_thread_root was {self.open_thread_root[:8] if self.open_thread_root else 'empty'}")
        
        if not self.open_thread_root:
            raise RuntimeError("_close_thread called with no thread open")
        
        self.open_thread_root = ""
        
        # Remove MessagesPanelWithThread - must exist
        body = self.query_one("#body", Horizontal)
        old = self.query_one(MessagesPanelWithThread)
        _dbg(f"_close_thread: removing MessagesPanelWithThread")
        old.remove()
        
        # Mount new panel after removal completes (remove is async)
        def mount_new():
            new_panel = MessagesPanel()
            body.mount(new_panel)
            _dbg(f"_close_thread: mounted new MessagesPanel")
            self.query_one("#composer", Input).focus()
        
        self.call_later(mount_new)

    @on(ThreadPanel.Closed)
    def handle_thread_panel_closed(self, event: ThreadPanel.Closed) -> None:
        """Handle thread panel closed event - swap back to MessagesPanel.
        
        Fails hard if no MessagesPanelWithThread exists.
        """
        del event
        _dbg(f"handle_thread_panel_closed() open_thread_root={self.open_thread_root[:8] if self.open_thread_root else 'empty'}")
        
        if not self.open_thread_root:
            raise RuntimeError("handle_thread_panel_closed called with no thread open")
        
        self.open_thread_root = ""
        
        # Remove MessagesPanelWithThread - must exist
        body = self.query_one("#body", Horizontal)
        old = self.query_one(MessagesPanelWithThread)
        old.remove()
        
        # Mount new panel after removal completes (remove is async)
        def mount_new():
            new_panel = MessagesPanel()
            body.mount(new_panel)
            self.query_one("#composer", Input).focus()
        
        
        self.call_later(mount_new)

    @on(ThreadPanel.ReplySent)
    def handle_thread_panel_reply(self, event: ThreadPanel.ReplySent) -> None:
        """Handle reply sent from thread panel."""
        _dbg(f"handle_thread_panel_reply(root={event.thread_root[:8]!r}, text={event.text[:20]!r}...)")
        target = self._display_name(self.active_buffer)
        if self.active_buffer == "status":
            return
        self._send_reply(target, event.thread_root, event.text)
    
    # NOTE: DO NOT REMOVE ReplyPanel handler. User wants this feature.
    # If it's broken, fix it. Don't just delete it.
    @on(ReplyPanel.ReplySent)
    def handle_reply_panel_reply(self, event: ReplyPanel.ReplySent) -> None:
        """Handle reply sent from reply panel."""
        _dbg(f"handle_reply_panel_reply(msgid={event.reply_to_msgid[:8]!r}, text={event.text[:20]!r}...)")
        self._send_reply(event.target, event.reply_to_msgid, event.text)

    def _refresh_thread_panel(self) -> None:
        """Refresh the thread panel with current messages.
        
        Fails hard if thread panel not found when open_thread_root is set.
        """
        if not self.open_thread_root:
            return
        panel = self.query_one(MessagesPanelWithThread)
        messages = self._collect_thread_messages(self.open_thread_root)
        thread_msgs = [ThreadMessage(m.sender, m.text) for m in messages]
        panel.refresh_thread_messages(thread_msgs)

    # ── Click detection on message log ─────────────────────────────────────

    @on(ScrollableLog.Clicked)
    def _on_scrollable_log_clicked(self, event: ScrollableLog.Clicked) -> None:
        """Handle clicks from ScrollableLog widget.
        
        DESIGN: Use the message sender directly - never query by ID.
        The event sender IS the ScrollableLog that was clicked.
        """
        # Get the ScrollableLog that emitted this event
        log = event.sender
        if not isinstance(log, ScrollableLog):
            return
        
        virtual_y = int(event.y + event.scroll_y)
        
        # Get thread_root from the COMPONENT, not from app dict
        thread_root = log.thread_root_at(virtual_y)
        
        # Show what's rendered at clicked line
        line_text = "?"
        if hasattr(log, 'lines') and 0 <= virtual_y < len(log.lines):
            line_text = str(log.lines[virtual_y])[:80]
        
        _dbg(f"ScrollableLog.Clicked: y={event.y} scroll_y={event.scroll_y} virtual_y={virtual_y}")
        _dbg(f"  line[{virtual_y}] = {line_text}")
        _dbg(f"  thread_root = {thread_root[:8] if thread_root else None}")
        # Show nearby lines with thread_roots (from component)
        for i in range(max(0, virtual_y-3), min(len(log._thread_roots), virtual_y+4)):
            root = log._thread_roots[i] if i < len(log._thread_roots) else None
            _dbg(f"    [{i}] root={root[:8] if root else None!r}")
        
        _dbg(f"ScrollableLog.Clicked: y={event.y} virtual_y={virtual_y} thread_root={thread_root[:8] if thread_root else 'None'}")
        if thread_root:
            _dbg(f"  opening thread: {thread_root[:8]}")
            _dbg(f"  OPENING THREAD: {thread_root[:8]}")
            self._open_thread(thread_root)
        else:
            _dbg(f"  no thread at virtual_y={virtual_y}")

    @on(ScrollableLog.ScrolledToTop)
    def _on_scrolled_to_top(self, event: ScrollableLog.ScrolledToTop) -> None:
        """Load more history when scrolled to top."""
        import sys
        sys.stderr.write(f"APP: ScrolledToTop received! active_buffer={self.active_buffer}\n")
        sys.stderr.flush()
        _dbg(f"ScrolledToTop received: active_buffer={self.active_buffer}")
        self._request_history_from_scroll()

    def _request_history_from_scroll(self) -> None:
        """Called when user scrolls to top - request older history.
        
        This is triggered by:
        1. watch_scroll_y crossing below threshold (<5) from above
        2. on_mouse_scroll_up when already at top (scroll_y < 5)
        
        We request CHATHISTORY BEFORE with the oldest timestamp we have.
        Server responds with a batch of older messages.
        """
        if self.active_buffer == "status":
            return
        key = self._buffer_key(self.active_buffer)
        if key in self._history_loading:
            return
        if key in self._history_exhausted:
            _dbg(f"History exhausted for {key}, skipping load")
            return
        self._history_loading.add(key)
        self._history_loading_key = key
        # Remove any existing spinner from previous scroll request
        # (user might scroll multiple times before batch arrives)
        for old in self.query(InlineSpinner):
            old.remove()
        # Mount inline spinner at top of messages panel (no fixed ID)
        body = self.query_one("#body")
        spinner = InlineSpinner("Loading older messages...")
        body.mount(spinner)
        self._request_history(self.active_buffer)

    def on_click(self, event: events.Click) -> None:
        """Catch ALL clicks at app level - close context menu and emoji picker."""
        widget_id = getattr(event.widget, 'id', '?')
        widget_class = type(event.widget).__name__
        
        # Log all clicks
        _dbg(f"CLICK: {widget_class}(id={widget_id}) button={event.button} x={event.x} y={event.y}")
        
        # Only close menus/pickers if clicking OUTSIDE of #messages
        # (Clicks on #messages are handled by _on_message_log_click which may open a menu)
        if widget_id != 'messages':
            for menu in self.query(ContextMenu):
                menu.remove()
            for picker in self.query(EmojiPicker):
                picker.remove()

    @on(events.Click, "#messages")
    def _on_message_log_click(self, event: events.Click) -> None:
        """Handle clicks on the message log to detect reply indicator clicks."""
        # events.Click has widget attribute (set in constructor)
        log = event.widget
        _dbg(f"click y={event.y} button={event.button} widget={event.widget} scroll_y={log.scroll_y if log else '?'}")
        if log is None:
            return
        
        # Right click: ignored (usually intercepted by terminal for paste)
        if event.button == 3:
            return
        
        # Left click: check for thread indicator first, then show context menu
        virtual_y = int(event.y + log.scroll_y)
        line_threads = self._rendered_line_threads.get(self.active_buffer, [])
        
        # If clicked on a thread indicator, open thread
        if 0 <= virtual_y < len(line_threads) and line_threads[virtual_y]:
            thread_root = line_threads[virtual_y]
            _dbg(f"  thread_root={thread_root[:8] if thread_root else None!r}")
            self._open_thread(thread_root)
            return
        
        # Otherwise, show context menu
        _dbg(f"  no thread indicator, showing context menu")
        if event.button == 1:
            self._show_context_menu(event, log)
    
    def _show_context_menu(self, event: events.Click, log) -> None:
        """Show context menu at click position."""
        _dbg(f"_show_context_menu: x={event.x} y={event.y} screen_x={event.screen_x} screen_y={event.screen_y}")
        
        # Close any existing menu
        for menu in self.query(ContextMenu):
            menu.remove()
        
        # Find which message is under cursor
        virtual_y = int(event.y + log.scroll_y)
        msgid = self._get_msgid_at_line(virtual_y)
        
        # Create menu
        menu = ContextMenu(
            actions=[
                ("Reply", self._on_menu_reply),
                ("React", self._on_menu_react),
            ],
            msgid=msgid,
        )
        # Mount to screen, dock to top
        self.screen.mount(menu)
        _dbg(f"  mounted ContextMenu msgid={msgid}")
    
    def _get_msgid_at_line(self, virtual_y: int) -> str | None:
        """Get the message ID at a given line index."""
        # Look up in message_locations: location -> msgid
        # Line indices correspond to locations like "line:0", "line:1", etc.
        location = f"line:{virtual_y}"
        # But we need to find which message this line belongs to
        # Check line_msgids if available
        if hasattr(self, '_rendered_line_msgids'):
            line_msgids = self._rendered_line_msgids.get(self.active_buffer, [])
            if 0 <= virtual_y < len(line_msgids):
                return line_msgids[virtual_y]
        return None
    
    def _on_menu_reply(self, msgid: str | None) -> None:
        """Handle Reply from context menu - show reply panel."""
        _dbg(f"Context menu Reply: msgid={msgid}")
        _dbg(f"_on_menu_reply called: msgid={msgid}")
        
        if not msgid:
            return
        
        # Close any existing reply panel
        for panel in self.query(ReplyPanel):
            panel.remove()
        
        # Get message context
        msg = self.message_index.get(msgid)
        if not msg:
            _dbg(f"  msgid {msgid} not found in index")
            return
        
        # Store reply target for composer
        self._reply_to_msgid = msgid
        
        # Create and mount reply panel as overlay
        panel = ReplyPanel(
            reply_to_msgid=msgid,
            context=msg.text,
            sender=msg.sender,
            target=self._display_name(self.active_buffer),
        )
        # Mount to screen as overlay, positioned right
        self.screen.mount(panel)
        _dbg(f"  mounted ReplyPanel for {msgid[:8]}")
    
    def _on_menu_react(self, msgid: str | None) -> None:
        """Handle React from context menu - show emoji picker."""
        _dbg(f"Context menu React: msgid={msgid}")
        if not msgid:
            return
        
        # Close any existing emoji picker
        for picker in self.query(EmojiPicker):
            picker.remove()
        
        # Create and mount emoji picker
        picker = EmojiPicker(msgid=msgid)
        self.screen.mount(picker)
        _dbg(f"  mounted EmojiPicker for {msgid[:8]}")
    
    @on(EmojiPicker.EmojiSelected)
    def handle_emoji_selected(self, event: EmojiPicker.EmojiSelected) -> None:
        """Handle emoji selection - send reaction."""
        _dbg(f"Emoji selected: {event.emoji} for msgid={event.msgid[:8] if event.msgid else None}")
        if event.msgid:
            # Send reaction via IRC
            self.client.raw(f"REACT {event.msgid} {event.emoji}")

    # ── Render active buffer ───────────────────────────────────────────────

    def _render_active_buffer(self) -> None:
        """Render the active buffer's messages to the RichLog.
        
        This is called when:
        - New message arrives (live)
        - Switching channels
        - Batch history arrives (prepend)
        - Thread panel opens/closes
        
        Flow:
        1. Update window title with channel name and topic
        2. Clear the RichLog widget
        3. Get renderable lines from _renderable_lines (formats grouping, etc)
        4. Write lines to RichLog, tracking thread roots and msgids per row
        5. Scroll to appropriate position (end/home/message/preserve)
        """
        active_name = self._display_name(self.active_buffer)
        topic = self.channel_topics.get(self.active_buffer, "").strip()
        self.title = f"freeq - {active_name}" if not topic else f"freeq - {active_name} | {topic}"
        log = self.query_one("#messages", ScrollableLog)
        width = log.size.width
        log.clear()
        render_lines, render_roots, render_msgids = self._renderable_lines(self.active_buffer, width)
        rendered_threads, rendered_msgids = self._write_render_lines(
            log,
            render_lines,
            thread_roots=render_roots,
            msgids=render_msgids,
        )
        self._rendered_line_threads[self.active_buffer] = rendered_threads
        self._rendered_line_msgids[self.active_buffer] = rendered_msgids
        
        # Debug: count how many lines have thread_roots
        thread_lines = sum(1 for t in rendered_threads if t is not None)
        _dbg(
            f"render buffer={self.active_buffer} logical={len(self.messages[self.active_buffer])} "
            f"render_lines={len(render_lines)} rendered={len(rendered_threads)} "
            f"thread_lines={thread_lines} roots_sample={render_roots[:5]}"
        )
        # Handle scroll positioning
        # - end: new live message, scroll to bottom
        # - home: history loaded, scroll to top to show new old messages
        # - message: open thread, scroll to the thread root message
        # - preserve: switch channel, keep current scroll position
        if self._scroll_mode == "end":
            log.scroll_end(animate=False)
        elif self._scroll_mode == "home":
            log.scroll_home(animate=False)
        elif self._scroll_mode == "message":
            # Scroll to a specific message (used when opening thread)
            _dbg(f"scroll mode=message, target={self._scroll_target_msgid[:8] if self._scroll_target_msgid else 'empty'}")
            if self._scroll_target_msgid:
                # Use call_later to ensure lines are rendered before scrolling
                # (RichLog defers rendering until size is known)
                target = self._scroll_target_msgid
                self._scroll_target_msgid = ""
                self.call_later(lambda: self._scroll_to_message(target))
        # else: preserve - do nothing, keep current scroll

    def _scroll_to_message(self, msgid: str) -> None:
        """Scroll to a specific message after rendering is complete."""
        log = self.query_one("#messages", ScrollableLog)
        success = log.scroll_to_location(msgid)
        _dbg(f"_scroll_to_message({msgid[:8]}): result={success}, lines={len(log.lines)}, virtual_size={log.virtual_size}")
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
            self._connected = True
            self._scroll_mode = "end" if self.active_buffer == "status" else "preserve"
            self._append_status(f"Connected to {self.client.server_addr}", "bold")
            self._update_loading_message("Loading channels...")
            self._check_loading_complete()
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
                self._refresh_sidebar()  # Show new channel in sidebar
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
                msgids=[],
                line_metas=[],
            )
            return
        if event_type == "batch_end":
            # Server finished sending a batch of messages.
            # Batch types: 'chathistory' (history replay), 'labeled-response' (command response)
            batch_id = event["id"]
            batch = self.batches.pop(batch_id, None)
            if batch is None:
                # Orphan batch_end without matching batch_start - ignore
                logger.error(f"BATCH END {batch_id}: no matching batch_start")
                return
            
            if not batch.lines:
                # Empty batch - server sent no messages (end of history or no matching messages)
                # Still need to clean up loading state
                if batch.batch_type == "chathistory":
                    key = self._buffer_key(batch.target)
                    self.restore_history_targets.discard(key)
                    self._history_loading.discard(key)
                    self._history_exhausted.add(key)  # No more history for this buffer!
                    _dbg(f"History exhausted for {key}")
                    # Remove spinner
                    for spinner in self.query(InlineSpinner):
                        spinner.remove()
                    self._check_loading_complete()
                return
            
            logger.info(f"BATCH END {batch_id}: {len(batch.lines)} lines for {batch.target}")
            
            # Sort lines by timestamp (oldest first)
            # batch.lines is list of (timestamp, Text) tuples
            indexed = sorted(enumerate(batch.lines), key=lambda item: item[1][0])
            ordered = [line for _i, (_ts, line) in indexed]
            roots = [batch.thread_roots[i] for i, (_ts, _line) in indexed]
            mids = [batch.msgids[i] for i, (_ts, _line) in indexed]
            line_metas = [batch.line_metas[i] for i, (_ts, _line) in indexed]
            
            # Prepend lines to in-memory message list
            # This updates: self.messages, _line_threads, _line_msgids, _line_message_meta
            self._prepend_lines(batch.target, ordered, thread_roots=roots, msgids=mids, line_metas=line_metas)
            
            if batch.batch_type == "chathistory":
                # History batch complete - update loading state
                key = self._buffer_key(batch.target)
                self.restore_history_targets.discard(key)
                self._history_loading.discard(key)
                
                # Remove the inline spinner if present (scroll-triggered history)
                # For initial history on join, there's no spinner - the loading overlay handles that
                for spinner in self.query(InlineSpinner):
                    spinner.remove()
                
                self._check_loading_complete()
                
                # Switch to the channel and scroll to top to show new messages
                self.active_buffer = key
                self._scroll_mode = "home"
                self._render_active_buffer()
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
            msgid = tags.get("msgid", "")
            if batch_id and batch_id in self.batches:
                if reply_to and thread_root:
                    parent = self.message_index.get(reply_to)
                    parent_snip = self._snippet(parent.text, 50) if parent else "(original not loaded)"
                    parent_sender = parent.sender if parent else "?"
                    self.batches[batch_id].lines.append(
                        (tags.get("time", ""), self._format_reply_indicator(parent_sender, parent_snip, thread_root))
                    )
                    self.batches[batch_id].thread_roots.append(thread_root)
                    self.batches[batch_id].msgids.append(None)
                    self.batches[batch_id].line_metas.append(None)
                self.batches[batch_id].lines.append(
                    (tags.get("time", ""), self._format_message(sender, text))
                )
                self.batches[batch_id].thread_roots.append(thread_root or None)
                self.batches[batch_id].msgids.append(msgid or None)
                self.batches[batch_id].line_metas.append((sender, text, tags.get("time", "")))
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
                        msgid="",
                        line_meta=None,
                    )
                self._append_line(
                    buffer_name,
                    self._format_message(sender, text),
                    msgid=msgid,
                    line_meta=(sender, text, tags.get("time", "")),
                    thread_root=thread_root,
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
        _dbg(f"_send_reply(target={target!r}, msgid={reply_to_msgid[:8]!r}, text={text[:20]!r})")
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
        
        # Check if replying to a specific message
        if self._reply_to_msgid:
            self._send_reply(self._display_name(target), self._reply_to_msgid, text)
            self._reply_to_msgid = None  # Clear after sending
            # Close reply panel if open
            for panel in self.query(ReplyPanel):
                panel.remove()
        else:
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
        # Clear debug callback
        from .widgets.debug import set_debug_callback
        set_debug_callback(None)
