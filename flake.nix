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
      in
      {
        packages = {
          default = freeq-textual;
          freeq-textual = freeq-textual;
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
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.just
            pkgs.maturin
            pkgs.pkg-config
            pkgs.openssl
            python
            python.pkgs.pip
            python.pkgs.textual
          ];

          env = {
            PYO3_PYTHON = "${python}/bin/python3.12";
          };
        };
      }
    );
}
