{
  description = "freeq workspace + glibc-static eve-av-bridge for bare Linux (Ubuntu boxd, etc.)";

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
    # eachDefaultSystem would also invent aarch64-darwin / x86_64-darwin and
    # Determinate CI inventory fails evaluating alsa on those hosts.
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        # Host gnu target only — static via crt-static + glibc.static (no musl).
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          extensions = [
            "rust-src"
            "rustfmt"
            "clippy"
          ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter =
            path: type:
            let
              base = baseNameOf path;
            in
            !(
              pkgs.lib.hasInfix "/target" path
              || pkgs.lib.hasInfix "/.git" path
              || pkgs.lib.hasInfix "/node_modules" path
              || pkgs.lib.hasInfix "/freeq-app" path
              || pkgs.lib.hasInfix "/freeq-ios" path
              || pkgs.lib.hasInfix "/freeq-android" path
              || base == "target"
            );
        };

        commonArgs = {
          inherit src;
          pname = "eve-av-bridge";
          version = "0.1.0";
          strictDeps = true;
          cargoExtraArgs = "-p eve-av-bridge";

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

          doCheck = false;
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Dynamic (Nix store) — fine on NixOS / nix-ld hosts.
        eve-av-bridge = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
            meta = {
              description = "eve freeq AV media plane (WebSocket + radio)";
              mainProgram = "eve-av-bridge";
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

        # glibc crt-static on the final binary only (not proc-macros).
        # cargo rustc -C flags apply only to the leaf crate — setting
        # RUSTFLAGS globally breaks async-trait / host proc-macros.
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

            NIX_LDFLAGS = "-L${pkgs.glibc.static}/lib -L${alsaLibStatic}/lib";

            # Build deps normally, then re-link the bin with crt-static.
            buildPhase = ''
              runHook preBuild
              cargoBuildLog=$(mktemp cargoBuildLogXXXX.json)
              cargo build --release --message-format json-render-diagnostics \
                -p eve-av-bridge \
                --bin eve-av-bridge \
                | tee "$cargoBuildLog"
              # Re-compile/link only the final binary with static glibc CRT.
              cargo rustc --release -p eve-av-bridge --bin eve-av-bridge -- \
                -C target-feature=+crt-static \
                -C link-arg=-L${alsaLibStatic}/lib \
                -C link-arg=-lasound
              runHook postBuild
            '';

            meta = {
              description = "eve-av-bridge with glibc crt-static for bare Linux";
              mainProgram = "eve-av-bridge";
            };
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

        devShells.default = pkgs.mkShell {
          packages = [
            rustToolchain
            pkgs.just
            pkgs.pkg-config
            pkgs.openssl
            pkgs.alsa-lib
            pkgs.glibc.static
            pkgs.cmake
            pkgs.protobuf
            pkgs.ffmpeg
            pkgs.watchexec
          ];

          shellHook = ''
            echo "freeq dev shell"
            echo "  cargo build -p eve-av-bridge --release"
            echo "  RUSTFLAGS='-C target-feature=+crt-static' cargo build -p eve-av-bridge --release"
            echo "  nix build .#eve-av-bridge-static   # glibc crt-static for Ubuntu/boxd"
            echo "  nix build .#eve-av-bridge          # normal dynamic (NixOS)"
          '';
        };

        formatter = pkgs.nixfmt;
      }
    );
}
