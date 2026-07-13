#!/usr/bin/env bash
# Regenerate the vendored Cargo dependencies for Buck2 builds.
# Run this whenever Cargo.toml dependencies change.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
THIRD="$SCRIPT_DIR/freeq-webui/third-party"
REINDEER="$HOME/.cargo/bin/reindeer"

cd "$SCRIPT_DIR/freeq-webui"

echo "[1/3] vendor…"
"$REINDEER" vendor

echo "[2/3] buckify…"
"$REINDEER" buckify

echo "[3/3] deduplicate aliases + add vendor target…"
python3 -c '
import re, sys
text = open(sys.argv[1]).read()
lines = text.split("\n")
seen = {}
out = []
skip = -1
for i, line in enumerate(lines):
    if i < skip:
        continue
    s = line.strip()
    if s.startswith("alias("):
        block = [line]
        j = i + 1
        p = 1
        while j < len(lines) and p > 0:
            block.append(lines[j])
            p += lines[j].count("(") - lines[j].count(")")
            j += 1
        m = re.search(r"name\s*=\s*\"([^\"]+)\"", "\n".join(block))
        if m and m.group(1) in seen:
            skip = j
            continue
        if m:
            seen[m.group(1)] = True
        out.append(line)
    else:
        out.append(line)
out.append("")
out.append("filegroup(")
out.append("    name = \"vendor\",")
out.append("    srcs = glob([\"vendor/**/*\"]),")
out.append("    visibility = [\"PUBLIC\"],")
out.append(")")
open(sys.argv[1], "w").write("\n".join(out))
' "$THIRD/BUCK"

echo "done — $THIRD/BUCK ready"
