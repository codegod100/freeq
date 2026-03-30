"""Message formatting for freeq-textual."""

import hashlib
import re
from rich.text import Text

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


def nick_color(nick: str) -> str:
    """Deterministic color for a nick based on hash."""
    digest = hashlib.md5(nick.encode()).hexdigest()
    idx = int(digest, 16) % len(_NICK_PALETTE)
    return _NICK_PALETTE[idx]


def format_nick(nick: str) -> Text:
    """Colorized nick."""
    return Text(nick, style=nick_color(nick))


# ── URL detection ───────────────────────────────────────────────────────────

_URL_RE = re.compile(r"(?P<url>(?:https?|wss?)://[^\s<>()]+)")


def short_url(url: str, limit: int = 36) -> str:
    """Truncate URL for display."""
    parsed = __import__("urllib.parse").urlparse(url)
    display = parsed.netloc + parsed.path
    if parsed.query:
        display += "?"
    if not display:
        display = url
    if len(display) <= limit:
        return display
    return display[: limit - 3].rstrip() + "..."


# ── Avatar colors ──────────────────────────────────────────────────────────

def avatar_palette(nick: str) -> list[str]:
    """Generate 4 deterministic colors for a 4x2 avatar."""
    digest = hashlib.md5(nick.encode()).digest()
    colors: list[str] = []
    for offset in range(0, 12, 3):
        red = 48 + digest[offset] % 160
        green = 48 + digest[offset + 1] % 160
        blue = 48 + digest[offset + 2] % 160
        colors.append(f"#{red:02x}{green:02x}{blue:02x}")
    return colors


# ── Message formatting ─────────────────────────────────────────────────────


def format_message_body(text: str, shortener=short_url) -> Text:
    """Format message body with clickable URLs."""
    body = Text(no_wrap=False, overflow="fold")
    last_end = 0
    for match in _URL_RE.finditer(text):
        start, end = match.span("url")
        if start > last_end:
            body.append(text[last_end:start])
        url = match.group("url")
        body.append(
            f"[link: {shortener(url)}]",
            style=f"underline cyan link {url}",
        )
        body.append(f" {shortener(url)}", style="dim")
        last_end = end
    if last_end < len(text):
        body.append(text[last_end:])
    return body


def format_header(nick: str, nick_color_func, avatar_rows_func=None, avatar_enabled: bool = False) -> Text:
    """Format avatar + nick header line."""
    name = Text(nick, style=f"bold {nick_color_func(nick)}")
    if not avatar_enabled:
        return name

    rows = avatar_rows_func(nick)
    line = Text()
    for color in rows[0]:
        line.append("\u2588", style=color)
    line.append(" ")
    line.append_text(name)
    return line


def format_avatar_row2(nick: str, avatar_rows_func=None, avatar_enabled: bool = False) -> Text | None:
    """Format second row of 4x2 avatar."""
    if not avatar_enabled:
        return None
    rows = avatar_rows_func(nick)
    line = Text()
    for color in rows[1]:
        line.append("\u2588", style=color)
    return line


def format_chat_block(
    nick: str,
    text: str,
    width: int,
    nick_color_func,
    format_body_func,
    avatar_rows_func=None,
    avatar_enabled: bool = False,
) -> list[Text]:
    """Return list of lines: header, avatar row2, then message lines with hanging indent."""
    lines: list[Text] = []

    # Header line (avatar row 1 + nick, or just nick)
    lines.append(format_header(nick, nick_color_func, avatar_rows_func, avatar_enabled))

    # Avatar row 2 (if enabled)
    if avatar_enabled and avatar_rows_func:
        row2 = format_avatar_row2(nick, avatar_rows_func, avatar_enabled)
        if row2:
            lines.append(row2)

    # Message lines with indent aligned to where text starts
    # Indent = 5 (avatar width) with avatar, 0 without
    indent = 5 if avatar_enabled else 0

    # Manually wrap to width - indent
    available = max(20, width - indent)
    words = text.split()
    current_line = ""
    for word in words:
        test_line = f"{current_line} {word}".strip()
        if len(test_line) <= available:
            current_line = test_line
        else:
            if current_line:
                lines.append(Text(" " * indent + current_line, no_wrap=False, overflow="fold"))
            current_line = word
    if current_line:
        lines.append(Text(" " * indent + current_line, no_wrap=False, overflow="fold"))

    return lines


def format_reply_indicator(parent_sender: str, snippet: str, thread_root: str, nick_color_func) -> Text:
    """Dim reply indicator: `  ↳ replying to <nick>: <snippet>`."""
    indicator = Text(no_wrap=False, overflow="fold")
    indicator.append("  \u21b3 ", style="dim")
    indicator.append("replying to ", style="dim italic")
    indicator.append(parent_sender, style=f"dim {nick_color_func(parent_sender)}")
    indicator.append(": ", style="dim")
    indicator.append(snippet, style="dim")
    return indicator


def format_system(text: str, style: str = "") -> Text:
    """System/status message with optional style."""
    return Text(text, style=style, no_wrap=False, overflow="fold")