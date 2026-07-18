{
  description = "freeq-web2 — StimulusReflex port of freeq-webui";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Match the Ruby the Gemfile.lock was resolved against.
        ruby = pkgs.ruby_3_4;

        # Gems with native extensions (puma, websocket-driver, bootsnap,
        # debug) need a C toolchain + make on PATH during `bundle install`.
        nativeBuildInputs = with pkgs; [
          # C compiler + make for native gem extension builds
          gcc
          gnumake
          # pkg-config + openssl: some gems probe for headers at extconf time
          pkg-config
          # sqlite/openssl headers in case a transitive dep wants them
          openssl.dev
          # zlib for any gem linking against it
          zlib.dev
        ];

        # A bundler that targets the same Ruby.
        bundler = pkgs.bundler.override { ruby = ruby; };

        # Node + npm for the esbuild JS pipeline.
        nodejs = pkgs.nodejs_22;
      in
      {
        devShells.default = pkgs.mkShell {
          packages =
            nativeBuildInputs
            ++ [
              ruby
              bundler
              nodejs
              # Handy: auto-rebuild JS on change during dev.
              pkgs.watchexec
              # curl for smoke-testing the server.
              pkgs.curl
            ];

          # Environment for the dev shell. `env` sets variables that are
          # available to all commands run inside the shell.
          env = {
            # Point bundler at a project-local install path so `nix develop`
            # doesn't pollute the user's global gem dir.
            BUNDLE_PATH = ".bundle/vendor";
            BUNDLE_DISABLE_SHARED_GEMS = "1";
            # Silence the StimulusReflex caching sanity check in dev.
            SKIP_SANITY_CHECK = "1";
            # Upstream freeq-server (production IRC at irc.freeq.at).
            # Override for a local server:
            #   FREEQ_UPSTREAM=ws://127.0.0.1:8080/irc \
            #   FREEQ_UPSTREAM_REST=http://127.0.0.1:8080 nix develop
            FREEQ_UPSTREAM = "wss://irc.freeq.at/irc";
            FREEQ_UPSTREAM_REST = "https://irc.freeq.at";
          };

          shellHook = ''
            echo ""
            echo "  freeq-web2 dev shell (Ruby $(ruby -v | awk '{print $2}'), Node $(node -v | cut -d/ -f2-))"
            echo "  Upstream: $FREEQ_UPSTREAM"

            # `bundle` and `npm` binaries live on PATH via mkShell. Install
            # deps idempotently so the shell is immediately runnable.
            if [ ! -d .bundle/vendor ] || ! bundle check >/dev/null 2>&1; then
              echo "  → installing ruby gems (bundle install)…"
              bundle install --quiet >/dev/null 2>&1 || echo "  ! bundle install failed; run it manually"
            fi

            if [ ! -d node_modules ]; then
              echo "  → installing npm deps…"
              npm install --silent >/dev/null 2>&1 || echo "  ! npm install failed; run it manually"
            fi

            if [ ! -f app/assets/builds/application.js ]; then
              echo "  → building JS bundle…"
              npm run build --silent >/dev/null 2>&1 || echo "  ! npm run build failed; run it manually"
            fi

            echo ""
            echo "  Run the server:"
            echo "    bin/rails server -b 127.0.0.1 -p 3000"
            echo ""
          '';
        };
      }
    );
}