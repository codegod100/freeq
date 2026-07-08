{ pkgs, lib, ... }:

# Freeq developer environment.
#
# One-shot entry point: `devenv shell` (or `direnv allow` after `direnv`
# is installed) drops you into a shell with the Rust toolchain, Node 24,
# Bun, and the system deps needed to build + run every package in this
# workspace.
#
# Source of truth for the Rust toolchain: rust-toolchain.toml at the repo
# root. We deliberately do NOT use `languages.rust.*` here — that block
# would fight the toolchain file.
{
  # ── Nix packages ──────────────────────────────────────────────────────
  packages = with pkgs; [
    # Install rustup itself (not a specific toolchain) — it reads
    # rust-toolchain.toml at the repo root, downloads the pinned version
    # (currently `stable`) on first `cargo` invocation, and puts `cargo`,
    # `rustc`, and the listed components (clippy, rustfmt, rust-analyzer)
    # on PATH.
    rustup

    gcc
    openssl
    # alsa-sys (freeq-sdk media/audio features) requires libasound and
    # pkg-config at build time. Without these, `cargo check --workspace
    # --all-targets` fails in a fresh devenv shell.
    alsa-lib
    pkg-config
    # whisper-rs-sys needs bindgen (libclang), cmake, and a C++ toolchain.
    # ratatui-image needs chafa for image rendering in the TUI; chafa
    # needs glib-2.0 in pkg-config search path.
    clang
    cmake
    chafa
    glib

    # Test scripts under scripts/ use lsof + nc.
    lsof
    netcat-openbsd

    # Common dev tooling.
    git
    gh
    gnumake
    curl
    jq

    # Task runner + Rust workflow helpers.
    just
    cargo-watch
    cargo-nextest
    cargo-edit        # cargo add/rm
    cargo-audit       # security audit (uses .cargo/audit.toml)
    cargo-outdated

    # Web client tooling.
    nodejs_24
    bun
  ];

  # ── Environment variables ────────────────────────────────────────────
  env = {
    # Default logging — freeq_webui + freeq_server at debug, rest at info.
    RUST_LOG = "freeq_webui=debug,freeq_server=debug,info";

    # Nicer cargo output.
    CARGO_TERM_COLOR = "always";
    CARGO_TERM_PROGRESS_WHEN = "never";
    CARGO_INCREMENTAL = "1";

    # Point freeq-app's vite dev server at the local server.
    FREEQ_WEB = "http://127.0.0.1:8080";

    # Convenience for the e2e scripts under scripts/.
    SERVER = "127.0.0.1:16667";
    LOCAL_SERVER = "127.0.0.1:16667";
    REMOTE_SERVER = "127.0.0.1:16668";

    # bindgen (used by whisper-rs-sys) needs libclang.so on PATH.
    LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
  };

  # ── Scripts (task-like shortcuts) ───────────────────────────────────
  scripts = {
    # Build the whole workspace
    build.exec = "cargo build --workspace";

    # Fast type-check across the workspace
    check.exec = "cargo check --workspace --all-targets";

    # Run the full Rust test suite (unit + integration)
    test.exec = "cargo test --workspace --all-features";

    # Fast test runner; respects per-package nextest configs if added later
    nt.exec = "cargo nextest run --workspace";

    # Watch + recheck on save
    watch.exec = "cargo watch -x check -x test";

    # Lint with clippy (deny warnings, like CI)
    lint.exec = "cargo clippy --workspace --all-targets -- -D warnings";

    # Format check (CI gate)
    fmt.exec = "cargo fmt --all -- --check";

    # Audit dependencies (uses .cargo/audit.toml)
    audit.exec = "cargo audit";

    # Web client dev server (Vite, port 5173)
    web-dev.exec = ''
      if [ ! -d "freeq-sdk-js/node_modules" ]; then
        (cd freeq-sdk-js && npm install --silent --ignore-scripts)
      fi
      if [ ! -d "freeq-app/node_modules" ]; then
        (cd freeq-app && npm install --silent --ignore-scripts)
      fi
      cd freeq-app && npm run dev
    '';

    # Web client production build (mirrors Dockerfile's web-builder stage)
    web-build.exec = ''
      (cd freeq-sdk-js && npm install --silent --ignore-scripts && npm run build)
      cd freeq-app && npm run build
    '';

    # Web client unit tests (vitest)
    web-test.exec = "cd freeq-app && npm test";

    # DataStar web UI (standalone proxy in freeq-webui/).
    # Default upstream is the public freeq deployment. Override with
    # `FREEQ_UPSTREAM=https://your-server` to point at a different one.
    # The proxy derives `wss://` from the scheme, so https upstream
    # becomes wss://irc.freeq.at/irc.
    # Binds to 127.0.0.1 — tailscale funnel proxies localhost:8090
    # to the public FQDN. Override with `FREEQ_WEBUI_BIND` for
    # all-interfaces (`0.0.0.0:8090`) or a specific Tailscale IP.
    webui-dev.exec = ''
      cd freeq-webui
      RUST_LOG="''${RUST_LOG:-freeq_webui=debug,info}" \
      FREEQ_UPSTREAM="''${FREEQ_UPSTREAM:-https://irc.freeq.at}" \
      FREEQ_WEBUI_BIND="''${FREEQ_WEBUI_BIND:-127.0.0.1:8090}" \
      FREEQ_PUBLIC_URL="''${FREEQ_PUBLIC_URL:-https://$(hostname -s).tailfe3ae2.ts.net}" \
        cargo run --bin freeq-webui
    '';

    # Run the server in dev mode (TCP + WebSocket on default ports)
    server-dev.exec = ''
      mkdir -p .dev-data
      cargo run --bin freeq-server -- \
        --listen-addr 127.0.0.1:6667 \
        --web-addr 127.0.0.1:8080 \
        --data-dir .dev-data \
        --db-path .dev-data/irc.db
    '';

    # Acceptance tests against two local test servers
    # (see scripts/test-local-e2e.sh)
    e2e.exec = "./scripts/test-local-e2e.sh";
  };

  # ── Process orchestration ────────────────────────────────────────────
  # No background services. Tests spin their own ports; the server is
  # brought up on demand via `devenv shell server-dev` (or
  # `just server-dev`).

  # ── enterShell: print a hint about the available shortcuts ───────────
  enterShell = ''
    cat <<'EOF'
    ╭─────────────────────────────────────────────────────────╮
    │ freeq dev env (devenv)                                  │
    │                                                         │
    │   devenv shell build      build the Rust workspace      │
    │   devenv shell check      fast cargo check              │
    │   devenv shell test       run the full test suite       │
    │   devenv shell nt         nextest (faster test runner)  │
    │   devenv shell watch      cargo watch on save           │
    │   devenv shell lint       clippy with -D warnings       │
    │   devenv shell fmt        cargo fmt --check             │
    │   devenv shell audit      cargo audit                   │
    │   devenv shell webui-dev  start the freeq-webui proxy   │
    │   devenv shell web-dev    start the freeq-app dev server │
    │   devenv shell web-build  production build of web client │
    │   devenv shell server-dev run freeq-server on :6667      │
    │   devenv shell e2e        run the S2S acceptance suite   │
    │   Browse the DataStar webui at                          │
    │   https://$(hostname -s).tailfe3ae2.ts.net/chat            │
    │   (run `tailscale funnel 8090` first if not already on)  │
    │   once webui-dev is running.                            │
    EOF
  '';

  # ── Misc: keep shell startup fast; avoid pulling unused services ────
  # Freeq is self-contained: SQLite is bundled in rusqlite, no external
  # DB. iroh/networking don't need system services. Nothing to disable.
}
