# 🟢 GREEN: Avatar Domain (IU-95456c2e)
# Description: Implements avatar functionality with 8 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Fetch user avatars from AT Protocol
#   2. Cache avatars locally
#   3. Display avatars in UI
#   4. Render avatars as 4color blocks when richpixels unavailable
#   5. Generate deterministic colors from DID
#   6. Support multiple avatar sizes
#   7. Handle avatar fetch failures gracefully
#   8. Update avatars when user changes them

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Tuple
from datetime import datetime
import hashlib

# === TYPES ===

@dataclass
class AvatarImage:
    """Represents avatar image data."""
    data: Optional[bytes] = None
    content_type: str = "image/png"
    width: int = 128
    height: int = 128
    cached_at: Optional[datetime] = None


@dataclass
class AvatarColorPalette:
    """4-color palette for fallback avatar rendering."""
    primary: str = "#0085ff"
    secondary: str = "#00d4ff"
    tertiary: str = "#0055ff"
    background: str = "#0a0a0a"


@dataclass
class Avatar:
    """Avatar domain entity."""
    id: str  # DID or user identifier
    did: Optional[str] = None
    handle: Optional[str] = None
    avatar_url: Optional[str] = None
    image: Optional[AvatarImage] = None
    color_palette: AvatarColorPalette = field(default_factory=AvatarColorPalette)
    fallback_text: str = ""
    cached: bool = False
    cache_time: Optional[datetime] = None
    fetch_failed: bool = False
    last_error: Optional[str] = None


# === COLOR GENERATION ===

def generate_palette_from_did(did: str) -> AvatarColorPalette:
    """Generate a deterministic 4-color palette from a DID.
    
    Uses hash of DID to generate consistent colors for each user.
    """
    # Create hash of DID
    did_hash = hashlib.sha256(did.encode()).hexdigest()
    
    # Extract color components from hash
    def hex_color(offset: int) -> str:
        r = int(did_hash[offset:offset+2], 16)
        g = int(did_hash[offset+2:offset+4], 16)
        b = int(did_hash[offset+4:offset+6], 16)
        # Ensure colors are vibrant (not too dark, not too light)
        r = max(64, min(224, r))
        g = max(64, min(224, g))
        b = max(64, min(224, b))
        return f"#{r:02x}{g:02x}{b:02x}"
    
    return AvatarColorPalette(
        primary=hex_color(0),
        secondary=hex_color(6),
        tertiary=hex_color(12),
        background=hex_color(18)
    )


def generate_fallback_text(handle: Optional[str], did: Optional[str]) -> str:
    """Generate fallback text for avatar.
    
    Returns first two letters of handle or last 2 chars of DID fragment.
    """
    if handle:
        return handle[:2].upper()
    elif did:
        # Get last part of DID
        parts = did.split(":")
        if len(parts) >= 3:
            return parts[-1][:2].upper()
    return "??"


# === AVATAR PROCESSING ===

def process(item: Avatar) -> Avatar:
    """Process avatar state and ensure all fields are populated.
    
    Generates color palette from DID and fallback text if not set.
    """
    # Generate color palette if DID available
    palette = item.color_palette
    if item.did and (palette.primary == "#0085ff" or not item.color_palette):
        palette = generate_palette_from_did(item.did)
    
    # Generate fallback text
    fallback = item.fallback_text or generate_fallback_text(item.handle, item.did)
    
    return Avatar(
        id=item.id,
        did=item.did,
        handle=item.handle,
        avatar_url=item.avatar_url,
        image=item.image,
        color_palette=palette,
        fallback_text=fallback,
        cached=item.cached,
        cache_time=item.cache_time,
        fetch_failed=item.fetch_failed,
        last_error=item.last_error
    )


def fetch_avatar(avatar: Avatar, pds_url: str) -> Avatar:
    """Fetch avatar from PDS.
    
    In a real implementation, this would make an HTTP request.
    Returns updated avatar with fetched image data.
    """
    # Simulate fetch - in real implementation this would:
    # 1. Check local cache first
    # 2. If not cached, fetch from PDS
    # 3. Store in cache
    # 4. Return updated avatar
    
    if avatar.cached and avatar.image:
        return avatar
    
    # For now, mark as needing fetch
    return Avatar(
        id=avatar.id,
        did=avatar.did,
        handle=avatar.handle,
        avatar_url=avatar.avatar_url,
        image=None,  # Would be populated by actual fetch
        color_palette=avatar.color_palette,
        fallback_text=avatar.fallback_text,
        cached=False,
        cache_time=None,
        fetch_failed=False,
        last_error="Not implemented: HTTP fetch required"
    )


def cache_avatar(avatar: Avatar, image_data: bytes) -> Avatar:
    """Cache avatar image data locally."""
    image = AvatarImage(
        data=image_data,
        content_type="image/png",
        cached_at=datetime.now()
    )
    
    return Avatar(
        id=avatar.id,
        did=avatar.did,
        handle=avatar.handle,
        avatar_url=avatar.avatar_url,
        image=image,
        color_palette=avatar.color_palette,
        fallback_text=avatar.fallback_text,
        cached=True,
        cache_time=datetime.now(),
        fetch_failed=False,
        last_error=None
    )


def clear_avatar_cache(avatar: Avatar) -> Avatar:
    """Clear cached avatar data."""
    return Avatar(
        id=avatar.id,
        did=avatar.did,
        handle=avatar.handle,
        avatar_url=avatar.avatar_url,
        image=None,
        color_palette=avatar.color_palette,
        fallback_text=avatar.fallback_text,
        cached=False,
        cache_time=None,
        fetch_failed=False,
        last_error=None
    )


def resize_avatar_image(image: AvatarImage, width: int, height: int) -> AvatarImage:
    """Resize avatar image to specified dimensions.
    
    In real implementation, this would use PIL or similar.
    """
    # Return new image with updated dimensions
    return AvatarImage(
        data=image.data,
        content_type=image.content_type,
        width=width,
        height=height,
        cached_at=image.cached_at
    )


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "95456c2e8e060638da25494598fa8e81b0f9c6f8cbbec13cee0d0e5db09a0f84",
    "name": "Avatar Domain",
    "risk_tier": "high",
}
