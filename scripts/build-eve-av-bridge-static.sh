#!/usr/bin/env bash
# Build eve-av-bridge with **glibc crt-static** via the freeq flake
# (no musl). Optionally copy it to a boxd VM.
#
#   ./scripts/build-eve-av-bridge-static.sh
#   ./scripts/build-eve-av-bridge-static.sh --deploy-boxd eve
#
# Equivalent cargo (from nix develop):
#   RUSTFLAGS='-C target-feature=+crt-static' cargo build -p eve-av-bridge --release

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[static] nix build .#eve-av-bridge-static  (glibc crt-static)"
nix build ".#eve-av-bridge-static" -L

OUT="$(readlink -f result)/bin/eve-av-bridge"
echo "[static] built: $OUT"
file "$OUT" || true
# Fully static → ldd says "not a dynamic executable"
ldd "$OUT" 2>&1 | head -8 || true

if [[ "${1:-}" == "--deploy-boxd" ]]; then
  VM="${2:-eve}"
  echo "[static] boxd cp → ${VM}:/home/boxd/bin/eve-av-bridge"
  boxd cp "$OUT" "${VM}:/home/boxd/bin/eve-av-bridge"
  boxd exec "$VM" -- bash -lc 'chmod +x /home/boxd/bin/eve-av-bridge; file /home/boxd/bin/eve-av-bridge; ldd /home/boxd/bin/eve-av-bridge 2>&1 | head -5; /home/boxd/bin/eve-av-bridge --help | head -8'
fi

echo "[static] done"
