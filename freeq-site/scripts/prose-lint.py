#!/usr/bin/env python3
"""
Prose lint: keep the site copy sounding like the person who writes it.

Thresholds are calibrated against the author's own published prose
(../../writing) rather than a generic style guide. The goal is consistency of
voice, not obedience to Strunk & White.

    python3 freeq-site/scripts/prose-lint.py           # report
    python3 freeq-site/scripts/prose-lint.py --check   # exit 1 if over budget
    python3 freeq-site/scripts/prose-lint.py --baseline ../writing

This is a smell detector, not a judge. A flagged line can be right, and a clean
page can still be lifeless: the things that matter most (an actual author, a
concrete specific, an admitted limitation) can't be counted.
"""

from __future__ import annotations

import argparse
import collections
import html
import pathlib
import re
import sys

# Per-1000-word budgets, calibrated against the full ../writing corpus
# (103k words): em_dash 2.9, semicolon_antithesis 1.6, triads 2.2,
# brag 0.4. Contrast constructions ("not just X", "rather than") run 2.6 there
# and are deliberately NOT limited: that is his voice, not a tell.
BUDGET = {
    "em_dash": 3.0,
    "semicolon_antithesis": 3.5,
    "triads": 2.6,  # his corpus runs 2.2 — triads are his voice, not a tell
    "brag_noun_phrase": 0.0,
    "empty_tail": 0.0,
}

PATTERNS = {
    # An em dash used for emphasis where a period belongs. The single loudest tell.
    "em_dash": lambda t: [m.start() for m in re.finditer(r"—", t)],
    # "X does this; y does that" — balanced clauses in a row read as generated.
    "semicolon_antithesis": lambda t: [m.start() for m in re.finditer(r";\s+[a-z]", t)],
    # Rule-of-three lists.
    "triads": lambda t: [m.start() for m in re.finditer(r"\b\w+, \w+,? and \w+\b", t)],
    # Verbless marketing brags.
    "brag_noun_phrase": lambda t: [
        m.start()
        for m in re.finditer(
            r"\b(zero install|full parity|trust all the way down|by default\.|"
            r"first-party|enterprise-grade|blazing[- ]fast|seamless(ly)?|"
            r"robust|powerful|elegant|cutting[- ]edge|best[- ]in[- ]class)\b",
            t,
            re.I,
        )
    ],
    # Clauses that add no information, e.g. "...not the last." / "and more."
    "empty_tail": lambda t: [
        m.start()
        for m in re.finditer(
            r"(not the last|and (so much )?more\.|the possibilities are|"
            r"in today's world|it's important to note|at the end of the day)",
            t,
            re.I,
        )
    ],
    # Claims we can't support: signatures give verifiable authorship and
    # integrity, which is not the same as non-repudiation.
    "overclaim": lambda t: [
        m.start() for m in re.finditer(r"\bnon-repudiation\b", t, re.I)
    ],
}


def visible_text(path: pathlib.Path) -> str:
    """Strip templating, code and markup so we lint prose, not syntax."""
    s = path.read_text(errors="ignore")
    s = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", s, flags=re.S)
    s = re.sub(r"\{%.*?%\}", " ", s, flags=re.S)  # jinja
    s = re.sub(r"\{\{.*?\}\}", " ", s, flags=re.S)
    s = re.sub(r"```.*?```", " ", s, flags=re.S)  # fenced code
    s = re.sub(r"`[^`]*`", " ", s)  # inline code
    s = re.sub(r"^---.*?^---", " ", s, flags=re.S | re.M)  # frontmatter
    s = re.sub(r"<[^>]+>", " ", s)  # tags
    return re.sub(r"[ \t]+", " ", html.unescape(s))


def lint(paths: list[pathlib.Path]) -> tuple[collections.Counter, int, dict]:
    counts: collections.Counter = collections.Counter()
    per_file: dict[str, collections.Counter] = {}
    words = 0
    for p in paths:
        t = visible_text(p)
        w = len(t.split())
        if w < 40:  # skip stubs/partials; rates are meaningless
            continue
        words += w
        fc: collections.Counter = collections.Counter()
        for name, find in PATTERNS.items():
            n = len(find(t))
            fc[name] = n
            counts[name] += n
        fc["_words"] = w
        per_file[str(p)] = fc
    return counts, words, per_file


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if over budget")
    ap.add_argument("--baseline", help="dir of human-written prose to compare against")
    ap.add_argument("paths", nargs="*", help="files/dirs (default: site templates + blog)")
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    if args.paths:
        targets: list[pathlib.Path] = []
        for a in args.paths:
            p = pathlib.Path(a)
            targets += sorted(p.rglob("*.html")) + sorted(p.rglob("*.md")) if p.is_dir() else [p]
    else:
        targets = sorted((root / "templates").glob("*.html")) + sorted(
            (root / "blog").glob("*.md")
        )

    counts, words, per_file = lint(targets)
    if not words:
        print("no prose found")
        return 0

    print(f"{len(per_file)} files · {words} words\n")
    print(f"{'tell':24} {'count':>6} {'per 1k':>8} {'budget':>8}  ")
    over = []
    for name in PATTERNS:
        rate = counts[name] / words * 1000
        budget = BUDGET.get(name, 0.0)
        flag = ""
        if rate > budget:
            flag = "  OVER"
            over.append((name, rate, budget))
        print(f"{name:24} {counts[name]:>6} {rate:>8.1f} {budget:>8.1f}{flag}")

    # Worst offenders, so there's somewhere to start.
    worst = sorted(
        per_file.items(),
        key=lambda kv: (kv[1]["em_dash"] + kv[1]["semicolon_antithesis"]) / kv[1]["_words"],
        reverse=True,
    )[:5]
    print("\nworst files (em dash + semicolon antithesis, per 1k words):")
    for f, c in worst:
        r = (c["em_dash"] + c["semicolon_antithesis"]) / c["_words"] * 1000
        print(f"  {r:>6.1f}  {f}  ({c['em_dash']} em, {c['semicolon_antithesis']} semi)")

    if args.baseline:
        b = pathlib.Path(args.baseline)
        bfiles = sorted(b.rglob("*.qmd")) + sorted(b.rglob("*.md"))
        bcounts, bwords, _ = lint(bfiles[:40])
        if bwords:
            print(f"\nbaseline ({b}, {bwords} words):")
            for name in PATTERNS:
                print(f"  {name:24} {bcounts[name]/bwords*1000:>6.1f} per 1k")

    print(
        "\nNote: the things that matter most aren't countable. An actual author, a\n"
        "concrete specific, an admitted limitation."
    )

    if args.check and over:
        print("\nFAIL: over budget on " + ", ".join(n for n, _, _ in over))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
