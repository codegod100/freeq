#!/usr/bin/env python3
"""Title gate for freeq launch posts.

Rejects audit-bait adjectives and the word "MMO" in the post title (the H1).
Launch rule: make them *want* the thing before they can audit it. Words like
"secure" / "federated" invite a cryptography audit before the reader has
experienced the strange thing; "MMO" derails technical threads unless the
system is genuinely massively-multiplayer. Let the *post* reveal that it is
signed, encrypted, federated, and policy-governed.

Usage: python3 lint_title.py blog/post.md [more.md ...]
"""
import re
import sys

AUDIT_BAIT = [
    "secure", "encrypted", "end-to-end", "e2e", "federated", "cryptographic",
    "cryptographically", "zero-knowledge", "zero knowledge", "decentralized",
    "trustless", "military-grade", "unhackable",
]


def title_of(text: str):
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("# "):
            return s[2:].strip()
        if s:
            return None  # first real line isn't an H1
    return None


def main() -> int:
    files = sys.argv[1:]
    hits = 0
    for f in files:
        t = title_of(open(f).read())
        if t is None:
            print(f"{f}: no H1 title (`# Title`) found")
            hits += 1
            continue
        tl = t.lower()
        bad = [w for w in AUDIT_BAIT if re.search(r"\b" + re.escape(w) + r"\b", tl)]
        if re.search(r"\bmmo\b", tl):
            bad.append("MMO — only if it is genuinely massively-multiplayer")
        if bad:
            hits += 1
            print(f'{f}: title "{t}"')
            for w in bad:
                print(f'    audit-bait / derailer: "{w}" — let the post reveal it, do not claim it in the title')
    if hits:
        print(f"\nFAIL: {hits} title issue(s). Make them want the thing before they audit it.")
        return 1
    print(f"OK: titles clean in {len(files)} file(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
