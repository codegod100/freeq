# 🟢 GREEN: Emoji Domain (IU-8800ff3d)
# Description: Implements emoji picker, shortcodes, and rendering with 7 requirements
# Risk Tier: HIGH
# Requirements:
#   1. Emoji shortcode resolution (:emoji: -> 😀)
#   2. Emoji picker UI
#   3. Recent emoji tracking
#   4. Emoji search/filtering
#   5. Category-based emoji organization
#   6. Custom emoji support
#   7. Emoji rendering in messages

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set
from enum import Enum, auto

# === TYPES ===

class EmojiCategory(Enum):
    """Emoji categories."""
    SMILEYS = "smileys"
    PEOPLE = "people"
    ANIMALS = "animals"
    FOOD = "food"
    TRAVEL = "travel"
    ACTIVITIES = "activities"
    OBJECTS = "objects"
    SYMBOLS = "symbols"
    FLAGS = "flags"
    RECENT = "recent"
    CUSTOM = "custom"


@dataclass
class Emoji:
    """Emoji domain entity."""
    id: str
    shortcode: str  # e.g., "smile"
    unicode: Optional[str] = None  # e.g., "😀"
    category: EmojiCategory = EmojiCategory.SMILEYS
    aliases: List[str] = field(default_factory=list)
    tags: List[str] = field(default_factory=list)
    custom: bool = False
    custom_url: Optional[str] = None
    is_recent: bool = False
    usage_count: int = 0


@dataclass
class EmojiSearch:
    """Emoji search state."""
    query: str = ""
    category_filter: Optional[EmojiCategory] = None
    results: List[Emoji] = field(default_factory=list)
    cursor_position: int = 0
    recent_only: bool = False


@dataclass
class EmojiPicker:
    """Emoji picker state."""
    emojis: Dict[str, Emoji] = field(default_factory=dict)
    categories: Dict[EmojiCategory, List[str]] = field(default_factory=dict)
    recent: List[str] = field(default_factory=list)
    favorites: Set[str] = field(default_factory=set)
    max_recent: int = 20
    search: EmojiSearch = field(default_factory=EmojiSearch)
    visible: bool = False
    selected_emoji: Optional[str] = None


# === COMMON EMOJI MAPPING ===

