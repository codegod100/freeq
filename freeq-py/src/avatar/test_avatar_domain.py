# 🟢 GREEN: Tests for Avatar Domain (IU-95456c2e)
# Risk Tier: HIGH

import pytest
from avatar_domain import (
    _phoenix, Avatar, AvatarImage, AvatarColorPalette, process,
    generate_palette_from_did, generate_fallback_text, cache_avatar,
    clear_avatar_cache, resize_avatar_image
)

# 🟢 GREEN: Traceability (always passes)
def test_traceability():
    assert _phoenix is not None
    assert _phoenix["iu_id"] == "95456c2e8e060638da25494598fa8e81b0f9c6f8cbbec13cee0d0e5db09a0f84"


# 🟢 GREEN: Color palette generation tests
def test_generate_palette_from_did():
    """Test deterministic palette generation from DID."""
    did = "did:plc:alice123"
    palette1 = generate_palette_from_did(did)
    palette2 = generate_palette_from_did(did)
    
    # Same DID should produce same palette
    assert palette1 == palette2
    assert palette1.primary.startswith("#")
    assert len(palette1.primary) == 7


def test_generate_palette_different_dids():
    """Test that different DIDs produce different palettes."""
    palette1 = generate_palette_from_did("did:plc:user1")
    palette2 = generate_palette_from_did("did:plc:user2")
    
    assert palette1.primary != palette2.primary


def test_palette_colors_are_vibrant():
    """Test that generated colors are in vibrant range."""
    did = "did:plc:test"
    palette = generate_palette_from_did(did)
    
    # Parse primary color
    r = int(palette.primary[1:3], 16)
    g = int(palette.primary[3:5], 16)
    b = int(palette.primary[5:7], 16)
    
    # Colors should be between 64 and 224
    assert 64 <= r <= 224
    assert 64 <= g <= 224
    assert 64 <= b <= 224


# 🟢 GREEN: Fallback text generation tests
def test_generate_fallback_text_from_handle():
    """Test generating fallback text from handle."""
    text = generate_fallback_text("@alice.bsky.social", None)
    assert text == "@A"


def test_generate_fallback_text_from_did():
    """Test generating fallback text from DID."""
    text = generate_fallback_text(None, "did:plc:xyz123")
    assert text == "XY"


def test_generate_fallback_text_empty():
    """Test fallback when both handle and DID are None."""
    text = generate_fallback_text(None, None)
    assert text == "??"


# 🟢 GREEN: Process function tests
def test_process_generates_palette():
    """Test that process generates color palette from DID."""
    avatar = Avatar(id="a1", did="did:plc:test123")
    result = process(avatar)
    
    assert result is not avatar
    assert result.color_palette.primary != "#0085ff"  # Should be generated
    assert len(result.color_palette.primary) == 7


def test_process_generates_fallback_text():
    """Test that process generates fallback text."""
    avatar = Avatar(id="a1", handle="@alice", did="did:plc:alice")
    result = process(avatar)
    
    assert result.fallback_text == "@A"


def test_process_preserves_existing_palette():
    """Test that process preserves manually set palette."""
    custom_palette = AvatarColorPalette(
        primary="#ff0000",
        secondary="#00ff00",
        tertiary="#0000ff",
        background="#ffffff"
    )
    avatar = Avatar(id="a1", did="did:plc:test", color_palette=custom_palette)
    result = process(avatar)
    
    # Should keep custom palette
    assert result.color_palette.primary == "#ff0000"


# 🟢 GREEN: Cache operations tests
def test_cache_avatar():
    """Test caching avatar image data."""
    avatar = Avatar(id="a1", did="did:plc:test")
    image_data = b"fake_image_data"
    
    result = cache_avatar(avatar, image_data)
    
    assert result.cached is True
    assert result.cache_time is not None
    assert result.image is not None
    assert result.image.data == image_data
    assert result.image.cached_at is not None


def test_clear_avatar_cache():
    """Test clearing avatar cache."""
    cached_avatar = Avatar(
        id="a1",
        did="did:plc:test",
        cached=True,
        cache_time=__import__('datetime').datetime.now(),
        image=AvatarImage(data=b"test")
    )
    
    result = clear_avatar_cache(cached_avatar)
    
    assert result.cached is False
    assert result.cache_time is None
    assert result.image is None


# 🟢 GREEN: Image operations tests
def test_resize_avatar_image():
    """Test resizing avatar image."""
    image = AvatarImage(
        data=b"test",
        width=128,
        height=128,
        content_type="image/png"
    )
    
    resized = resize_avatar_image(image, 64, 64)
    
    assert resized.width == 64
    assert resized.height == 64
    assert resized.data == image.data  # Data preserved
    assert resized.content_type == image.content_type


def test_process_transforms_input():
    """Ensure process creates new object (backwards compatibility)."""
    input_item = Avatar(id="123", did="did:plc:test")
    result = process(input_item)
    assert result is not input_item  # Should be new object
    assert result.fallback_text != ""  # Should have generated fallback
