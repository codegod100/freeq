"""
Route-level tests for /blog: the AT Protocol source and the local markdown files
must coexist, so that publishing the first Leaflet post doesn't silently drop the
posts that already exist as files.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import app as site  # noqa: E402
import atproto_blog as ab  # noqa: E402


def _post(title, date, slug):
    return ab.Post(
        slug=slug, title=title, description="d", date=date,
        published_at=f"{date}T00:00:00Z", html="<p>x</p>", rkey=slug,
        uri=f"at://did:plc:x/site.standard.document/{slug}",
    )


def test_index_merges_atproto_and_markdown(monkeypatch):
    monkeypatch.setattr(site, "_atproto_posts", lambda: [_post("From Leaflet", "2026-08-01", "from-leaflet")])
    monkeypatch.setattr(site, "_blog_posts", lambda: [
        {"slug": "older-file-post", "title": "Older File Post", "date": "2026-07-01"}
    ])
    body = site.app.test_client().get("/blog/").data.decode()
    assert "From Leaflet" in body
    assert "Older File Post" in body, "a pre-existing markdown post must not disappear"


def test_index_orders_by_date_across_sources(monkeypatch):
    monkeypatch.setattr(site, "_atproto_posts", lambda: [_post("Newer", "2026-08-01", "newer")])
    monkeypatch.setattr(site, "_blog_posts", lambda: [
        {"slug": "newest-file", "title": "Newest File", "date": "2026-09-01"},
        {"slug": "old-file", "title": "Old File", "date": "2026-01-01"},
    ])
    body = site.app.test_client().get("/blog/").data.decode()
    assert body.index("Newest File") < body.index("Newer") < body.index("Old File")


def test_atproto_wins_on_slug_collision(monkeypatch):
    # If a file post is migrated to Leaflet under the same slug, show one entry,
    # and prefer the AT Protocol record.
    monkeypatch.setattr(site, "_atproto_posts", lambda: [_post("Canonical", "2026-08-01", "dup")])
    monkeypatch.setattr(site, "_blog_posts", lambda: [
        {"slug": "dup", "title": "Stale Copy", "date": "2026-07-01"}
    ])
    body = site.app.test_client().get("/blog/").data.decode()
    assert "Canonical" in body
    assert "Stale Copy" not in body


def test_index_works_with_only_markdown(monkeypatch):
    monkeypatch.setattr(site, "_atproto_posts", lambda: [])
    monkeypatch.setattr(site, "_blog_posts", lambda: [
        {"slug": "only-file", "title": "Only File", "date": "2026-07-01"}
    ])
    body = site.app.test_client().get("/blog/").data.decode()
    assert "Only File" in body


def test_index_survives_atproto_outage(monkeypatch):
    def boom():
        raise RuntimeError("PDS down")
    monkeypatch.setattr(site, "_atproto_posts", boom)
    monkeypatch.setattr(site, "_blog_posts", lambda: [
        {"slug": "only-file", "title": "Only File", "date": "2026-07-01"}
    ])
    r = site.app.test_client().get("/blog/")
    assert r.status_code == 200
    assert b"Only File" in r.data


def test_feed_includes_both_sources(monkeypatch):
    monkeypatch.setattr(site, "_atproto_posts", lambda: [_post("From Leaflet", "2026-08-01", "from-leaflet")])
    monkeypatch.setattr(site, "_blog_posts", lambda: [
        {"slug": "file-post", "title": "File Post", "date": "2026-07-01"}
    ])
    body = site.app.test_client().get("/blog/feed.xml").data.decode()
    assert body.count("<item>") == 2
    assert "From Leaflet" in body and "File Post" in body
