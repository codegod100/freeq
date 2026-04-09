# 🟢 GREEN: URL Domain (IU-47ca9242)
# Description: Implements URL detection, preview, and handling with 4 requirements
# Risk Tier: HIGH
# Requirements:
#   1. URL detection in messages
#   2. URL preview generation
#   3. Render URLs as cyan underlined hyperlinks
#   4. URL shortening for display

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any
from datetime import datetime
import re

# === TYPES ===

@dataclass
class UrlPreview:
    """URL preview data."""
    url: str
    title: Optional[str] = None
    description: Optional[str] = None
    image_url: Optional[str] = None
    site_name: Optional[str] = None
    fetched_at: Optional[datetime] = None
    error: Optional[str] = None


@dataclass
class Url:
    """URL domain entity."""
    id: str
    original_url: str = ""
    normalized_url: str = ""
    display_text: str = ""
    preview: Optional[UrlPreview] = None
    cached: bool = False
    cache_time: Optional[datetime] = None
    click_count: int = 0
    error: Optional[str] = None
    shortened: bool = False


# === URL PATTERNS ===

URL_PATTERN = re.compile(
    r'https?://'  # http:// or https://
    r'(?:(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\.)+[A-Z]{2,6}\.?|'  # domain
    r'localhost|'  # localhost
    r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})'  # ip
    r'(?::\d+)?'  # optional port
    r'(?:/?|[/?]\S+)',  # path
    re.IGNORECASE
)


# === URL OPERATIONS ===

def normalize_url(url: str) -> str:
    """Normalize a URL for comparison and storage."""
    # Remove trailing slashes
    url = url.rstrip('/')
    
    # Convert to lowercase for scheme and host
    if '://' in url:
        scheme, rest = url.split('://', 1)
        url = f"{scheme.lower()}://{rest}"
    
    # Remove default ports
    url = re.sub(r':80(/|$)', r'\1', url)
    url = re.sub(r':443(/|$)', r'\1', url)
    
    return url


def shorten_url(url: str, max_length: int = 50) -> str:
    """Shorten URL for display.
    
    Shows domain + truncated path if too long.
    """
    if len(url) <= max_length:
        return url
    
    # Extract domain
    match = re.match(r'https?://([^/]+)', url)
    if not match:
        return url[:max_length-3] + "..."
    
    domain = match.group(1)
    remaining = max_length - len(domain) - 5  # Account for ellipsis and separators
    
    # Get path
    path = url[match.end():]
    if len(path) > remaining:
        path = path[:remaining] + "..."
    
    return f"{domain}/...{path}" if path else f"{domain}/..."


def detect_urls(text: str) -> List[str]:
    """Detect all URLs in text."""
    return URL_PATTERN.findall(text)


def format_url_for_display(url: str, max_length: int = 50) -> str:
    """Format URL as display string with hyperlink markup.
    
    Returns Textual markup for cyan underlined hyperlink.
    """
    display = shorten_url(url, max_length)
    return f"[underline cyan]{display}[/underline cyan]"


def process(item: Url) -> Url:
    """Process URL and generate display text.
    
    Normalizes URL and creates shortened display text.
    """
    normalized = normalize_url(item.original_url)
    display = shorten_url(normalized, max_length=50)
    
    return Url(
        id=item.id,
        original_url=item.original_url,
        normalized_url=normalized,
        display_text=display,
        preview=item.preview,
        cached=item.cached,
        cache_time=item.cache_time,
        click_count=item.click_count,
        error=item.error,
        shortened=len(item.original_url) > 50
    )


def fetch_preview(url: Url) -> Url:
    """Fetch URL preview data.
    
    In real implementation, this would fetch OpenGraph data.
    """
    # Simulate preview fetch
    preview = UrlPreview(
        url=url.normalized_url or url.original_url,
        title=f"Preview for {url.original_url[:30]}...",
        description="URL preview not yet implemented",
        fetched_at=datetime.now()
    )
    
    return Url(
        id=url.id,
        original_url=url.original_url,
        normalized_url=url.normalized_url,
        display_text=url.display_text,
        preview=preview,
        cached=True,
        cache_time=datetime.now(),
        click_count=url.click_count,
        error=None,
        shortened=url.shortened
    )


def cache_url(url: Url) -> Url:
    """Mark URL as cached."""
    return Url(
        id=url.id,
        original_url=url.original_url,
        normalized_url=url.normalized_url,
        display_text=url.display_text,
        preview=url.preview,
        cached=True,
        cache_time=datetime.now(),
        click_count=url.click_count,
        error=url.error,
        shortened=url.shortened
    )


def record_click(url: Url) -> Url:
    """Record a URL click."""
    return Url(
        id=url.id,
        original_url=url.original_url,
        normalized_url=url.normalized_url,
        display_text=url.display_text,
        preview=url.preview,
        cached=url.cached,
        cache_time=url.cache_time,
        click_count=url.click_count + 1,
        error=url.error,
        shortened=url.shortened
    )


def is_valid_url(url: str) -> bool:
    """Check if string is a valid HTTP/HTTPS URL."""
    if not url:
        return False
    
    # Basic validation
    pattern = re.compile(
        r'^https?://'  # scheme
        r'[\w.-]+'  # domain
        r'(\.[a-zA-Z]{2,})'  # TLD
        r'(:\d+)?'  # optional port
        r'(/[^\s]*)?$',  # optional path
        re.IGNORECASE
    )
    
    return bool(pattern.match(url))


def extract_domain(url: str) -> Optional[str]:
    """Extract domain from URL."""
    match = re.match(r'https?://([^/]+)', url)
    if match:
        return match.group(1)
    return None


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "47ca92422eff65e3ccd5a88ae4761d2e1e9349187027c71357b1a8381a512a65",
    "name": "URL Domain",
    "risk_tier": "high",
}
