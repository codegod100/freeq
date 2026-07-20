#!/bin/bash
set -euo pipefail

# Build the Rust SDK for Android targets and generate Kotlin bindings.
# Run from the repo root: ./freeq-android/build-rust.sh
#
# Prerequisites:
#   - Android NDK installed (set ANDROID_NDK_HOME or use default path)
#   - cargo-ndk: cargo install cargo-ndk
#   - Rust Android targets: rustup target add aarch64-linux-android x86_64-linux-android

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Prefer rustup-managed cargo/rustc over Homebrew (which lacks Android targets)
export PATH="$HOME/.cargo/bin:$PATH"
# If Homebrew rustc still wins, force rustup's rustc
if rustc --print sysroot 2>/dev/null | grep -q Cellar; then
    for tc in "$HOME/.rustup"/toolchains/stable-*; do
        if [ -x "$tc/bin/rustc" ]; then
            export RUSTC="$tc/bin/rustc"
            echo "==> Overriding Homebrew rustc with: $RUSTC"
            break
        fi
    done
fi

# Auto-detect NDK if not set (macOS SDK Manager, Linux ~/Android, or Nix androidenv)
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    for NDK_DIR in \
        "$HOME/Library/Android/sdk/ndk" \
        "$HOME/Android/Sdk/ndk" \
        "${ANDROID_HOME:-}/ndk" \
        "${ANDROID_SDK_ROOT:-}/ndk"
    do
        if [ -n "$NDK_DIR" ] && [ -d "$NDK_DIR" ]; then
            ANDROID_NDK_HOME="$(ls -d "$NDK_DIR"/*/ 2>/dev/null | sort -V | tail -1)"
            ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
            break
        fi
    done
    # local.properties sdk.dir → ndk/* (NixOS freeq-android builds)
    if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -f freeq-android/local.properties ]; then
        SDK_DIR="$(sed -n 's/^sdk\.dir=//p' freeq-android/local.properties | head -1)"
        if [ -n "$SDK_DIR" ] && [ -d "$SDK_DIR/ndk" ]; then
            ANDROID_NDK_HOME="$(ls -d "$SDK_DIR"/ndk/*/ 2>/dev/null | sort -V | tail -1)"
            ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
        fi
        # Nix android-sdk-ndk package keeps NDK outside the composite androidsdk root
        if [ -z "${ANDROID_NDK_HOME:-}" ]; then
            CAND="$(ls -d /nix/store/*-android-sdk-ndk-*/libexec/android-sdk/ndk/*/ 2>/dev/null | sort -V | tail -1)"
            if [ -n "$CAND" ]; then
                ANDROID_NDK_HOME="${CAND%/}"
            fi
        fi
    fi
    if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
        export ANDROID_NDK_HOME
        echo "==> Auto-detected NDK: $ANDROID_NDK_HOME"
    else
        echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME or install via SDK Manager / nix androidenv."
        exit 1
    fi
fi

JNILIBS_DIR="freeq-android/freeq/src/main/jniLibs"
FFI_DIR="freeq-android/freeq/src/main/java/com/freeq/ffi"
GEN_DIR="freeq-android/Generated"

echo "==> Building for Android targets (arm64-v8a, x86_64)..."
cargo ndk \
    -t arm64-v8a \
    -t x86_64 \
    -o "$JNILIBS_DIR" \
    build -p freeq-sdk-ffi --lib --release

echo "==> Building host binary for bindgen..."
cargo build -p freeq-sdk-ffi --lib --release
cargo build -p freeq-sdk-ffi --bin uniffi-bindgen

echo "==> Generating Kotlin bindings..."
cargo run -p freeq-sdk-ffi --bin uniffi-bindgen -- generate \
    freeq-sdk-ffi/src/freeq.udl \
    --language kotlin \
    --config freeq-sdk-ffi/uniffi.toml \
    --out-dir "$GEN_DIR"

echo "==> Installing generated bindings..."
# Remove old stub files
rm -f "$FFI_DIR/FreeqClient.kt" "$FFI_DIR/FreeqTypes.kt" "$FFI_DIR/EventHandler.kt"

# Copy generated binding (UniFFI outputs to package path under out-dir)
mkdir -p "$FFI_DIR"
find "$GEN_DIR" -name "*.kt" -exec cp {} "$FFI_DIR/" \;

echo "==> Done!"
echo "    Native libs: $JNILIBS_DIR/{arm64-v8a,x86_64}/libfreeq_sdk_ffi.so"
echo "    Kotlin binding: $FFI_DIR/freeq.kt"
