{
  description = "FreeQ Python TUI with screenshot tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            python312
            python312Packages.pip
            python312Packages.virtualenv
            # Screenshot tools
            scrot          # X11 screenshots
            grim           # Wayland screenshots  
            slurp          # Wayland region selector
            imagemagick    # import command
            # TUI dependencies
            python312Packages.textual
          ];
        };
      });
}
