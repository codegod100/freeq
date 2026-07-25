"""
Tests for the AT Protocol blog reader.

The headline risk is facet handling: offsets are BYTE offsets into UTF-8 and the
real posts are full of em dashes and curly quotes, so a naive `str` slice
silently corrupts text. Several tests below use deliberately multi-byte content
for that reason.

Run: python3 -m pytest freeq-site/tests/test_atproto_blog.py -q
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import atproto_blog as ab  # noqa: E402

BOLD = "pub.leaflet.richtext.facet#bold"
ITALIC = "pub.leaflet.richtext.facet#italic"
CODE = "pub.leaflet.richtext.facet#code"
LINK = "pub.leaflet.richtext.facet#link"


def facet(start, end, *features):
    return {"index": {"byteStart": start, "byteEnd": end}, "features": list(features)}


def bytes_of(s, sub):
    """Byte offsets of `sub` within `s`, the way a real client computes them."""
    b, sb = s.encode("utf-8"), sub.encode("utf-8")
    i = b.index(sb)
    return i, i + len(sb)


# ── richtext: the byte-offset trap ───────────────────────────────────────────

def test_plain_text_is_escaped():
    assert ab.render_richtext("a < b & c", None) == "a &lt; b &amp; c"


def test_bold_applies_to_the_right_characters():
    text = "the durable asset is the system"
    s, e = bytes_of(text, "durable asset")
    assert ab.render_richtext(text, [facet(s, e, {"$type": BOLD})]) == (
        "the <strong>durable asset</strong> is the system"
    )


def test_multibyte_text_is_not_corrupted():
    # Em dash and curly quotes are multi-byte. If the renderer slices the str by
    # byte offsets, the emphasis lands in the wrong place and text mangles.
    text = "code isn’t the asset — the system is"
    s, e = bytes_of(text, "the system is")
    out = ab.render_richtext(text, [facet(s, e, {"$type": BOLD})])
    assert out == "code isn’t the asset — <strong>the system is</strong>"
    assert "isn’t" in out and "—" in out


def test_multibyte_before_and_inside_the_span():
    text = "précis — “quoted” — tail"
    s, e = bytes_of(text, "“quoted”")
    out = ab.render_richtext(text, [facet(s, e, {"$type": ITALIC})])
    assert out == "précis — <em>“quoted”</em> — tail"


def test_link_wraps_outside_emphasis():
    text = "see the honeycomb post here"
    s, e = bytes_of(text, "honeycomb post")
    out = ab.render_richtext(
        text,
        [
            facet(s, e, {"$type": LINK, "uri": "https://example.com/x"}),
            facet(s, e, {"$type": BOLD}),
        ],
    )
    assert out == (
        'see the <a href="https://example.com/x" rel="noopener nofollow">'
        "<strong>honeycomb post</strong></a> here"
    )


def test_partially_overlapping_facets_do_not_produce_crossed_tags():
    # Pairwise nesting breaks here; segmenting on boundaries does not.
    text = "abcdef"
    out = ab.render_richtext(
        text, [facet(0, 4, {"$type": BOLD}), facet(2, 6, {"$type": ITALIC})]
    )
    # Every tag opened must close before its parent closes.
    assert out.count("<strong>") == out.count("</strong>")
    assert out.count("<em>") == out.count("</em>")
    for frag in ("ab", "cd", "ef"):
        assert frag in out
    assert "<strong>ab</strong>" in out


def test_code_facet_renders_inline_code():
    text = "call listRecords now"
    s, e = bytes_of(text, "listRecords")
    assert "<code>listRecords</code>" in ab.render_richtext(text, [facet(s, e, {"$type": CODE})])


def test_javascript_uri_is_not_linked():
    text = "click me"
    out = ab.render_richtext(
        text, [facet(0, 5, {"$type": LINK, "uri": "javascript:alert(1)"})]
    )
    assert "<a" not in out and "javascript" not in out


def test_out_of_range_and_inverted_offsets_are_survivable():
    text = "short"
    assert ab.render_richtext(text, [facet(0, 9999, {"$type": BOLD})]) == "<strong>short</strong>"
    assert ab.render_richtext(text, [facet(4, 2, {"$type": BOLD})]) == "short"
    assert ab.render_richtext(text, [{"features": [{"$type": BOLD}]}]) == "short"


def test_facet_boundary_mid_character_does_not_raise():
    # A buggy client could emit an offset inside a multi-byte char.
    text = "a—b"  # em dash is 3 bytes at offset 1..4
    out = ab.render_richtext(text, [facet(2, 3, {"$type": BOLD})])
    assert isinstance(out, str) and "a" in out


# ── blocks ───────────────────────────────────────────────────────────────────

def test_header_is_demoted_so_the_page_keeps_one_h1():
    blk = {"$type": "pub.leaflet.blocks.header", "level": 1, "plaintext": "Intro"}
    assert ab.render_block(blk) == "<h2>Intro</h2>"
    blk["level"] = 2
    assert ab.render_block(blk) == "<h3>Intro</h3>"


def test_code_block_escapes_and_keeps_language():
    blk = {
        "$type": "pub.leaflet.blocks.code",
        "language": "rust",
        "plaintext": "\nlet x = a < b;\n",
    }
    out = ab.render_block(blk)
    assert 'class="language-rust"' in out
    assert "a &lt; b" in out
    assert "<script" not in out


def test_unordered_list_renders_items_with_richtext():
    text = "recorded reasons"
    s, e = bytes_of(text, "recorded")
    blk = {
        "$type": "pub.leaflet.blocks.unorderedList",
        "children": [
            {"content": {"plaintext": text, "facets": [facet(s, e, {"$type": BOLD})]}},
            {"content": {"plaintext": "second"}},
        ],
    }
    out = ab.render_block(blk)
    assert out.startswith("<ul>") and out.endswith("</ul>")
    assert "<li><strong>recorded</strong> reasons</li>" in out
    assert "<li>second</li>" in out


def test_image_uses_the_public_blob_endpoint():
    blk = {
        "$type": "pub.leaflet.blocks.image",
        "alt": 'a "diagram"',
        "image": {"ref": {"$link": "bafyCID"}},
        "aspectRatio": {"width": 800, "height": 600},
    }
    out = ab.render_block(blk, pds="https://pds.example", did="did:plc:abc")
    assert "com.atproto.sync.getBlob" in out
    assert "did=did%3Aplc%3Aabc" in out and "cid=bafyCID" in out
    assert 'width="800"' in out and 'loading="lazy"' in out
    assert "&quot;diagram&quot;" in out  # alt text escaped


def test_image_without_pds_is_skipped_not_broken():
    blk = {"$type": "pub.leaflet.blocks.image", "image": {"ref": {"$link": "cid"}}}
    assert ab.render_block(blk) == ""


def test_unknown_block_type_is_skipped():
    assert ab.render_block({"$type": "pub.leaflet.blocks.somethingNew2027"}) == ""


def test_horizontal_rule_and_blockquote():
    assert ab.render_block({"$type": "pub.leaflet.blocks.horizontalRule"}) == "<hr>"
    assert ab.render_block(
        {"$type": "pub.leaflet.blocks.blockquote", "plaintext": "q"}
    ) == "<blockquote><p>q</p></blockquote>"


def test_empty_text_block_produces_nothing():
    assert ab.render_block({"$type": "pub.leaflet.blocks.text", "plaintext": "  "}) == ""


# ── documents & posts ────────────────────────────────────────────────────────

def doc(title, published, path, site="at://pub/1", blocks=None):
    return {
        "uri": f"at://did:plc:x/site.standard.document/{path}",
        "value": {
            "title": title,
            "description": "d",
            "path": path,
            "publishedAt": published,
            "site": site,
            "tags": ["freeq"],
            "content": {
                "pages": [
                    {
                        "$type": "pub.leaflet.pages.linearDocument",
                        "blocks": blocks
                        or [{"block": {"$type": "pub.leaflet.blocks.text", "plaintext": title}}],
                    }
                ]
            },
        },
    }


def test_posts_are_newest_first():
    posts = ab.build_posts(
        [
            doc("old", "2026-01-01T00:00:00Z", "a"),
            doc("new", "2026-06-01T00:00:00Z", "b"),
            doc("mid", "2026-03-01T00:00:00Z", "c"),
        ],
        pds="p",
        did="d",
        publication=None,
    )
    assert [p.title for p in posts] == ["new", "mid", "old"]
    assert posts[0].date == "2026-06-01"


def test_publication_filter_excludes_other_publications():
    recs = [
        doc("freeq post", "2026-06-01T00:00:00Z", "a", site="at://pub/freeq"),
        doc("book post", "2026-06-02T00:00:00Z", "b", site="at://pub/book"),
    ]
    posts = ab.build_posts(recs, pds="p", did="d", publication="at://pub/freeq")
    assert [p.title for p in posts] == ["freeq post"]


def test_rkey_falls_back_to_the_uri_when_path_missing():
    # `path` is optional; the record key is always recoverable from the at:// uri.
    r = doc("Some Title", "2026-01-01T00:00:00Z", "abc")
    r["value"]["path"] = ""
    p = ab.build_posts([r], pds="p", did="d", publication=None)[0]
    assert p.rkey == "abc"
    assert p.slug == "some-title"


def test_rkey_uses_the_last_path_segment():
    r = doc("Some Title", "2026-01-01T00:00:00Z", "x")
    r["value"]["path"] = "/posts/deep/3mjx4erlboc2l"
    p = ab.build_posts([r], pds="p", did="d", publication=None)[0]
    assert p.rkey == "3mjx4erlboc2l"


# ── caching / failure ────────────────────────────────────────────────────────

def test_source_returns_empty_and_records_error_when_pds_unresolvable(monkeypatch):
    monkeypatch.setattr(ab, "resolve_pds", lambda did, **kw: None)
    src = ab.BlogSource("did:plc:nope", require_publication=False)
    assert src.posts() == []
    assert src.last_error and "no PDS" in src.last_error


def test_source_serves_stale_posts_when_refresh_fails(monkeypatch):
    monkeypatch.setattr(ab, "resolve_pds", lambda did, **kw: "https://pds.example")
    monkeypatch.setattr(
        ab, "list_records", lambda *a, **k: [doc("first", "2026-01-01T00:00:00Z", "a")]
    )
    src = ab.BlogSource("did:plc:x", ttl=0.0, require_publication=False)
    assert [p.title for p in src.posts()] == ["first"]

    def boom(*a, **k):
        raise RuntimeError("PDS down")

    monkeypatch.setattr(ab, "list_records", boom)
    # Still serves the last good result rather than an empty page.
    assert [p.title for p in src.posts()] == ["first"]
    assert "PDS down" in (src.last_error or "")


def test_source_does_not_refetch_within_ttl(monkeypatch):
    calls = []
    monkeypatch.setattr(ab, "resolve_pds", lambda did, **kw: "https://pds.example")

    def counted(*a, **k):
        calls.append(1)
        return [doc("t", "2026-01-01T00:00:00Z", "a")]

    monkeypatch.setattr(ab, "list_records", counted)
    src = ab.BlogSource("did:plc:x", ttl=3600.0, require_publication=False)
    src.posts()
    src.posts()
    src.posts()
    assert len(calls) == 1


def test_post_lookup_by_slug():
    monkeypatch = None  # not needed; drive build_posts directly
    src = ab.BlogSource("did:plc:x", require_publication=False)
    src._posts = ab.build_posts([doc("t", "2026-01-01T00:00:00Z", "hello")], pds="p", did="d", publication=None)
    src._fetched_at = 9e9  # keep the cache warm
    assert src.post("hello").title == "t"
    assert src.post("missing") is None


def test_resolve_pds_reads_the_did_document():
    doc_ = {
        "service": [
            {"id": "#atproto_pds", "type": "AtprotoPersonalDataServer",
             "serviceEndpoint": "https://puffball.example"}
        ]
    }
    assert ab.resolve_pds("did:plc:x", fetch=lambda url: doc_) == "https://puffball.example"


def test_list_records_follows_cursors():
    pages = [
        {"records": [doc("a", "2026-01-01T00:00:00Z", "a")], "cursor": "c1"},
        {"records": [doc("b", "2026-01-02T00:00:00Z", "b")]},
    ]
    seq = iter(pages)
    got = ab.list_records("https://pds", "did:plc:x", "coll", fetch=lambda url: next(seq))
    assert len(got) == 2


# ── slugs: Leaflet's `path` is the rkey, which makes ugly permalinks ─────────

def test_slugify_makes_readable_permalinks():
    assert ab.slugify("Production Is a Compiler Input") == "production-is-a-compiler-input"
    assert ab.slugify("The Conversation Is the Commit") == "the-conversation-is-the-commit"


def test_slugify_handles_punctuation_and_unicode():
    assert ab.slugify("Code Isn’t the Asset — Really?") == "code-isnt-the-asset-really"
    assert ab.slugify("  spaced   out  ") == "spaced-out"
    assert ab.slugify("C++ & Rust: a story") == "c-rust-a-story"


def test_slugify_never_returns_empty():
    assert ab.slugify("—") == ""
    assert ab.slugify("") == ""


def test_post_uses_title_slug_but_keeps_the_rkey():
    r = doc("Production Is a Compiler Input", "2026-04-20T00:00:00Z", "3mjx4erlboc2l")
    r["value"]["path"] = "/3mjx4erlboc2l"
    p = ab.build_posts([r], pds="p", did="d", publication=None)[0]
    assert p.slug == "production-is-a-compiler-input"
    assert p.rkey == "3mjx4erlboc2l"


def test_lookup_resolves_title_slug_and_rkey_and_path():
    r = doc("Production Is a Compiler Input", "2026-04-20T00:00:00Z", "3mjx4erlboc2l")
    r["value"]["path"] = "/3mjx4erlboc2l"
    src = ab.BlogSource("did:plc:x", require_publication=False)
    src._posts = ab.build_posts([r], pds="p", did="d", publication=None)
    src._fetched_at = 9e9
    # A shared permalink must keep working whichever form it used.
    assert src.post("production-is-a-compiler-input") is not None
    assert src.post("3mjx4erlboc2l") is not None
    assert src.post("nope") is None


def test_duplicate_titles_get_distinct_slugs():
    # Two posts with the same title must not collide into one URL.
    a = doc("Same Title", "2026-01-01T00:00:00Z", "rkeyA")
    b = doc("Same Title", "2026-02-01T00:00:00Z", "rkeyB")
    a["value"]["path"] = "/rkeyA"
    b["value"]["path"] = "/rkeyB"
    posts = ab.build_posts([a, b], pds="p", did="d", publication=None)
    assert len({p.slug for p in posts}) == 2


def test_untitled_post_falls_back_to_rkey_slug():
    r = doc("—", "2026-01-01T00:00:00Z", "rkeyX")
    r["value"]["path"] = "/rkeyX"
    p = ab.build_posts([r], pds="p", did="d", publication=None)[0]
    assert p.slug == "rkeyX"


# ── safety: never show the wrong publication ────────────────────────────────

def test_source_without_a_publication_shows_nothing():
    """
    A DID's repo can hold documents from several publications (this one holds a
    book). Serving "every document in the repo" on freeq.at would publish the
    wrong posts, so an unconfigured source must yield nothing and let the caller
    fall back to local files.
    """
    src = ab.BlogSource("did:plc:x", publication=None, require_publication=True)
    src._posts = ab.build_posts(
        [doc("book post", "2026-01-01T00:00:00Z", "a", site="at://pub/book")],
        pds="p", did="d", publication=None,
    )
    src._fetched_at = 9e9
    assert src.posts() == []


def test_source_with_a_publication_shows_only_that_one(monkeypatch):
    monkeypatch.setattr(ab, "resolve_pds", lambda did, **kw: "https://pds.example")
    monkeypatch.setattr(ab, "list_records", lambda *a, **k: [
        doc("freeq post", "2026-06-01T00:00:00Z", "a", site="at://pub/freeq"),
        doc("book post", "2026-06-02T00:00:00Z", "b", site="at://pub/book"),
    ])
    src = ab.BlogSource("did:plc:x", publication="at://pub/freeq", require_publication=True)
    assert [p.title for p in src.posts()] == ["freeq post"]
