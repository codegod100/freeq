#!/bin/bash
# Hotspot analysis: identifies high-risk files by combining
# git churn (change frequency) with complexity (size + function count).
#
# Usage: ./scripts/hotspots.sh [--since 3months] [--top 20]
#
# High gamma = high risk. Focus testing and review on these files.

set -euo pipefail

SINCE="${1:---since=3 months ago}"
TOP="${2:-20}"

if [[ "$SINCE" == --since ]]; then
    SINCE="--since=${2:-3 months ago}"
    TOP="${3:-20}"
fi

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

echo "═══════════════════════════════════════════════════════════════"
echo " freeq Hotspot Analysis (churn × complexity)"
echo " Period: $(echo "$SINCE" | sed 's/--since=//')"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Collect churn data
declare -A CHURN
while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    file=$(echo "$line" | awk '{print $2}')
    if [[ -n "$file" && -f "$file" ]]; then
        CHURN["$file"]=$count
    fi
done < <(git log "$SINCE" --pretty=format: --name-only -- '*.rs' '*.ts' '*.tsx' | grep -v '^$' | sort | uniq -c | sort -rn)

# Compute gamma for each file
echo "FILE | LINES | FNS | CHURN | GAMMA"
echo "--- | --- | --- | --- | ---"

results=""
for file in "${!CHURN[@]}"; do
    churn=${CHURN[$file]}
    lines=$(wc -l < "$file" 2>/dev/null || echo 0)

    # Count functions based on file type
    if [[ "$file" == *.rs ]]; then
        fns=$(grep -cE '^\s*(pub\s+)?(async\s+)?fn ' "$file" 2>/dev/null || true)
    else
        fns=$(grep -cE 'function |const .* = .*=>|export (function|const|async)' "$file" 2>/dev/null || true)
    fi
    fns=${fns:-0}
    lines=${lines:-0}

    complexity=$(( ${lines} + ${fns} * 10 ))
    gamma=$(( ${churn} * ${complexity} / 1000 ))

    if [[ $gamma -gt 0 ]]; then
        results+="$gamma|$file|$lines|$fns|$churn\n"
    fi
done

echo -e "$results" | sort -t'|' -k1 -rn | head -"$TOP" | while IFS='|' read -r gamma file lines fns churn; do
    if [[ -n "$gamma" ]]; then
        printf "%-55s | %5s | %3s | %3s | %4s\n" "$file" "$lines" "$fns" "$churn" "$gamma"
    fi
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Gamma = churn × (lines + functions×10) / 1000"
echo " Higher gamma → more likely to contain bugs"
echo " Focus adversarial testing on the top files"
echo "═══════════════════════════════════════════════════════════════"