COMMON_EMOJIS: Dict[str, tuple[str, EmojiCategory]] = {
    # Smileys
    "smile": ("😀", EmojiCategory.SMILEYS),
    "grinning": ("😀", EmojiCategory.SMILEYS),
    "smiley": ("😃", EmojiCategory.SMILEYS),
    "grin": ("😁", EmojiCategory.SMILEYS),
    "laughing": ("😆", EmojiCategory.SMILEYS),
    "sweat_smile": ("😅", EmojiCategory.SMILEYS),
    "joy": ("😂", EmojiCategory.SMILEYS),
    "rofl": ("🤣", EmojiCategory.SMILEYS),
    "wink": ("😉", EmojiCategory.SMILEYS),
    "blush": ("😊", EmojiCategory.SMILEYS),
    "heart_eyes": ("😍", EmojiCategory.SMILEYS),
    "kissing": ("😗", EmojiCategory.SMILEYS),
    "thinking": ("🤔", EmojiCategory.SMILEYS),
    "neutral": ("😐", EmojiCategory.SMILEYS),
    "expressionless": ("😑", EmojiCategory.SMILEYS),
    "smirk": ("😏", EmojiCategory.SMILEYS),
    "unamused": ("😒", EmojiCategory.SMILEYS),
    "sweat": ("😓", EmojiCategory.SMILEYS),
    "pensive": ("😔", EmojiCategory.SMILEYS),
    "confused": ("😕", EmojiCategory.SMILEYS),
    "confounded": ("😖", EmojiCategory.SMILEYS),
    "kissing_heart": ("😘", EmojiCategory.SMILEYS),
    "angry": ("😠", EmojiCategory.SMILEYS),
    "rage": ("😡", EmojiCategory.SMILEYS),
    "cry": ("😢", EmojiCategory.SMILEYS),
    "sob": ("😭", EmojiCategory.SMILEYS),
    "flushed": ("😳", EmojiCategory.SMILEYS),
    "fearful": ("😨", EmojiCategory.SMILEYS),
    "cold_sweat": ("😰", EmojiCategory.SMILEYS),
    "relieved": ("😌", EmojiCategory.SMILEYS),
    "sleepy": ("😪", EmojiCategory.SMILEYS),
    "sleeping": ("😴", EmojiCategory.SMILEYS),
    "dizzy": ("😵", EmojiCategory.SMILEYS),
    "mask": ("😷", EmojiCategory.SMILEYS),
    "sunglasses": ("😎", EmojiCategory.SMILEYS),
    "nerd": ("🤓", EmojiCategory.SMILEYS),
    "poop": ("💩", EmojiCategory.SMILEYS),
    "thumbs_up": ("👍", EmojiCategory.PEOPLE),
    "thumbsup": ("👍", EmojiCategory.PEOPLE),
    "thumbs_down": ("👎", EmojiCategory.PEOPLE),
    "thumbsdown": ("👎", EmojiCategory.PEOPLE),
    "clap": ("👏", EmojiCategory.PEOPLE),
    "wave": ("👋", EmojiCategory.PEOPLE),
    "pray": ("🙏", EmojiCategory.PEOPLE),
    "fire": ("🔥", EmojiCategory.SYMBOLS),
    "heart": ("❤️", EmojiCategory.SYMBOLS),
    "rocket": ("🚀", EmojiCategory.TRAVEL),
    "check": ("✅", EmojiCategory.SYMBOLS),
    "x": ("❌", EmojiCategory.SYMBOLS),
    "warning": ("⚠️", EmojiCategory.SYMBOLS),
    "star": ("⭐", EmojiCategory.SYMBOLS),
    "sparkles": ("✨", EmojiCategory.SYMBOLS),
}


# === EMOJI OPERATIONS ===

def process(item: Emoji) -> Emoji:
    """Process emoji and resolve shortcode."""
    if item.unicode:
        return item
    
    # Try to resolve from common emojis
    if item.shortcode in COMMON_EMOJIS:
        unicode, category = COMMON_EMOJIS[item.shortcode]
        return Emoji(
            id=item.id,
            shortcode=item.shortcode,
            unicode=unicode,
            category=category,
            aliases=item.aliases,
            tags=item.tags,
            custom=item.custom,
            custom_url=item.custom_url,
            is_recent=item.is_recent,
            usage_count=item.usage_count
        )
    
    return item


def resolve_shortcode(shortcode: str) -> Optional[str]:
    """Resolve shortcode to unicode emoji.
    
    Returns None if shortcode not found.
    """
    # Remove colons if present
    clean = shortcode.strip(":")
    
    if clean in COMMON_EMOJIS:
        return COMMON_EMOJIS[clean][0]
    
    return None


def create_emoji_picker() -> EmojiPicker:
    """Create emoji picker with default emoji set."""
    emojis = {}
    categories: Dict[EmojiCategory, List[str]] = {c: [] for c in EmojiCategory}
    
    for shortcode, (unicode, category) in COMMON_EMOJIS.items():
        emoji = Emoji(
            id=f"emoji_{shortcode}",
            shortcode=shortcode,
            unicode=unicode,
            category=category
        )
        emojis[shortcode] = emoji
        categories[category].append(shortcode)
    
    return EmojiPicker(
        emojis=emojis,
        categories=categories,
        recent=[],
        favorites=set(),
        max_recent=20,
        search=EmojiSearch(),
        visible=False,
        selected_emoji=None
    )


