"""
Read the freeq blog from AT Protocol instead of local files.

Posts are authored in Leaflet, which writes them to the author's own PDS as
`site.standard.document` records (Leaflet also mirrors to its own
`pub.leaflet.document`; we read the standardized one). Everything we need is
world-readable via `com.atproto.repo.listRecords`, so this needs no auth, no API
key, and no Leaflet-specific service: if Leaflet disappeared tomorrow the posts
would still be in the repo and this module would still render them.

That is the point of putting the blog here rather than in `blog/*.md`. The blog
is the same claim the rest of the project makes, applied to itself: the data is
yours, the renderer is replaceable.

Record shape (discovered from live records, 2026-07):

    site.standard.document
      title, description, path, publishedAt, tags, site (at:// of publication)
      content: { pages: [ { $type: …linearDocument, blocks: [ {block: …} ] } ] }

    blocks: text | header(level) | blockquote | code(language) | image(blob)
            | unorderedList(children[].content)
    facets: byte-indexed ranges over `plaintext`, features:
            bold | italic | code | link(uri)

⚠ Facet offsets are **byte** offsets into UTF-8, exactly as in Bluesky richtext.
These posts are full of em dashes and curly quotes, all multi-byte, so slicing
the Python `str` by those numbers silently corrupts text. Always slice bytes.
"""

from __future__ import annotations

import html
import json
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any

PLC_DIRECTORY = "https://plc.directory"
DOC_COLLECTION = "site.standard.document"
PUB_COLLECTION = "site.standard.publication"
USER_AGENT = "freeq-site/1.0 (+https://freeq.at)"
HTTP_TIMEOUT = 6.0


# ── fetch ────────────────────────────────────────────────────────────────────

def _get_json(url: str, timeout: float = HTTP_TIMEOUT) -> Any:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def resolve_pds(did: str, *, fetch=_get_json) -> str | None:
    """The PDS endpoint for `did`, from its DID document."""
    try:
        doc = fetch(f"{PLC_DIRECTORY}/{urllib.parse.quote(did)}")
    except Exception:
        return None
    for svc in doc.get("service") or []:
        if "atproto_pds" in (svc.get("id") or "") or svc.get("type") == "AtprotoPersonalDataServer":
            return svc.get("serviceEndpoint")
    return None


def list_records(pds: str, did: str, collection: str, *, limit: int = 100, fetch=_get_json) -> list[dict]:
    """All records in a collection, following cursors."""
    out: list[dict] = []
    cursor = None
    while True:
        q = {"repo": did, "collection": collection, "limit": str(limit)}
        if cursor:
            q["cursor"] = cursor
        page = fetch(f"{pds}/xrpc/com.atproto.repo.listRecords?" + urllib.parse.urlencode(q))
        out.extend(page.get("records") or [])
        cursor = page.get("cursor")
        if not cursor or not page.get("records"):
            return out


def blob_url(pds: str, did: str, cid: str) -> str:
    q = urllib.parse.urlencode({"did": did, "cid": cid})
    return f"{pds}/xrpc/com.atproto.sync.getBlob?{q}"


# ── richtext ─────────────────────────────────────────────────────────────────

_TAGS = {
    "pub.leaflet.richtext.facet#bold": ("<strong>", "</strong>"),
    "pub.leaflet.richtext.facet#italic": ("<em>", "</em>"),
    "pub.leaflet.richtext.facet#code": ("<code>", "</code>"),
}


