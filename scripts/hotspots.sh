#!/bin/bash
# Hotspot analysis: identifies high-risk files by combining
# git churn (change frequency) with complexity (size + function count).
#
# Usage: ./scripts/hotspots.sh [--since "3 months ago"] [--top 20]
#
# High gamma = high risk. Focus testing and review on these files.
#
# Portability: stock macOS ships bash 3.2, which has no associative arrays
# (`declare -A`). This deliberately uses a single stream + awk instead, so the
# script runs everywhere without a bash 4 dependency.

set -euo pipefail

SINCE="3 months ago"
TOP=20

while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:-3 months ago}"; shift 2 ;;
        --since=*) SINCE="${1#--since=}"; shift ;;
        --top) TOP="${2:-20}"; shift 2 ;;
        --top=*) TOP="${1#--top=}"; shift ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

echo "═══════════════════════════════════════════════════════════════"
echo " freeq Hotspot Analysis (churn × complexity)"
echo " Period: since $SINCE · top $TOP"
echo "═══════════════════════════════════════════════════════════════"
echo ""
printf "%-58s %6s %5s %6s %6s\n" "FILE" "LINES" "FNS" "CHURN" "GAMMA"
printf "%-58s %6s %5s %6s %6s\n" "------------------------------------------" "-----" "---" "-----" "-----"

# churn: commits touching each still-existing source file
git log --since="$SINCE" --pretty=format: --name-only -- '*.rs' '*.ts' '*.tsx' \
  | grep -v '^$' \
  | sort | uniq -c | sort -rn \
  | while read -r churn file; do
        [ -n "${file:-}" ] || continue
        [ -f "$file" ] || continue          # skip deleted/renamed-away paths
        case "$file" in
            */node_modules/*|*/target/*|*.d.ts) continue ;;
        esac

        lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        case "$file" in
            *.rs) fns=$(grep -cE '^[[:space:]]*(pub[[:space:]]+)?(async[[:space:]]+)?fn ' "$file" 2>/dev/null || true) ;;
            *)    fns=$(grep -cE 'function |const .* = .*=>|export (function|const|async)' "$file" 2>/dev/null || true) ;;
        esac
        lines=${lines:-0}; fns=${fns:-0}

        # gamma = churn × (lines + fns×10) / 1000
        gamma=$(( churn * (lines + fns * 10) / 1000 ))
        [ "$gamma" -gt 0 ] || continue
        printf "%s|%s|%s|%s|%s\n" "$gamma" "$file" "$lines" "$fns" "$churn"
  done \
  | sort -t'|' -k1,1 -rn \
  | head -"$TOP" \
  | while IFS='|' read -r gamma file lines fns churn; do
        printf "%-58s %6s %5s %6s %6s\n" "$file" "$lines" "$fns" "$churn" "$gamma"
  done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Gamma = churn × (lines + functions×10) / 1000"
echo " Higher gamma → more likely to contain bugs"
echo " Focus adversarial testing on the top files"
echo "═══════════════════════════════════════════════════════════════"
