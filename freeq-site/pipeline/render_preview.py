#!/usr/bin/env python3
"""Render a launch-post markdown draft to a styled, self-contained HTML preview
and open it in the browser.

Approximates how the post will read on freeq.at: dark, terminal-adjacent, with
code blocks and the "what this does not claim" section visually distinct.
Placeholders the artifact gate flags (TODO/VERIFY, xxxx, dead links) are
highlighted in red so they can't be missed in review.

Usage:
    python3 pipeline/render_preview.py pipeline/drafts/post.md [--no-open]
"""
import html
import pathlib
import re
import subprocess
import sys

CSS = """
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0a0c12;color:#e8e8ea;
     font:17px/1.72 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
.wrap{max-width:720px;margin:0 auto;padding:56px 26px 100px}
h1{font-size:2.05em;line-height:1.18;letter-spacing:-.02em;margin:0 0 .1em;color:#fff}
.date{color:#8b8b95;font-style:italic;margin:0 0 2.2em}
h2{font-size:1.32em;margin:2.3em 0 .5em;color:#fff;
   padding-bottom:.25em;border-bottom:1px solid #ffffff14}
p{margin:1.05em 0}
strong{color:#fff}
a{color:#e05a6d}
code{font:.88em ui-monospace,'JetBrains Mono',Menlo,monospace;
     background:#ffffff0f;padding:.12em .35em;border-radius:4px;color:#f0b8a8}
pre{background:#12151e;border:1px solid #2a2f3a;border-radius:10px;
    padding:1em 1.1em;overflow-x:auto;margin:1.3em 0}
pre code{background:none;padding:0;color:#cfd3dc;font-size:.85em;line-height:1.6}
ul{margin:1.05em 0;padding-left:1.3em}
li{margin:.5em 0}
.flag{background:#e05a6d;color:#0a0c12;font-weight:700;padding:.05em .35em;border-radius:3px}
.note{font-size:.8em;color:#8b8b95;font-family:ui-monospace,Menlo,monospace;
      border-top:1px solid #ffffff14;margin-top:3.5em;padding-top:1em}
"""

PLACEHOLDER_RE = re.compile(
    r"(&lt;!--\s*(?:TODO|VERIFY|FIXME)[^&]*--&gt;|xxxx+|sig=\.\.\.|\]\(#\)|\bTODO\b|\bFIXME\b|\bVERIFY\b)")


def inline(t: str) -> str:
    t = html.escape(t)
    # Flag dead links before the link regex turns them into <a href="#">.
    t = t.replace("](#)", ']<span class="flag">(dead link)</span>')
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return PLACEHOLDER_RE.sub(r'<span class="flag">\1</span>', t)


def render(md: str) -> str:
    out, para, in_code, code, in_list = [], [], False, [], False
    first_em_done = False

    def flush():
        nonlocal para
        if para:
            out.append("<p>" + inline(" ".join(para)) + "</p>")
            para = []

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for line in md.splitlines():
        s = line.strip()
        if s.startswith("```"):
            if in_code:
                body = html.escape("\n".join(code))
                body = PLACEHOLDER_RE.sub(r'<span class="flag">\1</span>', body)
                out.append(f"<pre><code>{body}</code></pre>")
                code, in_code = [], False
            else:
                flush(); close_list(); in_code = True
            continue
        if in_code:
            code.append(line); continue
        if not s:
            flush(); close_list(); continue
        if s.startswith("# "):
            flush(); close_list(); out.append(f"<h1>{inline(s[2:])}</h1>"); continue
        if s.startswith("## "):
            flush(); close_list(); out.append(f"<h2>{inline(s[3:])}</h2>"); continue
        if re.fullmatch(r"\*\d{4}-\d{2}-\d{2}\*", s) and not first_em_done:
            flush(); out.append(f'<p class="date">{html.escape(s.strip("*"))}</p>')
            first_em_done = True
            continue
        if s.startswith("- ") or s.startswith("* "):
            flush()
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{inline(s[2:])}</li>")
            continue
        para.append(s)
    flush(); close_list()
    return "\n".join(out)


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    src = pathlib.Path(args[0])
    body = render(src.read_text())
    outp = src.with_suffix(".preview.html")
    outp.write_text(
        "<!doctype html><meta charset=utf-8>"
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        f"<title>{html.escape(src.stem)} — freeq draft</title>"
        f"<style>{CSS}</style><div class=wrap>{body}"
        '<div class="note">draft preview · red = placeholder the artifact gate is '
        "holding publication on</div></div>"
    )
    print(f"rendered -> {outp}")
    if "--no-open" not in sys.argv:
        subprocess.run(["open", str(outp)], check=False)
        print("opened in browser")
    return 0


if __name__ == "__main__":
    sys.exit(main())
