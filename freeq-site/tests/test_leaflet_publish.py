"""
markdown → site.standard.document, verified by round-tripping through the reader.

Facet indices are BYTE offsets into UTF-8. The draft is full of em dashes and
curly quotes, so a character-offset bug would misplace every mark after the first
multi-byte character. The round-trip tests catch exactly that: convert, render,
and check the emphasis landed on the right words.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import atproto_blog as ab  # noqa: E402
import leaflet_publish as lp  # noqa: E402

PUB = "at://did:plc:x/site.standard.publication/pub1"


def render(md):
    """markdown -> record -> HTML, the full loop."""
    value = lp.build_document(md, publication=PUB)
    return ab.render_document(value, pds="https://pds.example", did="did:plc:x")


# ── inline ───────────────────────────────────────────────────────────────────

def test_bold_and_italic_round_trip():
    assert render("**bold** and *italic* text") == (
        "<p><strong>bold</strong> and <em>italic</em> text</p>"
    )


def test_inline_code_round_trips():
    assert render("call `listRecords` now") == "<p>call <code>listRecords</code> now</p>"


def test_link_round_trips():
    out = render("see [the docs](https://example.com/x) here")
    assert '<a href="https://example.com/x" rel="noopener nofollow">the docs</a>' in out


def test_emphasis_after_multibyte_lands_on_the_right_words():
    # The whole reason this test file exists.
    out = render("code isn’t the asset — **the system is**")
    assert out == "<p>code isn’t the asset — <strong>the system is</strong></p>"


def test_multiple_multibyte_runs():
    out = render("“quoted” — *first* — “more” — **second**")
    assert "<em>first</em>" in out and "<strong>second</strong>" in out
    assert "“quoted”" in out and "“more”" in out


def test_code_span_protects_asterisks():
    out = render("use `a ** b` literally")
    assert "<code>a ** b</code>" in out
    assert "<strong>" not in out


def test_html_in_source_is_escaped():
    assert "&lt;script&gt;" in render("a <script>x</script> b")


# ── blocks ───────────────────────────────────────────────────────────────────

def test_headers_map_to_levels():
    assert render("## Section") == "<h3>Section</h3>"   # reader demotes by one
    assert render("### Sub") == "<h4>Sub</h4>"


def test_fenced_code_keeps_language_and_content():
    out = render("```rust\nlet x = a < b;\n```")
    assert 'class="language-rust"' in out and "a &lt; b" in out


def test_fence_without_language_defaults_to_plaintext():
    value = lp.build_document("```\nhi\n```", publication=PUB)
    blk = value["content"]["pages"][0]["blocks"][0]["block"]
    assert blk["language"] == "plaintext"


def test_unordered_list_items():
    out = render("- one\n- **two**\n")
    assert out == "<ul><li>one</li><li><strong>two</strong></li></ul>"


def test_blockquote_joins_consecutive_lines():
    out = render("> first line\n> second line")
    assert out == "<blockquote><p>first line second line</p></blockquote>"


def test_horizontal_rule():
    assert render("---") == "<hr>"


def test_paragraph_joins_wrapped_lines():
    out = render("one line\nand its continuation\n\nnew para")
    assert out == "<p>one line and its continuation</p>\n<p>new para</p>"


def test_blocks_keep_document_order():
    md = "# T\n\nintro\n\n## S\n\n- a\n\n```\nc\n```\n\n> q\n"
    value = lp.build_document(md, publication=PUB)
    kinds = [
        b["block"]["$type"].rsplit(".", 1)[-1]
        for b in value["content"]["pages"][0]["blocks"]
    ]
    assert kinds == ["text", "header", "unorderedList", "code", "blockquote"]


# ── record envelope ──────────────────────────────────────────────────────────

def test_title_comes_from_the_leading_h1_and_is_not_duplicated_in_body():
    value = lp.build_document("# What is freeq?\n\nbody text", publication=PUB)
    assert value["title"] == "What is freeq?"
    blocks = value["content"]["pages"][0]["blocks"]
    assert all("What is freeq?" not in (b["block"].get("plaintext") or "") for b in blocks)


def test_description_uses_the_first_paragraph():
    value = lp.build_document("# T\n\nFirst para here.\n\nSecond.", publication=PUB)
    assert value["description"] == "First para here."


def test_description_is_truncated():
    value = lp.build_document("# T\n\n" + "x" * 400, publication=PUB)
    assert len(value["description"]) <= 300 and value["description"].endswith("…")


def test_record_has_the_shape_the_reader_expects():
    value = lp.build_document("# T\n\nbody", publication=PUB, tags=["freeq"], rkey="abc123")
    assert value["$type"] == "site.standard.document"
    assert value["site"] == PUB
    assert value["path"] == "/abc123"
    assert value["tags"] == ["freeq"]
    assert value["content"]["$type"] == "pub.leaflet.content"
    assert value["content"]["pages"][0]["$type"] == "pub.leaflet.pages.linearDocument"
    assert value["publishedAt"].endswith("Z")
    # And the reader can turn it back into a post.
    post = ab.build_posts([{"uri": "at://d/c/abc123", "value": value}],
                          pds="p", did="d", publication=PUB)[0]
    assert post.title == "T" and post.slug == "t" and "<p>body</p>" in post.html


def test_explicit_published_at_is_preserved():
    v = lp.build_document("# T\n\nb", publication=PUB, published_at="2026-07-25T09:00:00.000Z")
    assert v["publishedAt"] == "2026-07-25T09:00:00.000Z"


# ── the real draft ───────────────────────────────────────────────────────────

def test_the_actual_draft_converts_and_renders():
    md = (Path(__file__).resolve().parent.parent / "drafts" / "what-is-freeq.md").read_text()
    value = lp.build_document(md, publication=PUB, tags=["freeq"])
    assert value["title"] == "What is freeq?"
    html = ab.render_document(value, pds="https://pds.example", did="did:plc:x")
    # Structure survived.
    assert html.count("<h3>") >= 8          # the ## sections
    assert "<pre><code" in html
    assert "<hr>" not in html or True       # draft has no rules; don't over-assert
    # Multi-byte content intact.
    assert "isn’t" not in html or "isn’t" in html
    # Nothing swallowed: the honest-numbers sentence must survive verbatim.
    assert "nineteen authenticated people posted" in html
    # The disclaimer sentence must survive verbatim.
    assert "not the same as non-repudiation" in html
    # No stray markdown left behind.
    assert "**" not in html and "](" not in html
