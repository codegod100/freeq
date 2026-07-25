{
  description = "freeq-web4 — Gleam Lightspeed LiveView port of freeq-web3";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentic = {
      # gleam-preview lives here (ahead of github:codegod100/agentic)
      url = "git+https://tangled.org/nandi.uk/agentic";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agentic,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkGleam =
        system: pkgs:
        let
          gleamPreview = agentic.packages.${system}.gleam-preview;
        in
        pkgs.runCommand "gleam" { meta.mainProgram = "gleam"; } ''
          mkdir -p $out/bin
          ln -s ${pkgs.lib.getExe gleamPreview} $out/bin/gleam
        '';

      mkGleamRuntime =
        system: pkgs:
        let
          gleam = mkGleam system pkgs;
        in
        [
          gleam
          pkgs.beamPackages.erlang
          pkgs.rebar3
        ];

      mkScripts =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          runtimeInputs = mkGleamRuntime system pkgs;
          freeq-web4 = pkgs.writeShellApplication {
            name = "freeq-web4";
            inherit runtimeInputs;
            text = ''
              exec gleam run "$@"
            '';
          };
          freeq-web4-watch = pkgs.writeShellApplication {
            name = "freeq-web4-watch";
            runtimeInputs = runtimeInputs ++ [ pkgs.watchexec ];
            text = ''
              exec watchexec \
                --restart \
                --clear \
                --exts gleam,toml,css,js \
                -- \
                gleam run "$@"
            '';
          };
        in
        {
          inherit freeq-web4 freeq-web4-watch;
        };
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          scripts = mkScripts system;
        in
        {
          default = pkgs.mkShell {
            packages = (mkGleamRuntime system pkgs) ++ [
              pkgs.watchexec
              scripts.freeq-web4
              scripts.freeq-web4-watch
            ];

            shellHook = ''
              echo "freeq-web4 dev shell (gleam-preview → gleam)"
              echo "  gleam run / freeq-web4     # http://127.0.0.1:4004/"
              echo "  freeq-web4-watch           # restart on source changes"
              echo "  gleam test"
              echo "  defaults: FREEQ_UPSTREAM=wss://irc.freeq.at/irc"
            '';
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          scripts = mkScripts system;
        in
        {
          default = {
            type = "app";
            program = "${scripts.freeq-web4}/bin/freeq-web4";
          };
          watch = {
            type = "app";
            program = "${scripts.freeq-web4-watch}/bin/freeq-web4-watch";
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
