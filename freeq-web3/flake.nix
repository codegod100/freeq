{
  description = "freeq-web3 — Phoenix LiveView port of freeq-web2";

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

        beam = pkgs.beam.packages.erlang_27;
        elixir = beam.elixir_1_18;
        nodejs = pkgs.nodejs_22;
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            elixir
            beam.erlang
            pkgs.rebar3
            nodejs
            pkgs.inotify-tools
            pkgs.curl
            pkgs.git
          ];

          # Plain strings only — do NOT use `toString ./.something` here.
          # Under flakes, path literals resolve into the read-only Nix store
          # (e.g. /nix/store/...-source/freeq-web3/.mix), which breaks
          # `mix local.hex` / archive installs.
          env = {
            FREEQ_UPSTREAM = "wss://irc.freeq.at/irc";
            FREEQ_UPSTREAM_REST = "https://irc.freeq.at";
          };

          shellHook = ''
            # Writable Mix/Hex homes under the *checkout* (PWD), not the store.
            export MIX_HOME="''${MIX_HOME:-$PWD/.mix}"
            export HEX_HOME="''${HEX_HOME:-$PWD/.hex}"
            mkdir -p "$MIX_HOME" "$HEX_HOME"

            echo ""
            echo "  freeq-web3 dev shell (Elixir $(elixir --short-version 2>/dev/null || elixir --version 2>/dev/null | awk '/Elixir/{print $2}'), Node $(node -v))"
            echo "  Upstream: $FREEQ_UPSTREAM"
            echo "  MIX_HOME=$MIX_HOME"

            # Hex is required before mix can fetch deps. Install non-interactively
            # into the project-local MIX_HOME (never prompts "Shall I install Hex?").
            # Newer Hex installs as archives/hex-*/ directories (not only .ez files).
            if ! ls -d "$MIX_HOME"/archives/hex-* >/dev/null 2>&1; then
              echo "  → installing Hex (mix local.hex --force)…"
              mix local.hex --force --quiet 2>/dev/null || mix local.hex --force
            fi
            # rebar3 is also on PATH from nixpkgs; local.rebar is optional.
            if ! ls "$MIX_HOME"/elixir/*/rebar3 >/dev/null 2>&1; then
              mix local.rebar --force --quiet 2>/dev/null || true
            fi

            if [ ! -d deps ] || [ ! -d _build ]; then
              echo "  → first time: mix setup"
            fi
            echo ""
            echo "  Run the server:"
            echo "    mix phx.server"
            echo "  If compile fails after an OTP change: rm -rf _build && mix compile"
            echo ""
          '';
        };
      }
    );
}
