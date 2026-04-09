# Avatar Fetching Domain Specification

## Part 1: Abstract System Design

### Domain Model

```
Entity Avatar:
  nick: String (IRC nickname)
  handle: String (AT Protocol handle, e.g., user.bsky.social)
  image_data: Bytes | None
  dominant_colors: List[Color] (4-color palette)
  source: Enum {FETCHED, GENERATED, DEFAULT}
  last_updated: DateTime

Entity AvatarCache:
  entries: Map[Nick, Avatar]
  max_size: Int
  ttl: Duration

Entity TerminalCapabilities:
  truecolor: Bool
  rich_pixels: Bool  # WezTerm-style image support
  color_mode: Enum {TRUECOLOR, ANSI256, ANSI16}
```

### Avatar Resolution Flow

```
Flow AvatarResolution:
  trigger: New message from unknown user
  steps:
    1. Check cache for existing avatar
    2. If cache miss:
       a. Send WHOIS query for AT Protocol handle
       b. Fetch avatar from Bluesky API
       c. Extract dominant colors
       d. Cache result
    3. Return avatar for rendering
```

### Color Generation Strategy

```
Strategy DeterministicPalette:
  input: Nick (if no handle/avatar available)
  output: 4-color palette
  algorithm:
    - Hash nick to generate HSL values
    - Generate complementary colors for variety
    - Ensure perceptual distinctness

Strategy ImageExtraction:
  input: Avatar image
  output: 4-color palette
  algorithm:
    - Resize to 4x4 grid
    - Extract dominant colors via k-means or median cut
    - Sort by perceptual brightness
```

---

## Part 2: Implementation Guidance (Python/Textual)

### WHOIS Integration

```python
class AvatarResolver:
    """Resolve avatars via WHOIS and Bluesky API."""
    
    def __init__(self, irc_client, cache: AvatarCache):
        self.irc = irc_client
        self.cache = cache
        self._pending_whois: Set[str] = set()
    
    def resolve(self, nick: str) -> Avatar:
        """Resolve avatar for nickname."""
        # Check cache first
        if avatar := self.cache.get(nick):
            return avatar
        
        # Avoid duplicate WHOIS
        if nick in self._pending_whois:
            return self._generate_placeholder(nick)
        
        # Send WHOIS to get AT Protocol handle
        self._pending_whois.add(nick)
        self.irc.send_whois(nick)
        
        return self._generate_placeholder(nick)
    
    def on_whois_reply(self, nick: str, realname: str):
        """Handle WHOIS reply with AT Protocol handle."""
        self._pending_whois.discard(nick)
        
        # Parse handle from realname (e.g., "user.bsky.social")
        if handle := self._extract_handle(realname):
            # Fetch avatar in background
            threading.Thread(
                target=self._fetch_and_cache,
                args=(nick, handle),
                daemon=True
            ).start()
    
    def _extract_handle(self, realname: str) -> str | None:
        """Extract AT Protocol handle from WHOIS realname."""
        # Pattern: something.bsky.social or did:plc:...
        if ".bsky.social" in realname or realname.startswith("did:plc:"):
            return realname.split()[0]  # First word
        return None
    
    def _fetch_and_cache(self, nick: str, handle: str):
        """Fetch avatar from Bluesky and cache."""
        try:
            avatar = self._fetch_from_bluesky(handle)
            self.cache.set(nick, avatar)
            
            # Notify UI to refresh
            self.app.call_from_thread(
                lambda: self.app.post_message(AvatarUpdated(nick))
            )
        except Exception as e:
            logger.error(f"Avatar fetch failed for {nick}: {e}")
```

### Bluesky API Integration

```python
class BlueskyAPI:
    """Fetch avatar data from Bluesky/AT Protocol."""
    
    BASE_URL = "https://api.bsky.app"
    
    def fetch_avatar(self, handle: str) -> Avatar:
        """Fetch avatar for handle."""
        # Resolve handle to DID
        did = self._resolve_handle(handle)
        
        # Fetch profile
        profile = self._get_profile(did)
        
        # Download avatar image
        if avatar_url := profile.get("avatar"):
            image_data = self._download_image(avatar_url)
            colors = self._extract_colors(image_data)
            
            return Avatar(
                nick=handle,
                handle=handle,
                image_data=image_data,
                dominant_colors=colors,
                source=AvatarSource.FETCHED,
                last_updated=datetime.now(),
            )
        
        # No avatar - generate from handle
        return self._generate_from_handle(handle)
    
    def _resolve_handle(self, handle: str) -> str:
        """Resolve handle to DID via identity API."""
        url = f"{self.BASE_URL}/xrpc/com.atproto.identity.resolveHandle"
        resp = requests.get(url, params={"handle": handle})
        return resp.json()["did"]
    
    def _get_profile(self, did: str) -> dict:
        """Get user profile."""
        url = f"{self.BASE_URL}/xrpc/app.bsky.actor.getProfile"
        resp = requests.get(url, params={"actor": did})
        return resp.json()
    
    def _download_image(self, url: str) -> bytes:
        """Download image data."""
        resp = requests.get(url, timeout=30)
        return resp.content
    
    def _extract_colors(self, image_data: bytes) -> List[Tuple[int, int, int]]:
        """Extract 4 dominant colors from image."""
        from PIL import Image
        import io
        
        img = Image.open(io.BytesIO(image_data))
        img = img.convert("RGB")
        img = img.resize((4, 4))  # Reduce to 4x4
        
        # Get colors
        colors = []
        for y in range(4):
            for x in range(4):
                colors.append(img.getpixel((x, y)))
        
        # Deduplicate and limit to 4
        unique = list(set(colors))[:4]
        return unique
```

