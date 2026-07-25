#!/usr/bin/env bash
# Run all freeq launch-post gates on the given markdown file(s).
# Usage: ./run_gates.sh blog/post.md ...   (defaults to ../blog/*.md)
here="$(cd "$(dirname "$0")" && pwd)"
if [ "$#" -eq 0 ]; then set -- "$here/../blog"/*.md; fi
rc=0
echo "==================== title ===================="; python3 "$here/lint_title.py" "$@" || rc=1
echo "================ hedge / vaporware ============="; python3 "$here/lint_hedge.py" "$@" || rc=1
echo "=============== artifact package ==============="; python3 "$here/check_artifact_package.py" "$@" || rc=1
echo "=================== links ====================="; python3 "$here/check_links.py" "$@" || rc=1
echo; [ $rc -eq 0 ] && echo "ALL GATES PASS" || echo "GATES FAILED (rc=$rc)"
exit $rc
