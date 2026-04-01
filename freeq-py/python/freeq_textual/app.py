from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from dataclasses import dataclass, field
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
from rich.markdown import Markdown
from rich.console import Console
from textual import events, on
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.css.query import NoMatches
from textual.reactive import reactive
from textual.widgets import Button, Footer, Header, Input, ListItem, ListView, Static

from .client import BrokerAuthFlow, FreeqAuthBroker, FreeqClient
from .widgets import BufferList, InlineSpinner, LoadingOverlay, MessageItem, MessagesPanel, MessagesPanelWithThread, ScrollableLog, SidePanelSlot, SlottedMessageList, ThreadMessage, ThreadPanel
from .components import get_component
from .components.all import *  # noqa: F401 - registers all widgets as friends!

# Get swappable components from registry - WE'RE ALL FRIENDS HERE!
# DO NOT import directly - use registry so everyone can be swapped
ReplyPanel = get_component('reply_panel')
ContextMenu = get_component('context_menu')
EmojiPicker = get_component('emoji_picker')
ThreadPanel = get_component('thread_panel')
BufferList = get_component('buffer_list')
UserList = get_component('user_list')
ScrollableLog = get_component('scrollable_log')
SlottedMessageList = get_component('slotted_message_list')
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

# Image URL pattern (defined early for use in the app)
_IMAGE_URL_RE = re.compile(r'https?://[^\s]+\.(?:png|jpg|jpeg|gif|webp|bmp|svg)(?:\?[^\s]*)?', re.IGNORECASE)


# ── Debug logging ─────────────────────────────────────────────────────────
# SINGLE LOG FILE: /tmp/freeq.log - ALL logging goes here!
# DO NOT create additional log files!
# DO NOT log to different files for different modules!
# ALL FRIENDS LOG TO THE SAME PLACE!

# Import the ONE TRUE _dbg from widgets/debug.py
from .widgets.debug import _dbg  # noqa: E402 - must import after module setup

# Import textual-image lazily at runtime to avoid module-level issues
def _ensure_textual_image():
    """Lazy import of textual-image to avoid build-time issues."""
    global TEXTUAL_IMAGE_AVAILABLE, TextualImageRenderable
    if TEXTUAL_IMAGE_AVAILABLE is None:
        try:
            from textual_image.renderable import Image as TextualImageRenderable
            TEXTUAL_IMAGE_AVAILABLE = True
            _dbg("textual-image lazy import successful")
        except ImportError as e:
            TEXTUAL_IMAGE_AVAILABLE = False
            TextualImageRenderable = None
            _dbg(f"textual-image lazy import failed: {e}")
    return TEXTUAL_IMAGE_AVAILABLE