def render_richtext(plaintext: str, facets: list[dict] | None) -> str:
    """
    Apply byte-indexed facets to `plaintext`, returning escaped HTML.

    Overlapping and nested facets are handled by segmenting on every boundary
    and recomputing which features are active in each run, rather than trying to
    nest tags pairwise (which breaks on partial overlap).
    """
    if not plaintext:
        return ""
    data = plaintext.encode("utf-8")
    if not facets:
        return html.escape(plaintext)

    spans = []
    for f in facets:
        idx = f.get("index") or {}
        start, end = idx.get("byteStart"), idx.get("byteEnd")
        if not isinstance(start, int) or not isinstance(end, int):
            continue
        # Clamp: a record written by a buggy client must not raise here.
        start = max(0, min(start, len(data)))
        end = max(start, min(end, len(data)))
        if start == end:
            continue
        for feat in f.get("features") or []:
            spans.append((start, end, feat))

    if not spans:
        return html.escape(plaintext)

    boundaries = sorted({0, len(data)} | {b for s, e, _ in spans for b in (s, e)})
    pieces: list[str] = []
    for lo, hi in zip(boundaries, boundaries[1:]):
        if lo >= hi:
            continue
        try:
            text = data[lo:hi].decode("utf-8")
        except UnicodeDecodeError:
            # A facet boundary landed mid-character (client bug). Recover the
            # nearest valid text rather than dropping the run.
            text = data[lo:hi].decode("utf-8", errors="replace")
        seg = html.escape(text)
        active = [feat for s, e, feat in spans if s <= lo and hi <= e]
        # Links outermost so emphasis nests inside the anchor.
        links = [f for f in active if f.get("$type") == "pub.leaflet.richtext.facet#link"]
        for feat in active:
            pair = _TAGS.get(feat.get("$type") or "")
            if pair:
                seg = f"{pair[0]}{seg}{pair[1]}"
        for lk in links:
            uri = lk.get("uri") or ""
            if uri.startswith(("http://", "https://")):
                seg = (
                    f'<a href="{html.escape(uri, quote=True)}" '
                    f'rel="noopener nofollow">{seg}</a>'
                )
        pieces.append(seg)
    return "".join(pieces)


# ── blocks ───────────────────────────────────────────────────────────────────

def render_block(block: dict, *, pds: str = "", did: str = "") -> str:
    t = block.get("$type") or ""
    kind = t.rsplit(".", 1)[-1]
    plain = block.get("plaintext") or ""
    facets = block.get("facets")

    if kind == "text":
        body = render_richtext(plain, facets)
        return f"<p>{body}</p>" if body.strip() else ""
    if kind == "header":
        level = block.get("level")
        level = level if isinstance(level, int) and 1 <= level <= 6 else 2
        # Documents carry their own <h1> from `title`, so demote in-body headers
        # by one to keep a single top-level heading per page.
        level = min(level + 1, 6)
        return f"<h{level}>{render_richtext(plain, facets)}</h{level}>"
    if kind == "blockquote":
        return f"<blockquote><p>{render_richtext(plain, facets)}</p></blockquote>"
    if kind == "horizontalRule":
        return "<hr>"
    if kind == "code":
        lang = block.get("language") or ""
        cls = f' class="language-{html.escape(lang, quote=True)}"' if lang else ""
        body = html.escape(plain.strip("\n"))
        return f"<pre><code{cls}>{body}</code></pre>"
    if kind == "unorderedList":
        items = []
        for child in block.get("children") or []:
            inner = child.get("content") or {}
            items.append(
                f"<li>{render_richtext(inner.get('plaintext') or '', inner.get('facets'))}</li>"
            )
        return "<ul>" + "".join(items) + "</ul>" if items else ""
    if kind == "image":
        img = block.get("image") or {}
        cid = ((img.get("ref") or {}).get("$link")) or ""
        if not cid or not pds or not did:
            return ""
        alt = html.escape(block.get("alt") or "", quote=True)
        ar = block.get("aspectRatio") or {}
        dims = ""
        if isinstance(ar.get("width"), int) and isinstance(ar.get("height"), int):
            dims = f' width="{ar["width"]}" height="{ar["height"]}"'
        src = html.escape(blob_url(pds, did, cid), quote=True)
        return f'<figure><img src="{src}" alt="{alt}"{dims} loading="lazy"></figure>'
    return ""  # unknown block type: skip rather than break the page


def render_document(value: dict, *, pds: str = "", did: str = "") -> str:
    parts: list[str] = []
    for page in (value.get("content") or {}).get("pages") or []:
        for wrapper in page.get("blocks") or []:
            parts.append(render_block(wrapper.get("block") or {}, pds=pds, did=did))
    return "\n".join(p for p in parts if p)


# ── posts ────────────────────────────────────────────────────────────────────

