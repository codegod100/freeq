#!/usr/bin/env bash
# Build the freeq-webui-client WASM crate in a hermetic scratch dir.
set -euo pipefail

# wasm-pack lives at $HOME/.cargo/bin; ensure it is on PATH.
export PATH="$HOME/.cargo/bin:$PATH"

# Use a sandbox-local CARGO_HOME so registry/git caches do not pollute
# the user's config, but the real user RUSTUP_HOME so the default
# toolchain is found.
export CARGO_HOME="$PWD/.cargo-home"
mkdir -p "$CARGO_HOME"

# Locate RUSTUP_HOME: prefer $HOME/.rustup, fall back to a known nix store.
for cand in "$HOME/.rustup" "/nix/store" "/home/nandi/.rustup"; do
    if [ -d "$cand" ] && [ -f "$cand/settings.toml" ]; then
        export RUSTUP_HOME="$cand"
        break
    fi
done

# Build the WASM crate in a location completely outside the workspace
# tree so cargo metadata does not pick up the root workspace.
        OUT_ABS="$(realpath "$OUT")"
        WORK="/tmp/freeq-webui-client-build"
        rm -rf "$WORK"
        mkdir -p "$WORK/src"
        cp freeq-webui-client/Cargo.toml "$WORK/"
        cp -RL freeq-webui-client/src/. "$WORK/src/"
        cd "$WORK"
        wasm-pack build --target web --release --out-dir "$OUT_ABS" .