# Initialize as None, will be set on first use
TEXTUAL_IMAGE_AVAILABLE = None
TextualImageRenderable = None


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
    is_streaming: bool = False  # True while message is being streamed (e.g., LLM output)
    mime_type: str = ""  # e.g., "text/markdown" for full markdown rendering
    edit_history: list[str] = field(default_factory=list)  # Previous versions of the text


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
    # LAYOUT ARCHITECTURE:
    # Horizontal(#body) contains 3 children that participate in layout:
    # - BufferList: fixed width 20
    # - MessagesPanel: 1fr (takes remaining space) 
    # - UserList: fixed width 25
    # Total fixed: 45 columns, leaving rest for messages
    #
    # SidePanelSlot is DOCKED to right (overlays, doesn't participate in flow)
    # It appears/disappears without affecting MessagesPanel width
    #
    # CRITICAL: Do NOT add width-based siblings to Horizontal without
    # adjusting the 1fr calculation. See tests/test_messages_panel_regression.py
    DEFAULT_CSS = """
    #body {
        width: 1fr;
        height: 1fr;
    }
    
    #messages {
        width: 1fr;
    }

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
        self.channel_ops: dict[str, set[str]] = defaultdict(set)  # Channel operators (+o)
        self.channel_voice: dict[str, set[str]] = defaultdict(set)  # Voiced users (+v)
        self.channel_topics: dict[str, str] = {}
        self.message_index: dict[str, MessageState] = {}
        self._reactions: dict[str, list[tuple[str, str]]] = defaultdict(list)  # msgid -> [(sender, emoji), ...]
        self.threads: dict[str, ThreadState] = {}
        self._thread_activity = 0
        self.restore_history_targets: set[str] = set()
        self._history_loading: set[str] = set()  # Channels currently loading history (prevent duplicates)
        self._history_exhausted: set[str] = set()  # Channels where we've hit the end of history
        self._scroll_mode = "preserve"
        self._scroll_target_msgid = ""
        self._theme_ready = False
        self._avatars_enabled = True  # Always use avatars
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
        self._pending_images: dict[str, tuple[str, str, int]] = {}  # msgid -> (url, buffer_name, line_index)
        self._rendered_images: dict[str, object] = {}  # msgid -> rendered image renderable
        self._pending_whois: set[str] = set()
        self._pending_avatar_fetches: set[str] = set()
        self._avatar_updates: SimpleQueue[tuple[str, list[str] | None, object | None]] = SimpleQueue()
        self._is_loading = True  # Loading state - shows spinner until data loaded
        self._load_message = "Connecting..."
        self._connected = False  # Track if we've received connected event
        self._history_loading_key: str | None = None  # Buffer key currently loading history
        # NOTE: NO global _reply_to_msgid! ReplyPanel owns its state.
        # Friends don't let friends use global state!

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="body"):
            yield BufferList(id="sidebar")
            yield MessagesPanel(use_slots=True)
            # NOTE: SidePanelSlot is DOCKED (see sum_slots.py), so it overlays
            # rather than participating in Horizontal layout. This prevents it
            # from squeezing MessagesPanel when hidden (display:none still takes space)
            yield UserList(id="user-list")
        # Docked overlay - appears above content without affecting layout
        yield SidePanelSlot(id="side-panel", empty_height=0)
        yield Input(
            placeholder="Type a message or /join /channel",
            id="composer",
            classes="-textual-compact",
        )
        yield Footer(compact=True)
        # Overlay slot for floating components (initially hidden)
        from .widgets import OverlaySlot
        yield OverlaySlot(id="overlay-slot", empty_height=0)

    def on_mount(self) -> None:
        _dbg("App.on_mount()")
        # Check textual-image availability at runtime
        _dbg(f"TEXTUAL_IMAGE_AVAILABLE={TEXTUAL_IMAGE_AVAILABLE}, TextualImageRenderable={TextualImageRenderable is not None}")
        self.theme = self.ui_config.get("theme", self.theme)
        self._theme_ready = True
        self._avatars_enabled = True  # Always use avatars (was: self._detect_avatar_support())
        composer = self.query_one("#composer", Input)
        
        # Mount loading overlay only in non-headless mode (component lifecycle, not CSS toggle)
        if not self.is_headless:
            overlay = LoadingOverlay(self._load_message, id="loading-overlay")
            self.mount(overlay)
        
        self._refresh_layout_widths()
        # Avatars always enabled, use tile fallback if rich-pixels unavailable
        if Pixels is None:
            self._append_status("avatars: rich-pixels unavailable, using tile fallback", "yellow")
        self._append_status(f"connecting to {self.client.server_addr}...", "dim")
        self._scroll_mode = "end"
        # Defer initial render until compose fully completes
        self.call_later(self._render_active_buffer)
        composer.focus()
        
        # Restore channels from UI config (works for both auth and guest users)
        self._restore_session_channels()
        
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

    def _restore_session_channels(self) -> None:
        """Restore channels from UI config for rejoin on connect.
        
        Called during startup to set up pending_rejoin from saved channels.
        Works for both authenticated and guest users.
        """
        # Get channels from UI config (works for all users)
        channels = self.ui_config.get("channels", [])
        if not channels:
            # Fall back to session if available (auth users)
            if self.cached_auth:
                channels = self.cached_auth.get("channels", [])
        
        if channels:
            self.pending_rejoin = set(channels)
            self.restore_history_targets = {
                self._buffer_key(channel)
                for channel in self.pending_rejoin
                if channel.startswith("#") or channel.startswith("&")
            }
            for channel in sorted(self.pending_rejoin):
                self._ensure_buffer(channel)
            _dbg(f"Restored {len(channels)} channels for rejoin: {channels}")

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
            # Restore last visited buffer now that channels are loaded
            self._restore_last_buffer()

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

    def _ensure_emoji_presentation(self, emoji: str) -> str:
        """Add emoji variant selector to emojis that might render as text.
        
        Some emojis (heart, skull, etc.) default to text presentation in terminals,
        appearing smaller than full-color emojis. This forces emoji presentation.
        """
        # Already has variant selector - don't add again
        if '\ufe0f' in emoji:
            return emoji
        # Characters that need explicit emoji presentation  
        NEEDS_EMOJI_VS = {
            '♥', '♡', '☠', '☢', '☣', '⚠', '⚡', '✝', '✡', '☪',
            '☮', '☯', '☸', '♈', '♉', '♊', '♋', '♌', '♍', '♎',
            '♏', '♐', '♑', '♒', '♓', '⛎', '❄', '☄', '⚜', '♻',
            '❤', '💀',  # Red heart and skull can be text too
        }
        if any(c in NEEDS_EMOJI_VS for c in emoji):
            return emoji + '\ufe0f'
        return emoji

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

    def _looks_like_markdown(self, text: str) -> bool:
        """Detect common markdown patterns in text."""
        patterns = [
            (r'\*\*[^*]+\*\*', 'bold'),
            (r'(?<![*\*])\*[^*]+\*(?!\*)', 'italic'),  # *italic* not **
            (r'`[^`]+`', 'code'),
            (r'\[[^\]]+\]\([^)]+\)', 'link'),
            (r'#{1,6}\s+\S', 'header'),  # # Header (anywhere, not just start)
            (r'(?:^|\n)[-*]\s+\S', 'list'),
            (r'(?:^|\n)>\s+\S', 'blockquote'),
            (r'(?<!_)_([^_]+)_(?!_)', 'italic_underscore'),
            (r'__[^_]+__', 'bold_underscore'),
            (r'!\[[^\]]*\]\([^)]+\)', 'image'),
            (r'```', 'codeblock'),
        ]
        for pattern, name in patterns:
            if re.search(pattern, text, re.MULTILINE):
                _dbg(f"  markdown pattern '{name}' matched in: {text[:60]!r}")
                return True
        return False

    # ==========================================================================
    # TEXT RENDERING FRAMEWORK
    # ==========================================================================
    # Pipeline: source -> preprocess -> detect -> render
    #
    # 1. SOURCE: Extract raw text from IRC (with \n escapes, etc.)
    # 2. PREPROCESS: Clean text (unescape newlines, normalize whitespace)
    # 3. DETECT: Determine content type (markdown, plain, code, etc.)
    # 4. RENDER: Format as Rich Text with appropriate styling
    # ==========================================================================

    def _source_text(self, raw: str) -> str:
        """Stage 1: Source raw text from IRC."""
        return raw

    def _preprocess_text(self, text: str) -> str:
        """Stage 2: Preprocess - unescape newlines, normalize."""
        # Convert literal \n to actual newlines
        text = text.replace('\\n', '\n')
        # Strip trailing whitespace but preserve internal newlines
        return text.rstrip()

    def _detect_content_type(self, text: str, mime_type: str = "") -> str:
        """Stage 3: Detect content type. Returns: 'markdown', 'plain', 'code'."""
        if mime_type == "text/markdown":
            return "markdown"
        if self._looks_like_markdown(text):
            return "markdown"
        return "plain"

    def _render_content(self, text: str, content_type: str, is_streaming: bool = False, width: int = 80) -> Text:
        """Stage 4: Render content based on type."""
        if content_type == "markdown":
            return self._render_markdown(text, is_streaming, width)
        # Plain text with URL linking
        return self._render_plain(text)

    def _render_markdown(self, text: str, is_streaming: bool = False, width: int = 80) -> Text:
        """Render markdown to Rich Text.
        
        Uses Rich's Markdown class with a theme matching the TUI dark theme.
        Avoids bright red colors, uses cyan/blue/green instead.
        """
        from rich.theme import Theme
        
        # Custom theme that matches the TUI dark aesthetic
        # No bright reds - uses cyan, blue, green, yellow
        custom_theme = Theme({
            'markdown.h1': 'bold bright_cyan',
            'markdown.h1.border': 'bright_cyan',
            'markdown.h2': 'bold cyan',
            'markdown.h2.border': 'cyan',
            'markdown.h3': 'bold blue',
            'markdown.h3.border': 'blue',
            'markdown.h4': 'bold bright_blue',
            'markdown.h4.border': 'bright_blue',
            'markdown.h5': 'bold green',
            'markdown.h5.border': 'green',
            'markdown.h6': 'bold bright_green',
            'markdown.h6.border': 'bright_green',
            'markdown.strong': 'bold white',
            'markdown.emph': 'italic white',
            'markdown.code': 'bright_yellow on black',
            'markdown.pre': 'bright_yellow on black',
            'markdown.link': 'underline bright_cyan',
            'markdown.link_url': 'underline dim cyan',
            'markdown.blockquote': 'dim italic',
            'markdown.blockquote.border': 'dim blue',
            'markdown.list': 'white',
            'markdown.item': 'white',
            'markdown.item.bullet': 'bright_cyan',
            'markdown.item.number': 'bright_cyan',
            'markdown.hr': 'dim blue',
            'markdown.table': 'white',
            'markdown.table.header': 'bold cyan',
            'markdown.table.border': 'dim blue',
        }, inherit=True)  # Inherit other default styles
        
        # Let Rich render the markdown to ANSI with custom theme
        console = Console(width=width, force_terminal=True, color_system="truecolor", theme=custom_theme)
        with console.capture() as capture:
            # Use github-dark theme for code blocks
            console.print(Markdown(text, code_theme="github-dark"))
        result = capture.get()
        
        # Convert full ANSI output to Text (this preserves all formatting)
        full_text = Text.from_ansi(result)
        
        if is_streaming:
            full_text.append("▍")
        
        _dbg(f"_render_markdown: input lines={text.count(chr(10))}, output={len(full_text.plain)} chars, {len(full_text.spans)} spans")
        return full_text

    def _render_plain(self, text: str) -> Text:
        """Render plain text with URL linking. Detects and marks image URLs."""
        body = Text(no_wrap=False, overflow="fold")
        last_end = 0
        for match in _URL_RE.finditer(text):
            start, end = match.span("url")
            if start > last_end:
                body.append(text[last_end:start])
            url = match.group("url")
            
            # Check if this is an image URL
            if _IMAGE_URL_RE.match(url):
                # Show image indicator
                body.append("🖼️ ", style="cyan")
                display_name = os.path.basename(url.split("?")[0])[:30]  # Truncate long names
                body.append(f"[{display_name}]", style=f"underline cyan link {url}")
            else:
                display_url = self._display_url(url)
                body.append(display_url, style=f"underline cyan link {url}")
            last_end = end
        if last_end < len(text):
            body.append(text[last_end:])
        return body

    def _extract_image_urls(self, text: str) -> list[str]:
        """Extract all image URLs from text."""
        return _IMAGE_URL_RE.findall(text)

    def _render_image_preview(self, url: str, max_width: int = 40, max_height: int = 10) -> Text | None:
        """Download and render an image preview using textual-image.
        
        Returns None if textual-image is not available or rendering fails.
        """
        if not TEXTUAL_IMAGE_AVAILABLE or render_image is None:
            return None
        
        try:
            # Download image
            import urllib.request
            import urllib.error
            
            # Set a timeout and user agent
            req = urllib.request.Request(
                url,
                headers={'User-Agent': 'Mozilla/5.0 (compatible; FreeQ-Chat/1.0)'}
            )
            
            with urllib.request.urlopen(req, timeout=5) as response:
                image_data = response.read()
            
            # Open with PIL
            if Image is None:
                return None
                
            img = Image.open(io.BytesIO(image_data))
            
            # Convert to RGB if necessary
            if img.mode in ('RGBA', 'LA', 'P'):
                img = img.convert('RGB')
            
            # Resize to fit within max dimensions while maintaining aspect ratio
            img.thumbnail((max_width, max_height), Image.Resampling.LANCZOS)
            
            # Render using textual-image
            renderable = render_image(img, max_width=max_width, max_height=max_height)
            
            # Convert to Text for display
            if renderable:
                # The renderable should be compatible with Rich
                return renderable
            
        except Exception as e:
            _dbg(f"Failed to render image {url[:40]}: {e}")
        
        return None

    def _format_message_pipeline(self, raw_text: str, mime_type: str = "", is_streaming: bool = False, width: int = 80) -> Text:
        """Full pipeline: source -> preprocess -> detect -> render."""
        # Stage 1 & 2: Source and preprocess
        text = self._preprocess_text(raw_text)
        
        # Stage 3: Detect
        content_type = self._detect_content_type(text, mime_type)
        _dbg(f"pipeline: raw={len(raw_text)} chars, preprocessed={len(text)} chars, type={content_type}")
        
        # Stage 4: Render
        rendered = self._render_content(text, content_type, is_streaming, width)
        _dbg(f"  -> rendered {len(rendered.plain)} chars, {len(rendered.spans)} spans")
        return rendered

    # Legacy methods (deprecated, use pipeline)
    def _format_markdown(self, text: str, is_streaming: bool = False, width: int = 80) -> Text:
        """Deprecated: Use _render_markdown."""
        return self._render_markdown(text, is_streaming, width)

    def _format_message_body(self, text: str, mime_type: str = "", is_streaming: bool = False) -> Text:
        """Deprecated: Use _format_message_pipeline."""
        return self._format_message_pipeline(text, mime_type, is_streaming)

    def _format_message_with_diff(self, old_text: str, new_text: str, mime_type: str = "", is_streaming: bool = False) -> Text:
        """Format message with inline diff showing removed (red/strike) and added (green) text."""
        # Word-level diff
        old_words = old_text.split()
        new_words = new_text.split()
        
        # Find common prefix
        prefix_len = 0
        for o, n in zip(old_words, new_words):
            if o == n:
                prefix_len += 1
            else:
                break
        
        # Find common suffix
        suffix_len = 0
        for o, n in zip(reversed(old_words[prefix_len:]), reversed(new_words[prefix_len:])):
            if o == n:
                suffix_len += 1
            else:
                break
        
        removed = old_words[prefix_len:len(old_words) - suffix_len] if suffix_len > 0 else old_words[prefix_len:]
        added = new_words[prefix_len:len(new_words) - suffix_len] if suffix_len > 0 else new_words[prefix_len:]
        
        # Build result with inline styling
        result = Text()
        
        # Common prefix (normal)
        if prefix_len > 0:
            prefix = " ".join(old_words[:prefix_len])
            result.append(prefix + " ")
        
        # Removed text (red strikethrough)
        if removed:
            removed_str = " ".join(removed)
            result.append(removed_str + " ", style="red strike")
        
        # Added text (green)
        if added:
            added_str = " ".join(added)
            result.append(added_str + " ", style="green")
        
        # Common suffix (normal)
        if suffix_len > 0:
            suffix = " ".join(old_words[len(old_words) - suffix_len:])
            result.append(suffix)
        
        # Handle streaming indicator
        if is_streaming:
            result.append("▍")
        
        return result

    def _format_message(self, sender: str, text: str, width: int = 0, *, mime_type: str = "", is_streaming: bool = False) -> Text:
        """A chat message: `<nick>: <text>` with colored nick and avatar.
        
        Always uses avatars. Markdown is detected and rendered with proper formatting.
        """
        parts: list[Text] = []
        # Always use avatars
        avatar = self._format_avatar(sender)
        if avatar.plain:
            parts.append(avatar)
        parts.append(self._format_nick(sender))
        parts.append(Text(": "))
        
        # Always use avatar indent (5 spaces for avatar + space)
        indent = 5
        nick_len = len(sender) + 2  # ": "
        indent += nick_len
        
        # Check if this is markdown - if so, render first then handle wrapping
        is_markdown = mime_type == "text/markdown" or self._looks_like_markdown(text)
        
        if is_markdown:
            # Render markdown first (creates multi-line output with formatting)
            body = self._format_message_body(text, mime_type, is_streaming)
            # For markdown, we assemble without width-based wrapping
            # The markdown renderer already handles line breaks
            parts.append(body)
            return Text().assemble(*parts)
        
        if width > 0:
            # Wrap text to width with indent
            lines = self._format_message_lines(text, indent, width)
            if lines:
                # First line goes on same line as nick (no indent, it's after nick)
                parts.append(self._format_message_body(lines[0].plain.lstrip(), mime_type, is_streaming))
                result = Text().assemble(*parts)
                # Continuation lines need indent + URL processing
                for cont_line in lines[1:]:
                    result.append(Text("\n"))
                    # cont_line has indent baked in, preserve it
                    indented = Text(" " * indent) + self._format_message_body(cont_line.plain.lstrip(), mime_type, is_streaming)
                    result.append(indented)
                return result
        
        parts.append(self._format_message_body(text, mime_type, is_streaming))
        return Text().assemble(*parts)

    def _format_thread_message(self, sender: str, text: str, width: int = 0, *, mime_type: str = "", is_streaming: bool = False) -> Text:
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
                result = Text().assemble(name, ": ", self._format_message_body(lines[0], mime_type, is_streaming))
                for cont_line in lines[1:]:
                    result.append(Text("\n"))
                    result.append(self._format_message_body(cont_line, mime_type, is_streaming))
                return result
        
        
        return Text().assemble(name, ": ", self._format_message_body(text, mime_type, is_streaming))

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
        """Wrap message text to width, each line prefixed with indent spaces.
        
        Handles word wrapping manually to ensure proper indentation on all lines,
        including continuation lines when long words need to break.
        """
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
                    # Flush current line with proper indent
                    lines.append(Text(" " * indent + current))
                # Check if the word itself is too long for available space
                if len(word) > available:
                    # Break long word into chunks that fit
                    chunk_start = 0
                    while chunk_start < len(word):
                        chunk = word[chunk_start:chunk_start + available]
                        lines.append(Text(" " * indent + chunk))
                        chunk_start += available
                    current = ""
                else:
                    current = word
        
        # Flush remaining text
        if current:
            lines.append(Text(" " * indent + current))
        
        return lines

    def _split_text_by_lines(self, text: Text) -> list[Text]:
        """Split a Text object by newlines, preserving style spans in each line."""
        _dbg(f"_split_text_by_lines: input has {len(text.spans)} spans, {text.plain.count(chr(10))} newlines")
        
        if '\n' not in text.plain:
            _dbg(f"  -> no newlines, returning as-is")
            return [text]
        
        lines: list[Text] = []
        current_start = 0
        
        for i, char in enumerate(text.plain):
            if char == '\n':
                # Create a new Text for this line
                line_text = text.plain[current_start:i]
                line = Text(line_text)
                
                # Copy spans that fall within this line's range
                for span in text.spans:
                    if span.end <= current_start:
                        continue
                    if span.start >= i:
                        continue
                    # Span overlaps with this line
                    new_start = max(span.start, current_start) - current_start
                    new_end = min(span.end, i) - current_start
                    line.spans.append(type(span)(new_start, new_end, span.style))
                
                lines.append(line)
                _dbg(f"  -> line[{len(lines)-1}]: '{line_text[:40]!r}' with {len(line.spans)} spans")
                current_start = i + 1
        
        # Handle last line (after final newline)
        if current_start < len(text.plain):
            line_text = text.plain[current_start:]
            line = Text(line_text)
            for span in text.spans:
                if span.end <= current_start:
                    continue
                new_start = max(span.start, current_start) - current_start
                new_end = min(span.end, len(text.plain)) - current_start
                line.spans.append(type(span)(new_start, new_end, span.style))
            lines.append(line)
            _dbg(f"  -> line[{len(lines)-1}] (last): '{line_text[:40]!r}' with {len(line.spans)} spans")
        
        _dbg(f"  -> total lines: {len(lines)}")
        return lines

    def _format_chat_block(self, sender: str, text: str, width: int = 80, reply_indicator: Text | None = None, reply_thread_root: str | None = None, timestamp: str = "", msgid: str | None = None, *, mime_type: str = "", is_streaming: bool = False) -> tuple[list[Text], list[str | None]]:
        """Return tuple of (lines, thread_roots) for a chat message.
        
        With avatars:
        - Line 1: ████ nick HH:MMpm MM/DD
        - Line 2: ████ reply indicator (if any) OR first line of message
        - Line 3+:      continuation (same column as line 2 text)
        """
        name = Text(sender, style=f"bold {_nick_color(sender)}")
        roots: list[str | None] = []
        
        # Get reactions for this message
        reactions_text = Text()
        if msgid and msgid in self._reactions:
            for r_sender, r_emoji in self._reactions[msgid]:
                reactions_text.append(f" {self._ensure_emoji_presentation(r_emoji)}")
        
        # Check if message has been edited - use current text from message_index if available
        has_edit_history = False
        old_text_for_diff = ""
        current_text = text
        if msgid and msgid in self.message_index:
            msg_state = self.message_index[msgid]
            current_text = msg_state.text  # Use the current text from message_index
            if msg_state.edit_history:
                has_edit_history = True
                old_text_for_diff = msg_state.edit_history[-1]
        
        
        # Format timestamp as 12hr with date (e.g., "2:30pm 1/15")
        time_str = self._format_timestamp(timestamp)
        time_text = Text(f" {time_str}", style="dim") if time_str else Text()
        
        # Always use avatars: nick on line 1, reply indicator or message on line 2
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
        
        # Check for markdown - handle multi-line formatted output
        is_markdown = mime_type == "text/markdown" or self._looks_like_markdown(current_text)
        if is_markdown:
            body = self._format_message_body(current_text, mime_type, is_streaming)
            _dbg(f"_format_chat_block: markdown body has {len(body.plain)} chars, {body.plain.count(chr(10))} newlines, {len(body.spans)} spans")
            # Split markdown by lines preserving formatting
            body_lines = self._split_text_by_lines(body)
            _dbg(f"  -> split into {len(body_lines)} lines")
            for i, body_line in enumerate(body_lines):
                if not body_line.plain.strip():
                    continue  # Skip empty lines
                _dbg(f"  -> line[{i}]: {len(body_line.plain)} chars, {len(body_line.spans)} spans")
                if i == 0 and not reply_indicator:
                    # First line with avatar row 2
                    line = Text()
                    for color in rows[1]:
                        line.append("\u2588", style=color)
                    line.append(" ")
                    line.append_text(body_line)
                    lines.append(line)
                else:
                    # Continuation lines with indent
                    # Use the raw text length for width check
                    plain = body_line.plain
                    if len(plain) > text_avail:
                        # Break long line into chunks with proper indent
                        chunk_start = 0
                        while chunk_start < len(plain):
                            chunk_text = plain[chunk_start:chunk_start + text_avail]
                            line = Text(indent)
                            chunk_line = Text(chunk_text)
                            # Copy spans that overlap with this chunk
                            chunk_len = len(chunk_text)
                            for span in body_line.spans:
                                span_start = max(span.start, chunk_start) - chunk_start
                                span_end = min(span.end, chunk_start + chunk_len) - chunk_start
                                if span_start < chunk_len and span_end > 0:
                                    chunk_line.spans.append(type(span)(max(0, span_start), min(chunk_len, span_end), span.style))
                            line.append_text(chunk_line)
                            lines.append(line)
                            roots.append(reply_thread_root)
                            chunk_start += text_avail
                    else:
                        line = Text(indent)
                        line.append_text(body_line)
                        lines.append(line)
                        roots.append(reply_thread_root)
                    continue  # Skip the default roots.append below
            # Add reactions to last line
            if lines:
                lines[-1].append_text(reactions_text)
            return lines, roots
        
        # Wrap message text (non-markdown)
        # If message has edit history, render with inline diff colors (no wrapping)
        if has_edit_history:
            diff_body = self._format_message_with_diff(old_text_for_diff, current_text, mime_type, is_streaming)
            # First message line uses avatar row 2 only if no reply indicator
            if not reply_indicator:
                line = self._make_avatar_text_line(rows[1], diff_body)
                line.append_text(reactions_text)
                lines.append(line)
                roots.append(reply_thread_root)
            else:
                line = Text(indent)
                line.append_text(diff_body)
                line.append_text(reactions_text)
                lines.append(line)
                roots.append(reply_thread_root)
            # Ensure at least 2 lines for avatar display
            if len(lines) == 1:
                lines.append(self._make_avatar_text_line(rows[1], Text()))
                roots.append(None)
            return lines, roots
        
        words = current_text.split()
        current = ""
        line_num = 0
        
        for word in words:
            test = f"{current} {word}".strip()
            test_display = self._format_message_body(test, mime_type, is_streaming).plain
            if len(test_display) <= text_avail:
                current = test
            else:
                if current:
                    # First message line uses avatar row 2 only if no reply indicator
                    if line_num == 0 and not reply_indicator:
                        lines.append(self._make_avatar_text_line(rows[1], self._format_message_body(current, mime_type, is_streaming)))
                    else:
                        cont = Text(indent)
                        cont.append_text(self._format_message_body(current, mime_type, is_streaming))
                        lines.append(cont)
                    # Message line gets thread_root for replies (larger click target)
                    roots.append(reply_thread_root)
                current = word
                line_num += 1
        
        
        # Flush remaining text
        if current:
            if line_num == 0 and not reply_indicator:
                last_line = self._make_avatar_text_line(rows[1], self._format_message_body(current, mime_type, is_streaming))
                last_line.append_text(reactions_text)  # Add reactions to last line
                lines.append(last_line)
            else:
                cont = Text(indent)
                cont.append_text(self._format_message_body(current, mime_type, is_streaming))
                cont.append_text(reactions_text)  # Add reactions to last line
                lines.append(cont)
            # Message line gets thread_root for replies (larger click target)
            roots.append(reply_thread_root)
        else:
            # No message text, just add reactions to last line if any
            if reactions_text and lines:
                lines[-1].append_text(reactions_text)
        
        
        # Ensure at least 2 lines for avatar display
        if len(lines) == 1:
            lines.append(self._make_avatar_text_line(rows[1], Text()))
            roots.append(None)
        
        # Check for image URLs and add image previews
        _ensure_textual_image()
        _dbg(f"Checking images: TEXTUAL_IMAGE_AVAILABLE={TEXTUAL_IMAGE_AVAILABLE}, current_text={bool(current_text)}, msgid={bool(msgid)}")
        if TEXTUAL_IMAGE_AVAILABLE and current_text and msgid:
            image_urls = self._extract_image_urls(current_text)
            _dbg(f"Extracted URLs from text: {image_urls}")
            if image_urls:
                _dbg(f"Found {len(image_urls)} image URLs in message {msgid[:8]}")
                for i, img_url in enumerate(image_urls[:2]):  # Limit to first 2 images
                    # Check if we already have this image rendered
                    if msgid in self._rendered_images:
                        # Use the pre-rendered image directly (not wrapped in Text)
                        # The renderable from textual-image is a special type, not Text
                        img_line = self._rendered_images[msgid]
                        lines.append(img_line)
                        roots.append(None)
                        _dbg(f"Using cached image for {msgid[:8]}: {type(img_line)}")
                    else:
                        # Start async image loading if not already pending
                        if msgid not in self._pending_images:
                            self._pending_images[msgid] = (img_url, buffer_key, len(lines))
                            _dbg(f"Starting async image load for {msgid[:8]}: {img_url[:50]}")
                            self._load_image_async(msgid, img_url, buffer_key)
                        else:
                            _dbg(f"Image already loading for {msgid[:8]}")
                        
                        # Show placeholder while loading
                        img_line = Text("     🖼️ ", style="dim")
                        img_name = os.path.basename(img_url.split("?")[0])[:25]
                        img_line.append(f"[Loading: {img_name}]", style=f"dim cyan link {img_url}")
                        lines.append(img_line)
                        roots.append(None)
            else:
                _dbg(f"No image URLs found in text: {current_text[:80]}")
        else:
            _dbg(f"Skipping image check: TEXTUAL_IMAGE_AVAILABLE={TEXTUAL_IMAGE_AVAILABLE}, has_text={bool(current_text)}, has_msgid={bool(msgid)}")
        
        return lines, roots

    def _load_image_async(self, msgid: str, url: str, buffer_key: str) -> None:
        """Load and render an image asynchronously using Textual workers."""
        _dbg(f"_load_image_async starting for {msgid[:8]}: {url[:50]}")
        
        async def download_and_render() -> Text | None:
            try:
                import urllib.request
                import urllib.error
                
                _dbg(f"Downloading image {url[:50]}...")
                req = urllib.request.Request(
                    url,
                    headers={'User-Agent': 'Mozilla/5.0 (compatible; FreeQ-Chat/1.0)'}
                )
                
                # Run the download in a thread to not block
                loop = asyncio.get_event_loop()
                image_data = await loop.run_in_executor(
                    None,  # Default executor
                    lambda: urllib.request.urlopen(req, timeout=10).read()
                )
                
                _dbg(f"Downloaded {len(image_data)} bytes for {msgid[:8]}")
                
                # Open with PIL
                if Image is None:
                    _dbg(f"PIL Image not available!")
                    return None
                    
                img = Image.open(BytesIO(image_data))
                _dbg(f"Opened image: {img.size} {img.mode}")
                
                # Convert to RGB if necessary
                if img.mode in ('RGBA', 'LA', 'P'):
                    img = img.convert('RGB')
                
                # Calculate dimensions (max 60 chars wide, 15 lines tall)
                max_width = 60
                max_height = 15
                
                # Resize maintaining aspect ratio
                img.thumbnail((max_width, max_height), Image.Resampling.LANCZOS)
                _dbg(f"Resized to {img.size}")
                
                # Render using textual-image
                if TextualImageRenderable is None:
                    _dbg(f"TextualImageRenderable is None, textual-image not available!")
                    return None
                
                # Create the Rich renderable image (this outputs terminal graphics protocol sequences)
                # For RichLog/ScrollableLog compatibility, we need to wrap it properly
                renderable = TextualImageRenderable(img, width=img.width, height=img.height)
                _dbg(f"Rendered image for {msgid[:8]}: type={type(renderable)}, size={img.size}")
                
                return renderable
                
            except Exception as e:
                _dbg(f"Failed to render image {url[:50]}: {e}")
                import traceback
                _dbg(f"Traceback: {traceback.format_exc()}")
                # Return error text
                error_text = Text(f"[Image failed: {str(e)[:30]}]", style="red dim")
                return error_text
        
        async def load_worker():
            _dbg(f"load_worker starting for {msgid[:8]}")
            rendered = await download_and_render()
            _dbg(f"load_worker got rendered image: {rendered is not None}")
            if rendered:
                self._rendered_images[msgid] = rendered
                self._pending_images.pop(msgid, None)
                # Trigger re-render of the buffer
                if self.active_buffer == buffer_key:
                    _dbg(f"Triggering re-render for buffer {buffer_key}")
                    self._scroll_mode = "preserve"
                    self.call_later(self._render_active_buffer)
                else:
                    _dbg(f"Buffer {buffer_key} not active (current: {self.active_buffer}), skipping re-render")
                _dbg(f"Image rendered successfully for {msgid[:8]}")
            else:
                _dbg(f"No rendered image for {msgid[:8]}")
        
        # Start the async worker
        _dbg(f"Creating asyncio task for image load {msgid[:8]}")
        try:
            asyncio.create_task(load_worker())
            _dbg(f"Task created for {msgid[:8]}")
        except Exception as e:
            _dbg(f"Failed to create task: {e}")
            import traceback
            _dbg(f"Traceback: {traceback.format_exc()}")

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
        """Refresh sidebar buffer list."""
        from .widgets import _dbg, validate_invariant
        
        # Guard: Don't run before mount. No try/except - hard fail for real bugs.
        if not self.is_mounted:
            _dbg("SIDEBAR: skipped refresh - app not mounted")
            return
        
        buffer_count = len(self.buffers)
        _dbg(f"SIDEBAR: refreshing with {buffer_count} buffers: {list(self.buffers.keys())}")
        
        ordered = sorted(self.buffers.values(), key=lambda b: (b.name != "status", b.name))
        
        # PROVABLE DIAGNOSTIC: This will throw if BufferList not found
        # Log shows exactly what's happening
        try:
            sidebar = self.query_one(BufferList)
            _dbg(f"SIDEBAR: found BufferList widget, updating with {len(ordered)} items")
            sidebar.update_buffers(ordered, self.active_buffer)
            
            # Verify the update actually created children
            child_count = len(list(sidebar.children))
            _dbg(f"SIDEBAR: BufferList now has {child_count} children")
            
            validate_invariant(
                len(ordered) == child_count,
                f"BufferList child count mismatch: expected {len(ordered)}, got {child_count}",
                expected=len(ordered),
                actual=child_count,
                buffers=list(self.buffers.keys())
            )
        except Exception as e:
            _dbg(f"SIDEBAR_ERROR: failed to refresh - {type(e).__name__}: {e}")
            raise  # Hard fail - we want to know if this breaks

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
        # Guard: Don't run before mount. No try/except - hard fail for real bugs.
        if not self.is_mounted:
            return
        ordered = sorted(self.buffers.values(), key=lambda b: (b.name != "status", b.name))
        sidebar = self.query_one(BufferList)
        sidebar.update_buffers(ordered, self.active_buffer)
        self._refresh_user_list()

    def _refresh_user_list(self) -> None:
        """Refresh user list panel with current channel members."""
        # Guard: Don't run before mount. No try/except - hard fail for real bugs.
        if not self.is_mounted:
            return
        user_list = self.query_one("#user-list", UserList)
        if self.active_buffer == "status":
            user_list.update_users("status", set(), set(), set())
        elif self.active_buffer in self.channel_members:
            members = self.channel_members[self.active_buffer]
            ops = self.channel_ops.get(self.active_buffer, set())
            voice = self.channel_voice.get(self.active_buffer, set())
            display_name = self._display_name(self.active_buffer)
            user_list.update_users(display_name, members, ops, voice)
        else:
            user_list.update_users(self.active_buffer, set(), set(), set())

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
        # Log the actual rendered output for debugging
        _dbg(f"_append_line: plain={rich.plain[:60]!r} spans={len(rich.spans)}")
        for i, span in enumerate(rich.spans[:3]):
            _dbg(f"  span[{i}]: {span.start}-{span.end} style={span.style}")

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
        # Debug: Check if lines have markdown spans
        for i, line in enumerate(lines):
            if isinstance(line, Text) and line.spans:
                _dbg(f"_prepend_lines[{i}]: {len(line.spans)} spans, plain={line.plain[:50]!r}")
                # Show all spans
                for j, span in enumerate(line.spans):
                    _dbg(f"  span[{j}]: {span.start}-{span.end} style={span.style}")
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
            
            # Look up message metadata from message_index if available
            msg_info = self.message_index.get(msgid) if msgid else None
            mime_type = msg_info.mime_type if msg_info else ""
            is_streaming = msg_info.is_streaming if msg_info else False
            
            if is_first:
                # Get reply indicator (first pending) to embed in chat block
                reply_ind = pending_reply_indicators[0][0] if pending_reply_indicators else None
                reply_root = pending_reply_indicators[0][1] if pending_reply_indicators else None
                pending_reply_indicators.clear()
                block_lines, block_roots = self._format_chat_block(sender, text, width, reply_indicator=reply_ind, reply_thread_root=reply_root, timestamp=timestamp, msgid=msgid, mime_type=mime_type, is_streaming=is_streaming)
                for block_line, block_root in zip(block_lines, block_roots):
                    renderable.append(block_line)
                    render_roots.append(block_root)
                    render_msgids.append(msgid)  # All lines of same message share msgid
            else:
                # Continuation of same sender - just message body, indented
                # Get current text from message_index if available (for edited messages)
                current_text = msg_info.text if msg_info else text
                # BUT: if this is a reply, we need to show its reply indicator first
                indent = 5  # Always use avatar indent
                if pending_reply_indicators:
                    # Show pending reply indicator(s) before the continuation message
                    # Indent them to match the continuation message
                    indent_str = " " * indent
                    for pending_line, pending_root, pending_msgid in pending_reply_indicators:
                        indented_line = Text(indent_str) + pending_line
                        renderable.append(indented_line)
                        render_roots.append(pending_root)
                        render_msgids.append(pending_msgid)
                    pending_reply_indicators.clear()
                # Check for reactions on this message
                reactions_text = Text()
                if msgid and msgid in self._reactions:
                    for r_sender, r_emoji in self._reactions[msgid]:
                        reactions_text.append(f" {self._ensure_emoji_presentation(r_emoji)}")
                
                # Determine content type
                is_markdown = mime_type == "text/markdown" or self._looks_like_markdown(current_text)
                
                # Check if message has edit history - render with inline diff
                if msg_info and msg_info.edit_history:
                    old_text = msg_info.edit_history[-1]
                    diff_body = self._format_message_with_diff(old_text, current_text, mime_type, is_streaming)
                    line = Text(" " * indent)
                    line.append_text(diff_body)
                    if reactions_text:
                        line.append_text(reactions_text)
                    renderable.append(line)
                    render_roots.append(None)
                    render_msgids.append(msgid)
                # Check if this is markdown - handle it properly
                elif is_markdown:
                    # Render markdown and split into lines
                    body = self._format_message_body(current_text, mime_type, is_streaming)
                    body_lines = self._split_text_by_lines(body)
                    for i, body_line in enumerate(body_lines):
                        if not body_line.plain.strip():
                            continue
                        # Add indent and handle long lines that need wrapping
                        plain = body_line.plain
                        available = max(20, width - indent)
                        if len(plain) > available:
                            # Break long line into chunks with proper indent
                            chunk_start = 0
                            while chunk_start < len(plain):
                                chunk_text = plain[chunk_start:chunk_start + available]
                                # Create new Text with chunk, preserving original styling
                                chunk_len = len(chunk_text)
                                line = Text(" " * indent)
                                chunk_line = Text(chunk_text)
                                # Copy spans that overlap with this chunk
                                for span in body_line.spans:
                                    span_start = max(span.start, chunk_start) - chunk_start
                                    span_end = min(span.end, chunk_start + chunk_len) - chunk_start
                                    if span_start < chunk_len and span_end > 0:
                                        chunk_line.spans.append(type(span)(max(0, span_start), min(chunk_len, span_end), span.style))
                                line.append_text(chunk_line)
                                renderable.append(line)
                                render_roots.append(None)
                                render_msgids.append(msgid)
                                chunk_start += available
                        else:
                            # Short line - just add indent
                            line = Text(" " * indent)
                            line.append_text(body_line)
                            renderable.append(line)
                            render_roots.append(None)
                            render_msgids.append(msgid)
                else:
                    # Plain text - word wrap as before
                    msg_lines = self._format_message_lines(current_text, indent, width)
                    for i, msg_line in enumerate(msg_lines):
                        renderable.append(msg_line)
                        render_roots.append(None)
                        render_msgids.append(msgid)
                
                # Append reactions to the last rendered line
                if reactions_text and renderable:
                    last_line = renderable[-1]
                    if isinstance(last_line, Text):
                        last_line.append_text(reactions_text)

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
        # Always look up avatars
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
            # Check for streaming flag and mime type from tags
            is_streaming = tags.get("+freeq.at/streaming") == "1"
            mime_type = tags.get("+freeq.at/mime", "")
            
            # If this is an edit of an existing message
            edit_of = tags.get("+draft/edit")
            if edit_of and edit_of in self.message_index:
                # Update existing message (edit or streaming continuation)
                existing = self.message_index[edit_of]
                # Store previous version for diff
                existing.edit_history.append(existing.text)
                existing.text = text
                existing.is_streaming = is_streaming
                existing.mime_type = mime_type  # Update mime type on edit too
                _dbg(f"Updated message {edit_of[:8]}: streaming={is_streaming}, edits={len(existing.edit_history)}")
            else:
                # New message
                self.message_index[msgid] = MessageState(
                    buffer_key=buffer_key,
                    sender=sender,
                    text=text,
                    thread_root=thread_root or msgid,
                    msgid=msgid,
                    reply_to=reply_to,
                    is_reply=is_reply,
                    timestamp=timestamp,
                    is_streaming=is_streaming,
                    mime_type=mime_type,
                )
                _dbg(f"Recorded msgid={msgid[:8]} reply_to={reply_to[:8] if reply_to else None} sender={sender} streaming={is_streaming} mime={mime_type}")
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
                thread_root, thread_msgs, self._format_thread_message, use_slots=True
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
            new_panel = MessagesPanel(use_slots=True)
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
        
        # Close the side panel slot after sending reply
        side_slot = self.query_one("#side-panel", SidePanelSlot)
        if side_slot:
            side_slot.clear()
            _dbg("  cleared side-panel slot after reply")

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

    @on(SlottedMessageList.MessageClicked)
    def _on_slotted_message_clicked(self, event: SlottedMessageList.MessageClicked) -> None:
        """Handle clicks from SlottedMessageList widget.
        
        Slot-based architecture - each message is a widget with a slot.
        """
        _dbg(f"SlottedMessageList.MessageClicked: msgid={event.msgid[:8] if event.msgid else None}")
        
        # Get the slotted list and show context menu
        try:
            slotted = self.query_one("#messages", SlottedMessageList)
        except Exception:
            return
        
        # Show context menu in slot for this message
        if event.msgid and event.widget:
            self._show_context_menu_in_slot(slotted, event.msgid)

    def _show_context_menu_in_slot(self, slotted: SlottedMessageList, msgid: str) -> None:
        """Show context menu in the slot of a specific message."""
        _dbg(f"_show_context_menu_in_slot: msgid={msgid[:8]}")
        
        # Clear any existing slot first (exclusive slots)
        slotted.clear_active_slot()
        
        # Create menu with on_close callback to clear slot
        def clear_slot():
            slotted.clear_active_slot()
        
        menu = ContextMenu(
            actions=[
                ("Reply", self._on_menu_reply),
                ("React", self._on_menu_react),
            ],
            msgid=msgid,
            on_close=clear_slot,
        )
        
        # Mount into the slot - the slot is part of the message layout
        slotted.mount_in_slot(msgid, menu)
        _dbg(f"  mounted ContextMenu in slot for msgid={msgid[:8]}")

    @on(ScrollableLog.ScrolledToTop)
    @on(SlottedMessageList.ScrolledToTop)
    def _on_scrolled_to_top(self, event) -> None:
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
            # Clear any active slots in SlottedMessageList
            try:
                slotted = self.query_one("#messages", SlottedMessageList)
                slotted.clear_active_slot()
            except Exception:
                pass

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
        """Show context menu in the slot below the clicked message.
        
        Slot-based architecture:
        - Each message has a reserved slot below it
        - ContextMenu mounts into the slot (not floating)
        - When action completes, component is destroyed, slot is empty
        - Such modular. Much reactive.
        """
        _dbg(f"_show_context_menu: x={event.x} y={event.y}")
        
        # Find which message is under cursor
        if isinstance(log, SlottedMessageList):
            # Slotted architecture - mount into message's slot
            # Each MessageItem is a separate widget, so we need to find
            # which MessageItem contains the click
            msgid = None
            for child in log.children:
                if isinstance(child, MessageItem):
                    # Check if click is within this item's region
                    if child.region.contains(event.x, event.y):
                        msgid = child.msgid
                        _dbg(f"  found MessageItem at click position, msgid={msgid[:8] if msgid else None}")
                        break
            
            # Show context menu in slot
            if msgid:
                self._show_context_menu_in_slot(log, msgid)
        else:
            # Legacy ScrollableLog - use absolute positioning
            # Close any existing menu
            for menu in self.query(ContextMenu):
                menu.remove()
            
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
            # Mount to screen with absolute positioning at click location
            menu.styles.position = "absolute"
            menu.styles.offset = (event.x, event.y)
            self.screen.mount(menu)
            _dbg(f"  mounted ContextMenu at ({event.x}, {event.y}) msgid={msgid[:8] if msgid else None}")
    
    def _get_log(self) -> ScrollableLog | SlottedMessageList | None:
        """Get the messages widget (ScrollableLog or SlottedMessageList)."""
        try:
            # Try ScrollableLog first (legacy)
            return self.query_one("#messages", ScrollableLog)
        except Exception:
            pass
        try:
            # Try SlottedMessageList (new slot-based architecture)
            return self.query_one("#messages", SlottedMessageList)
        except Exception:
            return None

    def _get_msgid_at_line(self, virtual_y: int) -> str | None:
        """Get the message ID at a given line index.
        
        DESIGN: Query the ScrollableLog component directly - it tracks msgids
        per rendered line. Do NOT use app's _rendered_line_msgids which can be stale.
        """
        log = self._get_log()
        if log:
            return log.msgid_at(virtual_y)
        return None
    
    def _on_menu_reply(self, msgid: str | None) -> None:
        """Handle Reply from context menu - show reply panel in side slot."""
        _dbg(f"_on_menu_reply(msgid={msgid[:8] if msgid else None})")
        
        if not msgid:
            return
        
        # Get message context
        msg = self.message_index.get(msgid)
        if not msg:
            _dbg(f"  msgid {msgid} not found in index")
            return
        
        # Get side panel slot and load ReplyPanel
        side_slot = self.query_one("#side-panel", SidePanelSlot)
        if side_slot:
            side_slot.load_variant(
                ReplyPanel,
                reply_to_msgid=msgid,
                context=msg.text,
                sender=msg.sender,
                target=self._display_name(self.active_buffer),
                on_close=lambda: _dbg(f"ReplyPanel closed for {msgid[:8]}")
            )
            _dbg(f"  loaded ReplyPanel into side-panel slot for {msgid[:8]}")
        else:
            _dbg("  ERROR: side-panel slot not found")
    
    def _on_menu_react(self, msgid: str | None) -> None:
        """Handle React from context menu - show emoji picker in message slot."""
        _dbg(f"Context menu React: msgid={msgid}")
        if not msgid:
            return
        
        # Get the inline actions slot for this message and load emoji picker
        # For now, use overlay slot as fallback
        slot_id = f"msg-{msgid[:8]}-actions" if msgid else None
        
        # Try to find the message's slot in slotted message list
        messages_list = self.query_one("#messages", (SlottedMessageList, ScrollableLog))
        if isinstance(messages_list, SlottedMessageList):
            # Find message item by msgid
            for item in messages_list.children:
                if hasattr(item, 'msgid') and item.msgid == msgid:
                    if hasattr(item, 'actions_slot') and item.actions_slot:
                        item.actions_slot.load_variant(
                            EmojiPicker,
                            msgid=msgid,
                            on_close=lambda: _dbg(f"EmojiPicker closed for {msgid[:8]}")
                        )
                        _dbg(f"  loaded EmojiPicker into message slot for {msgid[:8]}")
                        return
        
        # Fallback: use overlay slot
        overlay_slot = self.query_one("#overlay-slot", TypedSlot)
        if overlay_slot:
            overlay_slot.load_variant(
                EmojiPicker,
                msgid=msgid,
                on_close=lambda: _dbg(f"EmojiPicker closed for {msgid[:8]}")
            )
            _dbg(f"  loaded EmojiPicker into overlay slot for {msgid[:8]}")
    
    @on(EmojiPicker.EmojiSelected)
    def handle_emoji_selected(self, event: EmojiPicker.EmojiSelected) -> None:
        """Handle emoji selection - send reaction via TAGMSG."""
        _dbg(f"Emoji selected: {event.emoji} for msgid={event.msgid[:8] if event.msgid else None}")
        if event.msgid:
            # Optimistically add reaction locally (server won't echo without echo-message cap)
            self._reactions[event.msgid].append((self.client.nick, event.emoji))
            
            # Send reaction via client.send_reaction (uses correct TAGMSG format)
            target = self._display_name(self.active_buffer)
            self.client.send_reaction(target, event.emoji, event.msgid)
            
            # Re-render to show reaction immediately
            self._render_active_buffer()

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
        _dbg(f"_render_active_buffer START buffer={self.active_buffer}")
        
        # Guard: Screen must exist and be mounted.
        if not self.screen or not self.screen.is_mounted:
            _dbg(f"  ABORT: screen not ready")
            return
        
        # Guard: #messages must exist (compose must have finished for MessagesPanel).
        # This is only needed during startup - once app is running, #messages always exists.
        if not self.screen.query("#messages"):
            _dbg(f"  ABORT: #messages not found")
            return
        
        active_name = self._display_name(self.active_buffer)
        topic = self.channel_topics.get(self.active_buffer, "").strip()
        self.title = f"freeq - {active_name}" if not topic else f"freeq - {active_name} | {topic}"
        
        # Get the messages widget (could be ScrollableLog or SlottedMessageList)
        try:
            log = self.query_one("#messages", ScrollableLog)
            is_slotted = False
            _dbg(f"  using ScrollableLog (legacy mode)")
        except Exception as e1:
            try:
                log = self.query_one("#messages", SlottedMessageList)
                is_slotted = True
                _dbg(f"  using SlottedMessageList (slot mode)")
            except Exception as e2:
                _dbg(f"  ERROR: No messages widget found. ScrollableLog error: {e1}, SlottedMessageList error: {e2}")
                return  # No messages widget found
        
        if is_slotted:
            # SlottedMessageList path - each message is a widget with a slot
            self._render_active_buffer_slotted(log)
        else:
            # Legacy ScrollableLog path
            self._render_active_buffer_scrollable(log)
        
        _dbg(f"_render_active_buffer END")

    def _render_active_buffer_scrollable(self, log: ScrollableLog) -> None:
        """Render buffer content using legacy ScrollableLog (text-based)."""
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
        self._apply_scroll_mode(log)

    def _render_active_buffer_slotted(self, log: SlottedMessageList) -> None:
        """Render buffer content using SlottedMessageList (widget-based).
        
        Each message becomes a MessageItem widget with a slot below it.
        """
        from .widgets import check_render_pipeline, check_widget_state, log_operation
        
        with log_operation("render_slotted", buffer=self.active_buffer):
            check_widget_state(log, "render")
            
            log.clear()
            width = log.size.width or self.screen.size.width - 20 or 80
            
            render_lines, render_roots, render_msgids = self._renderable_lines(self.active_buffer, width)
            
            # Proactive validation of render pipeline
            check_render_pipeline(
                buffer_key=self.active_buffer,
                raw_line_count=len(self.messages.get(self.active_buffer, [])),
                rendered_line_count=len(render_lines),
                width=width,
            )
            
            # Create MessageItem widgets for each rendered line
            from rich.text import Text
            count = 0
            for line, thread_root, msgid in zip(render_lines, render_roots, render_msgids):
                if isinstance(line, str):
                    content = Text(line)
                else:
                    content = line
                log.write(content, msgid=msgid, thread_root=thread_root)
                count += 1
        
        _dbg(f"render slotted buffer={self.active_buffer} wrote={count} items")
        self._apply_scroll_mode(log)
        _dbg(f"_render_active_buffer_slotted END")

    def _apply_scroll_mode(self, log) -> None:
        """Apply scroll mode to log (works with both ScrollableLog and SlottedMessageList)."""
        _dbg(f"_apply_scroll_mode: mode={self._scroll_mode}")
        # Handle scroll positioning
        # - end: new live message, scroll to bottom
        # - home: history loaded, scroll to top to show new old messages
        # - message: open thread, scroll to the thread root message
        # - preserve: switch channel, keep current scroll position
        if self._scroll_mode == "end":
            log.scroll_end(animate=False)
            _dbg(f"  scrolled to end")
        elif self._scroll_mode == "home":
            log.scroll_home(animate=False)
            _dbg(f"  scrolled to home")
        elif self._scroll_mode == "message":
            # Scroll to a specific message (used when opening thread)
            _dbg(f"scroll mode=message, target={self._scroll_target_msgid[:8] if self._scroll_target_msgid else 'empty'}")
            if self._scroll_target_msgid:
                target = self._scroll_target_msgid
                self._scroll_target_msgid = ""
                self.call_later(lambda: self._scroll_to_message(target))
        else:
            _dbg(f"  no scroll (preserve/other)")

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
        """Persist joined channels to session and UI config.
        
        Channels are saved to both locations:
        - Session: for auth restore (only if authenticated)
        - UI config: always saved, works for guest users too
        """
        channels = self._session_channels()
        
        # Always save to UI config (works for guest users)
        if self.config_path:
            self.ui_config["channels"] = channels
            self._save_ui_config()
        
        # Also save to session if authenticated
        if self.cached_auth:
            self._write_session({
                **self.cached_auth,
                "channels": channels,
            })

    def _clear_saved_session(self) -> None:
        self.cached_auth = None
        if self.session_path and self.session_path.exists():
            self.session_path.unlink()

    def _save_ui_config(self) -> None:
        if self.config_path is None:
            return
        payload = {
            "theme": self.theme,
            "last_buffer": self.active_buffer,
        }
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
        self.config_path.write_text(json.dumps(payload))
        self.ui_config = payload

    def action_toggle_dark(self) -> None:
        super().action_toggle_dark()
        self._save_ui_config()

    def watch_theme(self, theme: str) -> None:
        if self._theme_ready:
            self._save_ui_config()

    def watch_active_buffer(self, buffer: str) -> None:
        """Save config when active buffer changes."""
        if self._theme_ready:  # App is fully initialized
            self._save_ui_config()

    def _restore_last_buffer(self) -> None:
        """Restore the last visited buffer from config, if it exists."""
        last_buffer = self.ui_config.get("last_buffer", "")
        if not last_buffer or last_buffer == "status":
            return
        key = self._buffer_key(last_buffer)
        if key in self.messages:
            _dbg(f"Restoring last buffer: {last_buffer}")
            self.active_buffer = key
            self._scroll_mode = "end"
            self._render_active_buffer()
            self._refresh_sidebar()
            self._refresh_user_list()
        else:
            _dbg(f"Last buffer {last_buffer} not available, staying on status")

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
            self._refresh_user_list()
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
                self._refresh_user_list()  # Show user list for new channel
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
                if self.active_buffer == key:
                    self._refresh_user_list()  # Update user list for current channel
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
            
            # Debug: Check spans in batch lines
            for i, (ts, line) in enumerate(batch.lines[:5]):
                if isinstance(line, Text):
                    _dbg(f"batch.line[{i}]: {len(line.spans)} spans, plain={line.plain[:50]!r}")
            
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
                
                # Check if this was scroll-triggered (has spinner) vs initial join
                had_spinner = bool(list(self.query(InlineSpinner)))
                
                # Remove the inline spinner if present (scroll-triggered history)
                # For initial history on join, there's no spinner - the loading overlay handles that
                for spinner in self.query(InlineSpinner):
                    spinner.remove()
                
                self._check_loading_complete()
                
                # Scroll behavior:
                # - Initial join (no spinner): scroll to end (latest messages)
                # - Scroll-triggered (had spinner): scroll to home (top) to show loaded history
                self.active_buffer = key
                self._scroll_mode = "home" if had_spinner else "end"
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
            nick_key = self._nick_key(event["nick"])
            self.channel_members[key].discard(nick_key)
            self.channel_ops[key].discard(nick_key)
            self.channel_voice[key].discard(nick_key)
            if self.active_buffer == key:
                self._refresh_user_list()  # Update user list after part
            if event["nick"].casefold() == self.client.nick.casefold():
                # We left the channel - clear all state for it
                if self.active_buffer == key:
                    self.active_buffer = "status"
                    self._scroll_mode = "end"
                    self._refresh_user_list()  # Clear user list when leaving channel
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
        if event_type == "mode_changed":
            channel = event.get("channel", "")
            mode = event.get("mode", "")
            arg = event.get("arg", "")
            set_by = event.get("set_by", "")
            key = self._buffer_key(channel)
            
            if mode == "+o" and arg:
                self.channel_ops[key].add(self._nick_key(arg))
                self._append_line(channel, self._format_system(f"{set_by} gave operator status to {arg}", "green"))
                if self.active_buffer == key:
                    self._refresh_user_list()
            elif mode == "-o" and arg:
                self.channel_ops[key].discard(self._nick_key(arg))
                self._append_line(channel, self._format_system(f"{set_by} removed operator status from {arg}", "yellow"))
                if self.active_buffer == key:
                    self._refresh_user_list()
            elif mode == "+v" and arg:
                self.channel_voice[key].add(self._nick_key(arg))
                if self.active_buffer == key:
                    self._refresh_user_list()
            elif mode == "-v" and arg:
                self.channel_voice[key].discard(self._nick_key(arg))
                if self.active_buffer == key:
                    self._refresh_user_list()
            return
        if event_type == "message":
            target = event["target"]
            sender = event["from"]
            # Convert literal \\n to actual newlines in message text
            text = event["text"].replace("\\n", "\n")
            tags = event.get("tags", {})
            
            # Check if this is an edit of an existing message
            edit_of = tags.get("+draft/edit")
            if edit_of and edit_of in self.message_index:
                # This is an edit - update the message and re-render, don't append new line
                buffer_name = self._message_buffer_name(target, sender)
                _dbg(f"Edit received for {edit_of[:8]}, updating and re-rendering")
                self._record_message(buffer_name, sender, text, tags)
                # Trigger re-render to show updated message with diff colors
                self._scroll_mode = "end" if self.active_buffer == self._buffer_key(buffer_name) else "preserve"
                self._render_active_buffer()
                return
            
            # Debug: log all tags for reply messages
            reply_tag = tags.get("+draft/reply") or tags.get("+reply")
            if reply_tag:
                _dbg(f"RAW MESSAGE TAGS: {dict(tags)}")
            self._ensure_avatar_lookup(sender)
            buffer_name = self._message_buffer_name(target, sender)
            buffer_key = self._buffer_key(buffer_name)
            self._record_message(buffer_name, sender, text, tags)
            
            # Parse reactions from +freeq.at/reactions tag
            msgid = tags.get("msgid", "")
            if msgid and "+freeq.at/reactions" in tags:
                reactions_str = tags["+freeq.at/reactions"]
                _dbg(f"  parsing +freeq.at/reactions for {msgid[:8]}: {reactions_str[:50]}")
                # Format: "sender:emoji,sender:emoji,..."
                for reaction in reactions_str.split(","):
                    if ":" in reaction:
                        r_sender, r_emoji = reaction.split(":", 1)
                        # Avoid duplicates
                        if (r_sender, r_emoji) not in self._reactions[msgid]:
                            self._reactions[msgid].append((r_sender, r_emoji))
                            _dbg(f"    loaded reaction: {r_sender} -> {r_emoji}")
                        else:
                            _dbg(f"    skipped duplicate reaction: {r_sender} -> {r_emoji}")
            
            reply_to = self._thread_reply_to(tags)
            thread_root = ""
            if reply_to:
                parent = self.message_index.get(reply_to)
                if parent:
                    thread_root = parent.thread_root
                else:
                    thread_root = reply_to
            # Single debug log per message
            batch_id = tags.get("batch")
            has_parent = reply_to in self.message_index if reply_to else False
            in_batch = batch_id in self.batches if batch_id else False
            _dbg(f"Message: from={sender} reply_to={reply_to[:8] if reply_to else None} parent_ok={has_parent} batch={in_batch}")
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
                # Extract mime type and streaming flag for proper rendering
                mime_type = tags.get("+freeq.at/mime", "")
                is_streaming = tags.get("+freeq.at/streaming") == "1"
                
                self.batches[batch_id].lines.append(
                    (tags.get("time", ""), self._format_message(sender, text, mime_type=mime_type, is_streaming=is_streaming))
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
                    indicator = self._format_reply_indicator(parent_sender, parent_snip, thread_root)
                    _dbg(f"Adding reply stub for {msgid[:8] if msgid else None}: reply_to={reply_to[:8]}, indicator_len={len(indicator.plain)}")
                    self._append_line(
                        buffer_name,
                        indicator,
                        mark_unread=False,
                        thread_root=thread_root,
                        msgid="",
                        line_meta=None,
                    )
                else:
                    _dbg(f"No reply stub for {msgid[:8] if msgid else None}: reply_to={reply_to[:8] if reply_to else None}, thread_root={thread_root[:8] if thread_root else None}")
                
                # Extract mime type and streaming flag for proper rendering
                mime_type = tags.get("+freeq.at/mime", "")
                is_streaming = tags.get("+freeq.at/streaming") == "1"
                
                self._append_line(
                    buffer_name,
                    self._format_message(sender, text, mime_type=mime_type, is_streaming=is_streaming),
                    msgid=msgid,
                    line_meta=(sender, text, tags.get("time", "")),
                    thread_root=thread_root,
                )
            return
        if event_type == "topic_changed":
            channel = event["channel"]
            # Convert literal \\n to actual newlines in topic
            topic = event["topic"].replace("\\n", "\n")
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
            # Convert literal \\n to actual newlines in notice text
            notice_text = event["text"].replace("\\n", "\n")
            notice = Text()
            notice.append("notice: ", style="magenta")
            notice.append(notice_text)
            self._append_line("status", notice, mark_unread=False)
            return
        if event_type == "tagmsg":
            # TAGMSG with tags - check for +react (emoji reaction)
            tags = event.get("tags", {})
            _dbg(f"TAGMSG received from={event.get('from')} target={event.get('target')} tags={list(tags.keys())}")
            if "+react" in tags:
                sender = event["from"]
                target = event["target"]
                emoji = tags["+react"]
                # Get the msgid being reacted to (web client uses +reply)
                target_msgid = tags.get("+reply") or tags.get("+draft/reply")
                _dbg(f"  +react found: emoji={emoji} target_msgid={target_msgid[:8] if target_msgid else None}")
                if target_msgid:
                    # Store reaction on the message (avoid duplicates)
                    reaction_key = (sender, emoji)
                    existing = self._reactions[target_msgid]
                    if reaction_key not in existing:
                        self._reactions[target_msgid].append((sender, emoji))
                        _dbg(f"  reaction stored: {sender} reacted {emoji} on {target_msgid[:8]}")
                    else:
                        _dbg(f"  reaction already exists, skipping duplicate")
                    # Re-render to show reaction on message
                    self._render_active_buffer()
                else:
                    # No target msgid, show as system message
                    buffer_name = self._message_buffer_name(target, sender)
                    self._append_line(
                        buffer_name,
                        Text(f"{sender} reacted with {emoji}", style="dim"),
                        mark_unread=True,
                    )
            return
        if event_type == "disconnected":
            self.channel_members.clear()
            self.channel_ops.clear()
            self.channel_voice.clear()
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
        """Send a reply using @+reply IRCv3 tag via raw IRC."""
        _dbg(f"_send_reply(target={target!r}, msgid={reply_to_msgid[:8]!r}, text={text[:20]!r})")
        self.client.raw(f"@+reply={reply_to_msgid} PRIVMSG {target} :{text}")

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
        
        # Send message - ReplyPanel handles its own replies via ReplySent message
        # Main composer sends normal messages (no global state needed!)
        self.client.send_message(self._display_name(target), text)

    # ── Sidebar ────────────────────────────────────────────────────────────

    @on(ListView.Selected, "#sidebar")
    def handle_sidebar_select(self, event: ListView.Selected) -> None:
        from .widgets import log_operation, set_context, log_state_snapshot
        
        _dbg(f"handle_sidebar_select(item={event.item.name!r})")
        if event.item.name is None:
            return
        
        # Set correlation context for this user operation
        set_context("user_operation", "channel_switch")
        set_context("from_buffer", self.active_buffer)
        set_context("to_buffer", event.item.name)
        
        with log_operation("channel_switch", 
                          from_buffer=self.active_buffer,
                          to_buffer=event.item.name):
            
            log_state_snapshot(self, "pre_switch")
            
            self.active_buffer = self._buffer_key(event.item.name)
            self.open_thread_root = ""
            
            # Swap back to MessagesPanel if thread panel was open
            if self._thread_panel_is_open():
                self._close_thread()
            
            self._scroll_mode = "end"
            self._render_active_buffer()
            self._refresh_user_list()
            self.query_one("#composer", Input).focus()
            
            log_state_snapshot(self, "post_switch")

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
