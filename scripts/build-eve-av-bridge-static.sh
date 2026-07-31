#!/usr/bin/env bash
# Build a *working* glibc crt-static eve-av-bridge for bare Linux (boxd).
#
# Default: flake app → crane package `eve-av-bridge-static` (local max-jobs).
# Do NOT use cargo-only `crt-static` re-link — it has produced SEGV binaries.
#
#   ./scripts/build-eve-av-bridge-static.sh
#   ./scripts/build-eve-av-bridge-static.sh --deploy-boxd eve
#   nix run .#build-static-bridge -- --deploy-boxd eve
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[static] nix run .#build-static-bridge $*"
# Ensure the thin wrapper can build locally when max-jobs=0 on the host.
export NIX_BUILD_MAX_JOBS="${NIX_BUILD_MAX_JOBS:-4}"
exec nix run "$ROOT#build-static-bridge" --max-jobs "${NIX_BUILD_MAX_JOBS}" --builders '' -- "$@"
