{
  description = "freeq workspace + crane-built eve-av-bridge (dynamic + glibc crt-static)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      rust-overlay,
      crane,
    }:
    # Linux only: packages pull alsa-lib + glibc.static (no Darwin).
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };
        inherit (pkgs) lib;

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "rustfmt"
            "clippy"
          ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Crane cargo sources + freeq path deps for eve-av-bridge only.
        # Keep the workspace Cargo.toml/Cargo.lock but drop huge app trees.
        cargoFilter =
          path: type:
          let
            base = baseNameOf path;
            isDenied =
              lib.hasInfix "/target" path
              || lib.hasInfix "/.git" path
              || lib.hasInfix "/.cargo-nix" path
              || lib.hasInfix "/node_modules" path
              || lib.hasInfix "/freeq-app" path
              || lib.hasInfix "/freeq-ios" path
              || lib.hasInfix "/freeq-android" path
              || lib.hasInfix "/freeq-macos" path
              || lib.hasInfix "/freeq-webui" path
              || lib.hasInfix "/freeq-web2" path
              || lib.hasInfix "/freeq-site" path
              || lib.hasInfix "/docs/" path
              || lib.hasInfix "/deploy/" path
              || lib.hasInfix "/Freeq.WinUI" path
              || base == "target"
              || base == ".cargo-nix";
          in
          (!isDenied)
          && (
            (craneLib.filterCargoSources path type)
            # Keep workspace metadata and non-rs assets crane still needs occasionally.
            || base == "Cargo.toml"
            || base == "Cargo.lock"
            || base == "rust-toolchain.toml"
            || lib.hasSuffix ".md" base
          );

        src = lib.cleanSourceWith {
          src = ./.;
          filter = cargoFilter;
          name = "freeq-eve-av-bridge-src";
        };

        commonArgs = {
          inherit src;
          pname = "eve-av-bridge";
          version = "0.1.0";
          strictDeps = true;

          # Workspace package — only build the bridge crate + its path deps.
          cargoExtraArgs = "-p eve-av-bridge --bins";

          nativeBuildInputs = with pkgs; [
            pkg-config
            cmake
            protobuf
            rustToolchain
          ];

          # iroh-live / cpal pull alsa on Linux (even if we only publish PCM).
          buildInputs = with pkgs; [
            alsa-lib
            openssl
          ];

          # No unit tests in the package build (they need network/SFU).
          doCheck = false;
        };

        # Shared dep graph — rebuilt only when Cargo.lock / toolchain change.
        cargoArtifacts = craneLib.buildDepsOnly (
          commonArgs
          // {
            # Deps-only still needs the same -p flag so it doesn't try every workspace member.
            pname = "eve-av-bridge-deps";
          }
        );

        # Dynamic (Nix store) — fine on NixOS / nix-ld hosts.
        eve-av-bridge = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            meta = {
              description = "eve freeq AV media plane (WebSocket + radio + viz)";
              mainProgram = "eve-av-bridge";
              platforms = lib.platforms.linux;
            };
          }
        );

        # Static libasound.a (default alsa-lib is shared-only).
        alsaLibStatic = pkgs.alsa-lib.overrideAttrs (old: {
          dontDisableStatic = true;
          configureFlags = (old.configureFlags or [ ]) ++ [
            "--enable-static"
            "--disable-shared"
          ];
        });

        # glibc crt-static on the *leaf* binary only. Global RUSTFLAGS break
        # host proc-macros; crane's cargo build runs normally, then we re-link.
        eve-av-bridge-static = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            pname = "eve-av-bridge-static";

            PKG_CONFIG_ALL_STATIC = "1";

            buildInputs = [
              pkgs.glibc.static
              alsaLibStatic
              pkgs.openssl
            ];

            # Prefer static alsa/openssl search paths for the final link.
            NIX_LDFLAGS = "-L${pkgs.glibc.static}/lib -L${alsaLibStatic}/lib";

            # After crane's normal cargo build, re-link only the bin with crt-static.
            postBuild = ''
              cargo rustc --release -p eve-av-bridge --bin eve-av-bridge --offline -- \
                -C target-feature=+crt-static \
                -C link-arg=-L${alsaLibStatic}/lib \
                -C link-arg=-L${pkgs.glibc.static}/lib \
                -C link-arg=-lasound
            '';

            meta = {
              description = "eve-av-bridge with glibc crt-static for bare Linux (Ubuntu boxd)";
              mainProgram = "eve-av-bridge";
              platforms = lib.platforms.linux;
            };
          }
        );

        # Optional clippy as a check (same artifacts).
        eve-av-bridge-clippy = craneLib.cargoClippy (
          commonArgs
          // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- -D warnings";
          }
        );
      in
      {
        packages = {
          default = eve-av-bridge;
          eve-av-bridge = eve-av-bridge;
          eve-av-bridge-static = eve-av-bridge-static;
        };

        apps.eve-av-bridge = flake-utils.lib.mkApp {
          drv = eve-av-bridge;
        };

        checks = {
          inherit eve-av-bridge eve-av-bridge-static;
          clippy = eve-av-bridge-clippy;
        };

        # Match package build inputs so local cargo can link the same libs.
        # Prefer: `nix develop` then `cargo build -p eve-av-bridge --release`
        # Or: `nix build .#eve-av-bridge` / `.#eve-av-bridge-static` (crane).
        devShells.default = craneLib.devShell {
          checks = self.checks.${system} or { };

          packages = with pkgs; [
            just
            pkg-config
            openssl
            alsa-lib
            glibc.static
            cmake
            protobuf
            ffmpeg
            watchexec
            rustToolchain
          ];

          shellHook = ''
            # Prefer rustup cargo when present (faster incremental local builds).
            if [ -d "$HOME/.rustup/toolchains" ]; then
              for t in stable-x86_64-unknown-linux-gnu nightly-x86_64-unknown-linux-gnu; do
                if [ -x "$HOME/.rustup/toolchains/$t/bin/cargo" ]; then
                  export PATH="$HOME/.rustup/toolchains/$t/bin:$PATH"
                  break
                fi
              done
            fi
            if [ -d "$HOME/.cargo/bin" ]; then
              export PATH="$HOME/.cargo/bin:$PATH"
            fi

            # Avoid nix gcc-wrapper poisoning host build-scripts (SIGSEGV).
            unset NIX_CC NIX_CC_FOR_BUILD NIX_BINTOOLS NIX_BINTOOLS_FOR_BUILD
            unset NIX_CFLAGS_COMPILE NIX_CFLAGS_COMPILE_FOR_BUILD
            if [ -n "''${NIX_LDFLAGS-}" ]; then
              export NIX_LDFLAGS="$(printf '%s\n' "$NIX_LDFLAGS" | sed -E 's/ *-rpath [^ ]+//g')"
            fi
            if [ -n "''${NIX_LDFLAGS_FOR_BUILD-}" ]; then
              export NIX_LDFLAGS_FOR_BUILD="$(printf '%s\n' "$NIX_LDFLAGS_FOR_BUILD" | sed -E 's/ *-rpath [^ ]+//g')"
            fi
            export NIX_HARDENING_ENABLE=""

            echo "freeq crane shell (rustc=$(rustc --version 2>/dev/null | head -1))"
            echo "  cargo build -p eve-av-bridge --release"
            echo "  nix build .#eve-av-bridge            # crane dynamic"
            echo "  nix build .#eve-av-bridge-static     # crane + glibc crt-static"
            echo "  nix build .#checks.x86_64-linux.clippy"
          '';
        };

        formatter = pkgs.nixfmt;
      }
    );
}