def search_emojis(picker: EmojiPicker, query: str) -> List[Emoji]:
    """Search emojis by query."""
    if not query:
        return []
    
    query = query.lower()
    results = []
    
    for emoji in picker.emojis.values():
        # Match shortcode
        if query in emoji.shortcode.lower():
            results.append(emoji)
            continue
        
        # Match aliases
        if any(query in alias.lower() for alias in emoji.aliases):
            results.append(emoji)
            continue
        
        # Match tags
        if any(query in tag.lower() for tag in emoji.tags):
            results.append(emoji)
            continue
    
    # Sort by usage count (most used first)
    results.sort(key=lambda e: e.usage_count, reverse=True)
    
    return results


def select_emoji(picker: EmojiPicker, shortcode: str) -> EmojiPicker:
    """Select an emoji and update recent/favorites."""
    if shortcode not in picker.emojis:
        return picker
    
    emoji = picker.emojis[shortcode]
    
    # Update recent
    new_recent = [shortcode] + [r for r in picker.recent if r != shortcode]
    new_recent = new_recent[:picker.max_recent]
    
    # Update usage count
    new_emojis = dict(picker.emojis)
    new_emojis[shortcode] = Emoji(
        id=emoji.id,
        shortcode=emoji.shortcode,
        unicode=emoji.unicode,
        category=emoji.category,
        aliases=emoji.aliases,
        tags=emoji.tags,
        custom=emoji.custom,
        custom_url=emoji.custom_url,
        is_recent=True,
        usage_count=emoji.usage_count + 1
    )
    
    return EmojiPicker(
        emojis=new_emojis,
        categories=picker.categories,
        recent=new_recent,
        favorites=picker.favorites,
        max_recent=picker.max_recent,
        search=picker.search,
        visible=picker.visible,
        selected_emoji=shortcode
    )


def toggle_favorite(picker: EmojiPicker, shortcode: str) -> EmojiPicker:
    """Toggle emoji favorite status."""
    new_favorites = set(picker.favorites)
    
    if shortcode in new_favorites:
        new_favorites.remove(shortcode)
    else:
        new_favorites.add(shortcode)
    
    return EmojiPicker(
        emojis=picker.emojis,
        categories=picker.categories,
        recent=picker.recent,
        favorites=new_favorites,
        max_recent=picker.max_recent,
        search=picker.search,
        visible=picker.visible,
        selected_emoji=picker.selected_emoji
    )


def show_picker(picker: EmojiPicker) -> EmojiPicker:
    """Show the emoji picker."""
    return EmojiPicker(
        emojis=picker.emojis,
        categories=picker.categories,
        recent=picker.recent,
        favorites=picker.favorites,
        max_recent=picker.max_recent,
        search=EmojiSearch(),
        visible=True,
        selected_emoji=None
    )


def hide_picker(picker: EmojiPicker) -> EmojiPicker:
    """Hide the emoji picker."""
    return EmojiPicker(
        emojis=picker.emojis,
        categories=picker.categories,
        recent=picker.recent,
        favorites=picker.favorites,
        max_recent=picker.max_recent,
        search=picker.search,
        visible=False,
        selected_emoji=None
    )


def get_emojis_by_category(picker: EmojiPicker, category: EmojiCategory) -> List[Emoji]:
    """Get all emojis in a category."""
    shortcodes = picker.categories.get(category, [])
    return [picker.emojis.get(sc) for sc in shortcodes if sc in picker.emojis]


def replace_shortcodes(text: str) -> str:
    """Replace shortcodes in text with unicode emojis.
    
    Example: "Hello :smile:" -> "Hello 😀"
    """
    import re
    
    pattern = r':([a-zA-Z0-9_\-]+):'
    
    def replace(match):
        shortcode = match.group(1)
        unicode = resolve_shortcode(shortcode)
        return unicode if unicode else match.group(0)
    
    return re.sub(pattern, replace, text)


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "8800ff3d0b107565c6843f640189ff9c37d2ecc77f5d20b8a75c187a47adc523",
    "name": "Emoji Domain",
    "risk_tier": "high",
}
