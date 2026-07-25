"""
Convert markdown into a Leaflet/Standard-Sites document record.

The inverse of `atproto_blog.py`. That module reads `site.standard.document`
records and renders HTML; this one takes markdown and produces the record, so a
post drafted as a file can be published to the author's PDS and then read back
by Leaflet, freeq.at, or anything else that speaks the lexicon.

Record shape (matching what Leaflet itself writes, so its editor can still open
the result):

    site.standard.document
      title, description, publishedAt, path, site, tags
      content: { $type: pub.leaflet.content,
                 pages: [ { $type: pub.leaflet.pages.linearDocument,
                            id, blocks: [ { block: … } ] } ] }

⚠ Facet indices are **byte** offsets into UTF-8, as in Bluesky richtext. Emitting
character offsets silently misplaces emphasis in any text containing an em dash,
a curly quote, or an emoji. Everything here works in bytes.
"""

from __future__ import annotations

import datetime as _dt
import re
import uuid

CONTENT_TYPE = "pub.leaflet.content"
PAGE_TYPE = "pub.leaflet.pages.linearDocument"
BLOCK_WRAPPER = "pub.leaflet.pages.linearDocument#block"
DOC_TYPE = "site.standard.document"

B = "pub.leaflet.blocks."
F = "pub.leaflet.richtext.facet#"


# ── inline richtext ──────────────────────────────────────────────────────────

