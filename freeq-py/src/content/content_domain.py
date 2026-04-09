# 🟢 GREEN: Content Domain (IU-2790ac55)
# Description: Implements content processing with 5 requirements
# Risk Tier: HIGH
# Requirements:
#   1. 4-stage rendering pipeline: source -> preprocess -> detect -> render
#   2. URL detection and linking
#   3. Mention detection (@user, #channel)
#   4. Emoji shortcode resolution
#   5. Content formatting and word wrapping

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Tuple
from enum import Enum, auto
import re

# === TYPES ===

class ContentEntityType(Enum):
    """Types of content entities."""
    URL = auto()
    MENTION = auto()
    CHANNEL_REF = auto()
    EMOJI = auto()
    CODE = auto()
    BOLD = auto()
    ITALIC = auto()
    UNDERLINE = auto()
    STRIKETHROUGH = auto()
    COLOR = auto()


@dataclass
class ContentEntity:
    """Entity within content (URL, mention, etc.)."""
    entity_type: ContentEntityType
    start: int
    end: int
    text: str
    data: Dict[str, Any] = field(default_factory=dict)


@dataclass
class Content:
    """Content domain entity."""
    id: str
    raw_text: str = ""
    processed_text: str = ""
    entities: List[ContentEntity] = field(default_factory=list)
    word_count: int = 0
    char_count: int = 0
    line_count: int = 0
    has_url: bool = False
    has_mention: bool = False
    has_emoji: bool = False
    formatted_lines: List[str] = field(default_factory=list)
    pipeline_stage: str = "source"


# === RENDERING PIPELINE ===

class ContentPipeline:
    """4-stage content rendering pipeline.
    
    Stages:
    1. source - raw content
    2. preprocess - clean/normalize
    3. detect - find entities (URLs, mentions, etc.)
    4. render - format for display
    """
    
    @staticmethod
    def source(content: Content) -> Content:
        """Stage 1: Source - raw content."""
        return Content(
            id=content.id,
            raw_text=content.raw_text,
            processed_text=content.raw_text,
            entities=[],
            word_count=0,
            char_count=len(content.raw_text),
            line_count=content.raw_text.count('\n') + 1,
            has_url=False,
            has_mention=False,
            has_emoji=False,
            formatted_lines=[],
            pipeline_stage="source"
        )
    
    @staticmethod
    def preprocess(content: Content) -> Content:
        """Stage 2: Preprocess - clean and normalize."""
        text = content.raw_text
        
        # Normalize line endings
        text = text.replace('\r\n', '\n').replace('\r', '\n')
        
        # Remove control characters except tab and newline
        text = ''.join(c for c in text if ord(c) >= 32 or c in '\n\t')
        
        # Collapse multiple spaces
        text = re.sub(r' +', ' ', text)
        
        # Strip leading/trailing whitespace per line
        lines = text.split('\n')
        lines = [line.strip() for line in lines]
        text = '\n'.join(lines)
        
        return Content(
            id=content.id,
            raw_text=content.raw_text,
            processed_text=text,
            entities=content.entities,
            word_count=0,
            char_count=len(text),
            line_count=text.count('\n') + 1,
            has_url=content.has_url,
            has_mention=content.has_mention,
            has_emoji=content.has_emoji,
            formatted_lines=[],
            pipeline_stage="preprocess"
        )
    
    @staticmethod
    def detect(content: Content) -> Content:
        """Stage 3: Detect - find entities."""
        text = content.processed_text
        entities = []
        
        # Detect URLs
        url_pattern = r'https?://[^\s<>"\')\]]+[^\s<>"\')\].,;!?]'
        for match in re.finditer(url_pattern, text):
            entities.append(ContentEntity(
                entity_type=ContentEntityType.URL,
                start=match.start(),
                end=match.end(),
                text=match.group(),
                data={"url": match.group()}
            ))
        
        # Detect mentions (@user)
        mention_pattern = r'@(\w+[\w\-]*)'
        for match in re.finditer(mention_pattern, text):
            entities.append(ContentEntity(
                entity_type=ContentEntityType.MENTION,
                start=match.start(),
                end=match.end(),
                text=match.group(),
                data={"user": match.group(1)}
            ))
        
        # Detect channel refs (#channel)
        channel_pattern = r'#([a-zA-Z][a-zA-Z0-9\-_]*)'
        for match in re.finditer(channel_pattern, text):
            entities.append(ContentEntity(
                entity_type=ContentEntityType.CHANNEL_REF,
                start=match.start(),
                end=match.end(),
                text=match.group(),
                data={"channel": match.group(1)}
            ))
        
        # Detect emoji shortcodes (:emoji:)
        emoji_pattern = r':([a-zA-Z0-9_\-]+):'
        for match in re.finditer(emoji_pattern, text):
            entities.append(ContentEntity(
                entity_type=ContentEntityType.EMOJI,
                start=match.start(),
                end=match.end(),
                text=match.group(),
                data={"shortcode": match.group(1)}
            ))
        
        # Detect bold/italic markers
        bold_pattern = r'\*\*(.+?)\*\*'
        for match in re.finditer(bold_pattern, text):
            entities.append(ContentEntity(
                entity_type=ContentEntityType.BOLD,
                start=match.start(),
                end=match.end(),
                text=match.group(),
                data={"content": match.group(1)}
            ))
        
        italic_pattern = r'\*(.+?)\*'
        for match in re.finditer(italic_pattern, text):
            # Skip if already part of bold
            if not any(e.start == match.start() for e in entities):
                entities.append(ContentEntity(
                    entity_type=ContentEntityType.ITALIC,
                    start=match.start(),
                    end=match.end(),
                    text=match.group(),
                    data={"content": match.group(1)}
                ))
        
        # Sort entities by position
        entities.sort(key=lambda e: e.start)
        
        # Count words
        words = text.split()
        word_count = len(words)
        
        return Content(
            id=content.id,
            raw_text=content.raw_text,
            processed_text=text,
            entities=entities,
            word_count=word_count,
            char_count=content.char_count,
            line_count=content.line_count,
            has_url=any(e.entity_type == ContentEntityType.URL for e in entities),
            has_mention=any(e.entity_type == ContentEntityType.MENTION for e in entities),
            has_emoji=any(e.entity_type == ContentEntityType.EMOJI for e in entities),
            formatted_lines=[],
            pipeline_stage="detect"
        )
    
    @staticmethod
    def render(content: Content, wrap_width: int = 80) -> Content:
        """Stage 4: Render - format for display."""
        text = content.processed_text
        
        # Apply formatting
        formatted = text
        
        # Replace entities with formatted versions
        for entity in reversed(content.entities):
            if entity.entity_type == ContentEntityType.URL:
                formatted = (
                    formatted[:entity.start] +
                    f"[underline cyan]{entity.text}[/underline cyan]" +
                    formatted[entity.end:]
                )
            elif entity.entity_type == ContentEntityType.MENTION:
                formatted = (
                    formatted[:entity.start] +
                    f"[bold yellow]{entity.text}[/bold yellow]" +
                    formatted[entity.end:]
                )
            elif entity.entity_type == ContentEntityType.CHANNEL_REF:
                formatted = (
                    formatted[:entity.start] +
                    f"[bold green]#{entity.data['channel']}[/bold green]" +
                    formatted[entity.end:]
                )
            elif entity.entity_type == ContentEntityType.EMOJI:
                formatted = (
                    formatted[:entity.start] +
                    f"[emoji]{entity.text}[/emoji]" +
                    formatted[entity.end:]
                )
        
        # Word wrap
        lines = wrap_text(formatted, wrap_width)
        
        return Content(
            id=content.id,
            raw_text=content.raw_text,
            processed_text=content.processed_text,
            entities=content.entities,
            word_count=content.word_count,
            char_count=content.char_count,
            line_count=len(lines),
            has_url=content.has_url,
            has_mention=content.has_mention,
            has_emoji=content.has_emoji,
            formatted_lines=lines,
            pipeline_stage="render"
        )


