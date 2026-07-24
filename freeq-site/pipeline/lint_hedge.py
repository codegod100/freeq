#!/usr/bin/env python3
"""Hedge / vaporware gate for freeq launch posts.

Launch rule: a capability is demonstrably there or it is absent. No "where
available", no future tense for features, no roadmap language dressed as a
proof. Hedging makes the launch feel unfinished and quietly overclaims what is
not deployed. This is the freeq analog of the book's stance gate — inverted:
the book bans claiming things exist; freeq bans claiming things that are not
actually deployed and runnable *right now*.

Usage: python3 lint_hedge.py blog/post.md [more.md ...]
"""
import re
import sys

PATTERNS = [
    (r"\bwhere available\b", '"where available" — remove; a capability is there or absent'),
    (r"\bwhere supported\b", '"where supported" — same hedge'),
    (r"\bcoming soon\b", '"coming soon" — vaporware'),
    (r"\bwill (?:support|be able to|eventually|soon)\b", "future-tense capability — describe only what is deployed"),
    (r"\bwe plan to\b", '"we plan to" — roadmap, not a proof'),
    (r"\bin the future\b", '"in the future" — undeployed'),
    (r"\b(?:is |are )?planned\b", '"planned" — undeployed'),
    (r"\broadmap\b", '"roadmap" — undeployed'),
    (r"\bin theory\b", '"in theory" — show it in practice or cut the claim'),
    (r"\beventually\b", '"eventually" — hedge'),
    (r"\bshould (?:be able to|work|support|handle)\b", '"should ..." — it works on a clean machine or it does not'),
    (r"\bexperimental support\b", '"experimental support" — hedge'),
    (r"\bnot yet\b", '"not yet" — if it is in the post it reads as unfinished; cut or move to the roadmap doc'),
]


def main() -> int:
    files = sys.argv[1:]
    hits = 0
    for f in files:
        for i, line in enumerate(open(f).read().splitlines(), 1):
            # skip a "what this does NOT claim" section's own hedged phrasing is fine;
            # we only flag capability hedging in the body, so keep it simple and flag all.
            for pat, why in PATTERNS:
                m = re.search(pat, line, re.I)
                if m:
                    hits += 1
                    print(f'{f}:{i}: "{m.group(0)}" — {why}')
    if hits:
        print(f"\nFAIL: {hits} hedge/vaporware hit(s). No hedging — the executable proof is the product.")
        return 1
    print(f"OK: no hedging in {len(files)} file(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