# Order matters: code first so `**` inside backticks isn't treated as bold.
_INLINE = [
    ("code", re.compile(r"`([^`]+)`")),
    ("link", re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")),
    ("bold", re.compile(r"\*\*([^*]+)\*\*")),
    ("italic", re.compile(r"(?<!\*)\*([^*\n]+)\*(?!\*)")),
]


def parse_inline(md: str) -> tuple[str, list[dict]]:
    """
    Strip inline markdown, returning (plaintext, facets).

    Facets carry byte offsets into the returned plaintext. Nested marks are not
    supported by the lexicon's flat facet model beyond overlapping ranges, which
    is fine: **bold with `code`** yields two facets over overlapping ranges and
    renders correctly.
    """
    text = md
    marks: list[tuple[int, int, dict]] = []  # (char_start, char_end, feature)

    # Repeatedly find the earliest match of any pattern, replace it with its
    # inner text, and record the mark against the *new* string.
    while True:
        best = None
        for kind, pat in _INLINE:
            m = pat.search(text)
            if m and (best is None or m.start() < best[1].start()):
                best = (kind, m)
        if best is None:
            break
        kind, m = best
        inner = m.group(1)
        feature: dict
        if kind == "link":
            feature = {"$type": F + "link", "uri": m.group(2)}
        else:
            feature = {"$type": F + kind}
        start = m.start()
        text = text[:start] + inner + text[m.end():]
        shift = m.end() - m.start() - len(inner)
        marks = [
            (
                s - shift if s > start else s,
                e - shift if e > start else e,
                f,
            )
            for s, e, f in marks
        ]
        marks.append((start, start + len(inner), feature))

    facets = []
    for cs, ce, feature in sorted(marks):
        # char offsets → byte offsets
        bs = len(text[:cs].encode("utf-8"))
        be = len(text[:ce].encode("utf-8"))
        if be > bs:
            facets.append({"index": {"byteStart": bs, "byteEnd": be}, "features": [feature]})
    return text, facets


def _text_block(md: str) -> dict:
    plain, facets = parse_inline(md)
    block: dict = {"$type": B + "text", "plaintext": plain}
    if facets:
        block["facets"] = facets
    return block


# ── block parsing ────────────────────────────────────────────────────────────

def parse_blocks(md: str) -> list[dict]:
    """Markdown → a list of Leaflet block objects (unwrapped)."""
    blocks: list[dict] = []
    lines = md.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        if not stripped:
            i += 1
            continue

        # fenced code
        if stripped.startswith("```"):
            lang = stripped[3:].strip() or "plaintext"
            i += 1
            body: list[str] = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                body.append(lines[i])
                i += 1
            i += 1  # closing fence
            blocks.append(
                {"$type": B + "code", "language": lang, "plaintext": "\n".join(body)}
            )
            continue

        # horizontal rule
        if re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", stripped):
            blocks.append({"$type": B + "horizontalRule"})
            i += 1
            continue

        # heading
        m = re.match(r"(#{1,6})\s+(.*)", stripped)
        if m:
            plain, facets = parse_inline(m.group(2).strip())
            blk: dict = {
                "$type": B + "header",
                "level": len(m.group(1)),
                "plaintext": plain,
            }
            if facets:
                blk["facets"] = facets
            blocks.append(blk)
            i += 1
            continue

        # blockquote (join consecutive > lines)
        if stripped.startswith(">"):
            parts = []
            while i < len(lines) and lines[i].strip().startswith(">"):
                parts.append(lines[i].strip()[1:].strip())
                i += 1
            plain, facets = parse_inline(" ".join(p for p in parts if p))
            blk = {"$type": B + "blockquote", "plaintext": plain}
            if facets:
                blk["facets"] = facets
            blocks.append(blk)
            continue

        # unordered list
        if re.match(r"[-*+]\s+", stripped):
            children = []
            while i < len(lines) and re.match(r"[-*+]\s+", lines[i].strip()):
                item = re.sub(r"^[-*+]\s+", "", lines[i].strip())
                children.append(
                    {"$type": B + "unorderedList#listItem", "content": _text_block(item)}
                )
                i += 1
            blocks.append({"$type": B + "unorderedList", "children": children})
            continue

        # paragraph: consume until a blank line or the start of another block
        para: list[str] = []
        while i < len(lines):
            s = lines[i].strip()
            if not s or s.startswith(("```", ">")) or re.match(r"#{1,6}\s", s) \
               or re.match(r"[-*+]\s+", s) or re.fullmatch(r"(-{3,}|\*{3,}|_{3,})", s):
                break
            para.append(s)
            i += 1
        if para:
            blocks.append(_text_block(" ".join(para)))
    return blocks


# ── document ─────────────────────────────────────────────────────────────────

def split_front_matter(md: str) -> tuple[str, str]:
    """(title, body) — the leading `# Heading` becomes the record title."""
    lines = md.split("\n")
    title = ""
    for idx, line in enumerate(lines):
        if line.startswith("# "):
            title = line[2:].strip()
            return title, "\n".join(lines[idx + 1:])
        if line.strip():
            break
    return title, md


def first_paragraph(blocks: list[dict], limit: int = 300) -> str:
    for b in blocks:
        if b.get("$type") == B + "text" and (b.get("plaintext") or "").strip():
            text = b["plaintext"].strip()
            return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"
    return ""


def build_document(
    md: str,
    *,
    publication: str,
    published_at: str | None = None,
    tags: list[str] | None = None,
    rkey: str | None = None,
    description: str | None = None,
) -> dict:
    """Markdown → a `site.standard.document` record value."""
    title, body = split_front_matter(md)
    blocks = parse_blocks(body)
    value = {
        "$type": DOC_TYPE,
        "title": title or "(untitled)",
        "description": description if description is not None else first_paragraph(blocks),
        "publishedAt": published_at
        or _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"
        ),
        "site": publication,
        "content": {
            "$type": CONTENT_TYPE,
            "pages": [
                {
                    "$type": PAGE_TYPE,
                    "id": str(uuid.uuid4()),
                    "blocks": [{"$type": BLOCK_WRAPPER, "block": b} for b in blocks],
                }
            ],
        },
    }
    if tags:
        value["tags"] = tags
    if rkey:
        # Leaflet stores the record key as the path.
        value["path"] = f"/{rkey}"
    return value