def wrap_text(text: str, width: int) -> List[str]:
    """Wrap text to specified width."""
    if not text:
        return [""]
    
    lines = []
    for paragraph in text.split('\n'):
        if len(paragraph) <= width:
            lines.append(paragraph)
        else:
            # Simple word wrap
            words = paragraph.split(' ')
            current_line = ""
            for word in words:
                if len(current_line) + len(word) + 1 <= width:
                    current_line += " " + word if current_line else word
                else:
                    if current_line:
                        lines.append(current_line)
                    current_line = word
            if current_line:
                lines.append(current_line)
    
    return lines


def process(item: Content) -> Content:
    """Run full content processing pipeline.
    
    Executes all 4 stages: source -> preprocess -> detect -> render
    """
    stage1 = ContentPipeline.source(item)
    stage2 = ContentPipeline.preprocess(stage1)
    stage3 = ContentPipeline.detect(stage2)
    stage4 = ContentPipeline.render(stage3)
    return stage4


def extract_urls(content: Content) -> List[str]:
    """Extract all URLs from content."""
    return [
        e.data.get("url", e.text)
        for e in content.entities
        if e.entity_type == ContentEntityType.URL
    ]


def extract_mentions(content: Content) -> List[str]:
    """Extract all user mentions from content."""
    return [
        e.data.get("user", "")
        for e in content.entities
        if e.entity_type == ContentEntityType.MENTION
    ]


def extract_channels(content: Content) -> List[str]:
    """Extract all channel references from content."""
    return [
        e.data.get("channel", "")
        for e in content.entities
        if e.entity_type == ContentEntityType.CHANNEL_REF
    ]


def strip_formatting(text: str) -> str:
    """Remove IRC formatting codes and markup."""
    # Remove IRC color codes (\x03foreground,background)
    text = re.sub(r'\x03\d{1,2}(,\d{1,2})?', '', text)
    
    # Remove other IRC codes
    text = text.replace('\x02', '')  # Bold
    text = text.replace('\x1D', '')  # Italic
    text = text.replace('\x1F', '')  # Underline
    text = text.replace('\x0F', '')  # Reset
    text = text.replace('\x16', '')  # Reverse
    
    # Remove Textual markup
    text = re.sub(r'\[/?[^\]]+\]', '', text)
    
    return text


# === PHOENIX VCS TRACEABILITY ===
_phoenix = {
    "iu_id": "2790ac556c9559669090ce9fdd5a5e4f47d179c398a9bd199e37af5e8a8e6c6e",
    "name": "Content Domain",
    "risk_tier": "high",
}