@dataclass
class Post:
    slug: str            # readable permalink, derived from the title
    title: str
    description: str
    date: str            # YYYY-MM-DD, for display/sorting
    published_at: str    # raw ISO
    html: str
    rkey: str = ""       # record key; also accepted as a permalink
    tags: list[str] = field(default_factory=list)
    uri: str = ""        # at:// of the record, so the page can cite its source


def slugify(title: str) -> str:
    """
    A readable URL slug from a title.

    Leaflet stores `path` as the record key ("/3mjx4erlboc2l"), which makes for
    opaque permalinks. We publish title slugs and keep the rkey as an alias, so
    links shared in either form keep resolving.

    Apostrophes are dropped rather than hyphenated ("isn't" → "isnt", not
    "isn-t").
    """
    s = unicodedata.normalize("NFKD", title or "")
    s = s.encode("ascii", "ignore").decode("ascii").lower()
    s = re.sub(r"['\u2019\u02bc]", "", s)
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def _rkey_from(value: dict, uri: str) -> str:
    path = (value.get("path") or "").strip("/")
    if path:
        return path.rsplit("/", 1)[-1]
    return uri.rsplit("/", 1)[-1]


def build_posts(records: list[dict], *, pds: str, did: str, publication: str | None) -> list[Post]:
    """Records → Posts, newest first, optionally filtered to one publication."""
    posts: list[Post] = []
    for r in records:
        v = r.get("value") or {}
        if publication and (v.get("site") or "") != publication:
            continue
        published = v.get("publishedAt") or ""
        rkey = _rkey_from(v, r.get("uri") or "")
        posts.append(
            Post(
                slug=slugify(v.get("title") or "") or rkey,
                title=v.get("title") or "(untitled)",
                description=v.get("description") or "",
                date=published[:10],
                published_at=published,
                html=render_document(v, pds=pds, did=did),
                rkey=rkey,
                tags=[t for t in (v.get("tags") or []) if isinstance(t, str)],
                uri=r.get("uri") or "",
            )
        )
    posts.sort(key=lambda p: p.published_at, reverse=True)
    # Two posts can share a title. Disambiguate the later ones with the rkey so
    # one URL never shadows another post.
    seen: set[str] = set()
    for p in posts:
        if p.slug in seen:
            p.slug = f"{p.slug}-{p.rkey}"
        seen.add(p.slug)
    return posts


class BlogSource:
    """
    Cached view of a DID's published documents.

    Never raises to the caller and never blocks a page render on the network for
    long: on any failure it serves the last good result, and if there has never
    been one it returns an empty list so the route can fall back to local posts.
    """

    def __init__(
        self,
        did: str,
        publication: str | None = None,
        ttl: float = 300.0,
        require_publication: bool = True,
    ):
        # A repo can hold documents from several publications — this DID also
        # publishes a book. Without a publication URI we would serve the wrong
        # posts, which is worse than serving none, so default to refusing and
        # let the caller fall back to local files.
        self.did = did
        self.publication = publication
        self.require_publication = require_publication
        self.ttl = ttl
        self._posts: list[Post] = []
        self._pds: str | None = None
        self._fetched_at = 0.0
        self._last_error: str | None = None

    @property
    def last_error(self) -> str | None:
        return self._last_error

    def _refresh(self) -> None:
        try:
            pds = self._pds or resolve_pds(self.did)
            if not pds:
                raise RuntimeError(f"no PDS for {self.did}")
            records = list_records(pds, self.did, DOC_COLLECTION)
            self._posts = build_posts(
                records, pds=pds, did=self.did, publication=self.publication
            )
            self._pds = pds
            self._fetched_at = time.time()
            self._last_error = None
        except Exception as exc:  # network, JSON, PDS 5xx — all non-fatal
            self._last_error = f"{type(exc).__name__}: {exc}"
            # Back off so a dead PDS doesn't slow every request.
            self._fetched_at = time.time() - self.ttl / 2

    def posts(self) -> list[Post]:
        if self.require_publication and not self.publication:
            return []
        if not self._posts or time.time() - self._fetched_at > self.ttl:
            self._refresh()
        return self._posts

    def post(self, slug: str) -> Post | None:
        """Resolve a permalink by title slug or by record key."""
        wanted = (slug or "").strip("/").lower()
        for p in self.posts():
            if wanted in (p.slug.lower(), p.rkey.lower()):
                return p
        return None