### Terminal Capability Detection

```python
class TerminalCapabilities:
    """Detect terminal rendering capabilities."""
    
    @classmethod
    def detect(cls) -> TerminalCapabilities:
        """Auto-detect terminal capabilities."""
        env = os.environ
        
        # Check for WezTerm rich pixels
        rich_pixels = env.get("TERM_PROGRAM") == "WezTerm"
        
        # Check color support
        term = env.get("TERM", "")
        colorterm = env.get("COLORTERM", "")
        
        if "truecolor" in colorterm or "24bit" in colorterm:
            color_mode = ColorMode.TRUECOLOR
        elif "256" in term:
            color_mode = ColorMode.ANSI256
        else:
            color_mode = ColorMode.ANSI16
        
        # Environment override
        if env.get("FREEQ_AVATARS") == "0":
            rich_pixels = False
        elif env.get("FREEQ_AVATARS") == "1":
            rich_pixels = True
        
        return cls(
            truecolor=color_mode == ColorMode.TRUECOLOR,
            rich_pixels=rich_pixels,
            color_mode=color_mode,
        )
```

### Avatar Rendering

```python
class AvatarRenderer:
    """Render avatars based on terminal capabilities."""
    
    def __init__(self, capabilities: TerminalCapabilities):
        self.caps = capabilities
    
    def render(self, avatar: Avatar, size: int = 2) -> RenderableType:
        """Render avatar for terminal."""
        if self.caps.rich_pixels and avatar.image_data:
            return self._render_rich_pixels(avatar.image_data, size)
        
        if avatar.dominant_colors:
            return self._render_color_blocks(avatar.dominant_colors, size)
        
        return self._render_placeholder(avatar.nick, size)
    
    def _render_color_blocks(
        self, colors: List[Tuple[int, int, int]], size: int
    ) -> RenderableType:
        """Render as 4-color Unicode blocks."""
        from rich.text import Text
        
        text = Text()
        for i, (r, g, b) in enumerate(colors[:4]):
            color = f"#{r:02x}{g:02x}{b:02x}"
            text.append("██", style=f"{color} on {color}")
            if i % 2 == 1:
                text.append("\n")
        
        return text
    
    def _render_rich_pixels(self, image_data: bytes, size: int) -> str:
        """Render using WezTerm rich pixels protocol."""
        # WezTerm iTerm2 image protocol
        import base64
        
        b64 = base64.b64encode(image_data).decode()
        
        # OSC 1337 ; File=... : base64 data ST
        return f"\x1b]1337;File=inline=1;width={size};height={size}:{b64}\x07"
    
    def _render_placeholder(self, nick: str, size: int) -> Text:
        """Render text placeholder (first letter)."""
        from rich.text import Text
        
        bg, fg = generate_avatar_palette(nick)
        return Text(
            nick[0].upper(),
            style=f"{fg} on {bg} bold"
        )
```

### Avatar Cache

```python
class AvatarCache:
    """LRU cache for avatar data."""
    
    def __init__(self, max_size: int = 1000, ttl: timedelta = timedelta(hours=24)):
        self.max_size = max_size
        self.ttl = ttl
        self._cache: OrderedDict[str, Tuple[Avatar, datetime]] = OrderedDict()
    
    def get(self, nick: str) -> Avatar | None:
        """Get avatar from cache if not expired."""
        if nick not in self._cache:
            return None
        
        avatar, timestamp = self._cache[nick]
        
        if datetime.now() - timestamp > self.ttl:
            del self._cache[nick]
            return None
        
        # Move to end (LRU)
        self._cache.move_to_end(nick)
        return avatar
    
    def set(self, nick: str, avatar: Avatar):
        """Add avatar to cache."""
        self._cache[nick] = (avatar, datetime.now())
        self._cache.move_to_end(nick)
        
        # Evict oldest if over capacity
        if len(self._cache) > self.max_size:
            self._cache.popitem(last=False)
```

### Avatar Events

```python
class AvatarUpdated(Message):
    """Avatar data updated for user."""
    def __init__(self, nick: str):
        super().__init__()
        self.nick = nick


class FreeQApp(App):
    def on_avatar_updated(self, event: AvatarUpdated) -> None:
        """Refresh message widgets for updated avatar."""
        for widget in self.query(MessageWidget):
            if widget.message.sender == event.nick:
                widget.refresh()
```
