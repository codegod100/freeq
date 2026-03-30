{
  description = "freeq development environment and freeq-textual package";

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
        lib = pkgs.lib;
        python = pkgs.python312;
        source =
          lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              let
                rel = lib.removePrefix "${toString ./.}/" (toString path);
              in
              lib.cleanSourceFilter path type
              && !(lib.hasPrefix "target/" rel)
              && !(lib.hasPrefix "dist/" rel)
              && rel != "1240466bundle_nix";
          };

        freeq-textual = python.pkgs.buildPythonApplication {
          pname = "freeq-textual";
          version = "0.1.0";
          pyproject = true;
          src = source;
          buildAndTestSubdir = "freeq-py";

          nativeBuildInputs = [
            pkgs.rustPlatform.cargoSetupHook
            pkgs.rustPlatform.maturinBuildHook
            pkgs.cargo
            pkgs.rustc
            pkgs.pkg-config
          ];

          buildInputs = [
            pkgs.openssl
          ];

          propagatedBuildInputs = [
            python.pkgs.pillow
            python.pkgs."rich-pixels"
            python.pkgs.textual
          ];

          cargoDeps = pkgs.rustPlatform.importCargoLock {
            lockFile = ./Cargo.lock;
          };

          env = {
            PYO3_PYTHON = "${python}/bin/python3.12";
          };

          meta = {
            mainProgram = "freeq-textual";
          };
        };

        freeq-textual-dev = pkgs.writeShellApplication {
          name = "freeq-textual-dev";
          runtimeInputs = [ freeq-textual ];
          text = ''
            exec freeq-textual "$@"
          '';
        };

        freeq-textual-editable = pkgs.writeShellApplication {
          name = "freeq-textual-editable";
          runtimeInputs = [
            pkgs.maturin
            python
          ];
          text = ''
            repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            cd "$repo_root"
            maturin develop --manifest-path freeq-py/Cargo.toml
            exec python3 -m freeq_textual "$@"
          '';
        };
      in
      {
        packages = {
          default = freeq-textual;
          freeq-textual = freeq-textual;
          freeq-textual-dev = freeq-textual-dev;
          freeq-textual-editable = freeq-textual-editable;
        };

        apps = {
          default = {
            type = "app";
            program = "${freeq-textual}/bin/freeq-textual";
          };
          freeq-textual = {
            type = "app";
            program = "${freeq-textual}/bin/freeq-textual";
          };
          dev-textual = {
            type = "app";
            program = "${freeq-textual-dev}/bin/freeq-textual-dev";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.just
            pkgs.maturin
            pkgs.pkg-config
            pkgs.openssl
            pkgs.watchexec
            python
            python.pkgs.venvShellHook
            python.pkgs.pip
            python.pkgs.pillow
            python.pkgs."rich-pixels"
            python.pkgs.textual
            python.pkgs."textual-dev"
          ];

          env = {
            PYO3_PYTHON = "${python}/bin/python3.12";
            PYTHONPATH = "${python.pkgs.textual}/${python.sitePackages}:${python.pkgs.pillow}/${python.sitePackages}:${python.pkgs."rich-pixels"}/${python.sitePackages}";
          };

          venvDir = ".venv";

          postShellHook = ''
            echo "Virtualenv ready at $VIRTUAL_ENV"
            echo "Run: just dev-textual"
          '';
        };
      }
    );
}
